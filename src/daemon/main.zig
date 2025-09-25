const std = @import("std");
const layoutlib = @import("layoutlib");

const LayoutNode = layoutlib.LayoutNode;
const Constraint = layoutlib.Constraint;
const Renderer = layoutlib.Renderer;
const types = layoutlib.types;
const preview = layoutlib.preview;
const views = layoutlib.registry;

const Action = enum { render };

const ParseError = error{
    InvalidHeader,
    InvalidXml,
    MissingRoot,
    InvalidAction,
    InvalidViewType,
    InvalidOrientation,
    InvalidSizeSpec,
    InvalidDimension,
    InvalidText,
    InvalidColorResource,
    UnknownColorResource,
    InvalidColorReference,
    InvalidFontResource,
    UnknownFontResource,
    InvalidFontReference,
};

const Request = struct {
    id: ?[]u8 = null,
    action: Action = .render,
    root: LayoutNode,
    constraint: Constraint = .{},
    resources: Resources = .{},

    pub fn deinit(self: *Request, allocator: std.mem.Allocator) void {
        if (self.id) |id_slice| allocator.free(id_slice);
        self.root.deinit(allocator);
        self.resources.deinit(allocator);
    }
};

const Resources = struct {
    colors: std.StringArrayHashMapUnmanaged(types.Color) = .{},
    fonts: std.StringArrayHashMapUnmanaged(types.FontMetrics) = .{},

    pub fn deinit(self: *Resources, allocator: std.mem.Allocator) void {
        self.colors.deinit(allocator);
        self.fonts.deinit(allocator);
    }

    pub fn getColor(self: *const Resources, name: []const u8) ?types.Color {
        if (self.colors.get(name)) |entry| return entry;
        return null;
    }

    pub fn getFont(self: *const Resources, name: []const u8) ?types.FontMetrics {
        if (self.fonts.get(name)) |entry| return entry;
        return null;
    }
};

const XmlAttribute = struct { name: []const u8, value: []const u8 };

const XmlElement = struct {
    name: []const u8,
    attributes: std.ArrayListUnmanaged(XmlAttribute) = .{},
    children: std.ArrayListUnmanaged(XmlElement) = .{},

    pub fn deinit(self: *XmlElement, allocator: std.mem.Allocator) void {
        for (self.children.items) |*child| child.deinit(allocator);
        self.children.deinit(allocator);
        self.attributes.deinit(allocator);
    }
};

const Parser = struct {
    input: []const u8,
    index: usize = 0,

    fn init(input: []const u8) Parser {
        return .{ .input = input, .index = 0 };
    }

    fn eof(self: *Parser) bool {
        return self.index >= self.input.len;
    }
    fn peek(self: *Parser) u8 {
        return self.input[self.index];
    }

    fn skipWhitespace(self: *Parser) void {
        while (!self.eof()) : (self.index += 1) {
            switch (self.input[self.index]) {
                ' ', '\t', '\r', '\n' => {},
                else => return,
            }
        }
    }

    fn startsWith(self: *Parser, pattern: []const u8) bool {
        return self.index + pattern.len <= self.input.len and
            std.mem.eql(u8, self.input[self.index .. self.index + pattern.len], pattern);
    }

    fn advance(self: *Parser, amount: usize) void {
        self.index += amount;
    }

    fn expectChar(self: *Parser, expected: u8) !void {
        if (self.eof() or self.input[self.index] != expected) return ParseError.InvalidXml;
        self.index += 1;
    }

    fn parseName(self: *Parser) ![]const u8 {
        if (self.eof()) return ParseError.InvalidXml;
        const start = self.index;
        while (!self.eof()) : (self.index += 1) {
            switch (self.input[self.index]) {
                ' ', '\t', '\r', '\n', '/', '>', '=', '?' => break,
                else => {},
            }
        }
        if (start == self.index) return ParseError.InvalidXml;
        return self.input[start..self.index];
    }

    fn parseAttributeValue(self: *Parser) ![]const u8 {
        if (self.eof()) return ParseError.InvalidXml;
        const quote = self.input[self.index];
        if (quote != '"' and quote != '\'') return ParseError.InvalidXml;
        self.index += 1;
        const start = self.index;
        while (!self.eof()) : (self.index += 1) {
            if (self.input[self.index] == quote) {
                const value = self.input[start..self.index];
                self.index += 1;
                return value;
            }
        }
        return ParseError.InvalidXml;
    }

    fn consumeComment(self: *Parser) !void {
        self.advance(4); // "<!--"
        while (!self.eof()) : (self.index += 1) {
            if (self.startsWith("--")) {
                self.advance(2);
                try self.expectChar('>');
                return;
            }
        }
        return ParseError.InvalidXml;
    }

    fn consumeProcessingInstruction(self: *Parser) !void {
        self.advance(2); // "<?"
        while (!self.eof()) : (self.index += 1) {
            if (self.peek() == '?' and (self.index + 1 < self.input.len and self.input[self.index + 1] == '>')) {
                self.advance(2);
                return;
            }
        }
        return ParseError.InvalidXml;
    }

    fn consumeCData(self: *Parser) !void {
        self.advance(9); // "<![CDATA["
        while (!self.eof()) : (self.index += 1) {
            if (self.startsWith("]]")) {
                self.advance(2);
                try self.expectChar('>');
                return;
            }
        }
        return ParseError.InvalidXml;
    }

    fn consumeText(self: *Parser) void {
        while (!self.eof()) : (self.index += 1) {
            if (self.input[self.index] == '<') return;
        }
    }

    fn skipProlog(self: *Parser) !void {
        self.skipWhitespace();
        while (!self.eof()) {
            if (self.startsWith("<?")) {
                try self.consumeProcessingInstruction();
            } else if (self.startsWith("<!--")) {
                try self.consumeComment();
            } else break;
            self.skipWhitespace();
        }
    }

    fn parseElement(self: *Parser, allocator: std.mem.Allocator) !XmlElement {
        self.skipWhitespace();
        if (self.eof()) return ParseError.InvalidXml;

        if (self.startsWith("<?")) {
            try self.consumeProcessingInstruction();
            return self.parseElement(allocator);
        }
        if (self.startsWith("<!--")) {
            try self.consumeComment();
            return self.parseElement(allocator);
        }
        if (self.startsWith("<![CDATA[")) {
            try self.consumeCData();
            return self.parseElement(allocator);
        }

        try self.expectChar('<');
        if (self.eof() or self.input[self.index] == '/') return ParseError.InvalidXml;

        const name = try self.parseName();
        var element = XmlElement{ .name = name };
        errdefer element.deinit(allocator);

        while (true) {
            self.skipWhitespace();
            if (self.eof()) return ParseError.InvalidXml;
            const c = self.input[self.index];
            if (c == '/') {
                self.advance(1);
                try self.expectChar('>');
                return element;
            } else if (c == '>') {
                self.advance(1);
                break;
            } else {
                const attr_name = try self.parseName();
                self.skipWhitespace();
                try self.expectChar('=');
                self.skipWhitespace();
                const attr_value = try self.parseAttributeValue();
                try element.attributes.append(allocator, .{ .name = attr_name, .value = attr_value });
            }
        }

        while (true) {
            self.skipWhitespace();
            if (self.eof()) return ParseError.InvalidXml;
            if (self.startsWith("</")) {
                self.advance(2);
                self.skipWhitespace();
                const closing_name = try self.parseName();
                if (!std.mem.eql(u8, closing_name, element.name)) return ParseError.InvalidXml;
                self.skipWhitespace();
                try self.expectChar('>');
                break;
            }
            if (self.startsWith("<!--")) {
                try self.consumeComment();
                continue;
            }
            if (self.startsWith("<![CDATA[")) {
                try self.consumeCData();
                continue;
            }
            if (self.startsWith("<?")) {
                try self.consumeProcessingInstruction();
                continue;
            }
            if (self.startsWith("<")) {
                const child = try self.parseElement(allocator);
                try element.children.append(allocator, child);
            } else {
                self.consumeText();
            }
        }
        return element;
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Buffered stdio with 0.15.1 interfaces
    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer_impl = std.fs.File.stdout().writer(&stdout_buf);
    const stdout_writer: *std.Io.Writer = &stdout_writer_impl.interface;

    var stderr_buf: [4096]u8 = undefined;
    var stderr_writer_impl = std.fs.File.stderr().writer(&stderr_buf);
    const stderr_writer: *std.Io.Writer = &stderr_writer_impl.interface;

    var stdin_buf: [4096]u8 = undefined;
    var stdin_reader_impl = std.fs.File.stdin().reader(&stdin_buf);
    const stdin_reader: *std.Io.Reader = &stdin_reader_impl.interface;

    while (true) {
        // Read a single header line: "Content-Length: N"
        const header_line = readLineAlloc(allocator, stdin_reader, 4096) catch |err| {
            try stderr_writer.print("read_error:{s}\n", .{@errorName(err)});
            try stderr_writer.flush();
            break;
        };
        defer allocator.free(header_line);

        const trimmed = std.mem.trim(u8, header_line, " \t\r");
        if (trimmed.len == 0) continue;

        // Case-insensitive match for "Content-Length:"
        if (!(trimmed.len > "Content-Length:".len and
            std.ascii.startsWithIgnoreCase(trimmed, "Content-Length:")))
        {
            try emitError(stdout_writer, null, "invalid_header");
            try stdout_writer.flush();
            try stderr_writer.print("request_error:InvalidHeader\n", .{});
            try stderr_writer.flush();
            continue;
        }

        const length_slice = std.mem.trim(u8, trimmed["Content-Length:".len..], " \t");
        const content_length = std.fmt.parseInt(usize, length_slice, 10) catch {
            try emitError(stdout_writer, null, "invalid_length");
            try stdout_writer.flush();
            try stderr_writer.print("request_error:InvalidHeader\n", .{});
            try stderr_writer.flush();
            continue;
        };

        // Reject zero or absurdly large payloads (protect allocator)
        if (content_length == 0 or content_length > (1 << 28)) { // 256 MiB ceiling
            try emitError(stdout_writer, null, "invalid_length");
            try stdout_writer.flush();
            continue;
        }

        // Payload
        const payload = try allocator.alloc(u8, content_length);
        defer allocator.free(payload);

        readExact(stdin_reader, payload) catch |err| {
            try emitError(stdout_writer, null, "unexpected_eof");
            try stdout_writer.flush();
            try stderr_writer.print("read_error:{s}\n", .{@errorName(err)});
            try stderr_writer.flush();
            break;
        };

        // Parse → Request
        var parser = Parser.init(payload);
        parser.skipProlog() catch |err| {
            try emitError(stdout_writer, null, @errorName(err));
            try stdout_writer.flush();
            try stderr_writer.print("parse_error:{s}\n", .{@errorName(err)});
            try stderr_writer.flush();
            continue;
        };

        var request = parseRequest(allocator, &parser) catch |err| {
            try emitError(stdout_writer, null, @errorName(err));
            try stdout_writer.flush();
            try stderr_writer.print("request_error:{s}\n", .{@errorName(err)});
            try stderr_writer.flush();
            continue;
        };
        defer request.deinit(allocator);

        switch (request.action) {
            .render => {},
        }

        // If you persist renderer_instance above, reuse it here
        var renderer_instance = Renderer.init(allocator);
        var rendered = renderer_instance.render(&request.root, request.constraint) catch |err| {
            try emitError(stdout_writer, request.id, @errorName(err));
            try stdout_writer.flush();
            try stderr_writer.print("render_error:{s}\n", .{@errorName(err)});
            try stderr_writer.flush();
            continue;
        };
        defer rendered.deinit(allocator);

        const preview_image = preview.renderBase64Preview(allocator, &rendered) catch |err| {
            try emitError(stdout_writer, request.id, @errorName(err));
            try stdout_writer.flush();
            try stderr_writer.print("preview_error:{s}\n", .{@errorName(err)});
            try stderr_writer.flush();
            continue;
        };
        defer allocator.free(preview_image);

        try emitSuccess(stdout_writer, request.id, &rendered, preview_image);
        try stdout_writer.flush();
    }
}

// A simple, allocation-backed line reader (excludes trailing '\n' and ignores '\r').
// 0.15.1: use Reader.takeByte(); EndOfStream is a real error when using interface helpers.  [oai_citation:1‡ziglang.org](https://ziglang.org/download/0.15.1/release-notes.html?utm_source=chatgpt.com)
fn readLineAlloc(allocator: std.mem.Allocator, r: *std.Io.Reader, max: usize) ![]u8 {
    var out = std.ArrayListUnmanaged(u8){};
    errdefer out.deinit(allocator);

    while (out.items.len < max) {
        const b = r.takeByte() catch |e| switch (e) {
            error.EndOfStream => break, // return what we've accumulated
            else => return e,
        };

        if (b == '\n') break;
        if (b != '\r') try out.append(allocator, b);
    }
    return try out.toOwnedSlice(allocator);
}

// Read exactly len(payload) bytes or fail with UnexpectedEof (built atop takeByte()).
fn readExact(r: *std.Io.Reader, payload: []u8) !void {
    var i: usize = 0;
    while (i < payload.len) {
        const b = r.takeByte() catch |e| switch (e) {
            error.EndOfStream => return error.UnexpectedEof,
            else => return e,
        };
        payload[i] = b;
        i += 1;
    }
}

// ---- request parsing & rendering glue ----
fn parseRequest(allocator: std.mem.Allocator, parser: *Parser) !Request {
    var root_element = try parser.parseElement(allocator);
    defer root_element.deinit(allocator);

    var req = Request{ .root = LayoutNode.setGeneric(.{}) };
    errdefer req.deinit(allocator);

    if (std.mem.eql(u8, root_element.name, "layout-request")) {
        for (root_element.attributes.items) |attribute| {
            if (std.mem.eql(u8, attribute.name, "id")) {
                req.id = try decodeXmlEntities(allocator, attribute.value);
            } else if (std.mem.eql(u8, attribute.name, "action")) {
                req.action = try parseAction(attribute.value);
            }
        }

        var layout_child: ?*XmlElement = null;
        for (root_element.children.items) |*child| {
            if (std.mem.eql(u8, child.name, "constraint")) {
                req.constraint = try parseConstraintElement(child);
            } else if (std.mem.eql(u8, child.name, "resources")) {
                try parseResources(allocator, child, &req.resources);
            } else {
                layout_child = child;
            }
        }

        const target = layout_child orelse return ParseError.MissingRoot;
        req.root = try buildLayoutNode(allocator, target, &req.resources);
        return req;
    }

    // Treat first element as layout root by default.
    req.root = try buildLayoutNode(allocator, &root_element, &req.resources);
    return req;
}

fn parseAction(value: []const u8) !Action {
    if (std.mem.eql(u8, value, "render")) return .render;
    return ParseError.InvalidAction;
}

fn parseConstraintElement(element: *const XmlElement) !Constraint {
    var constraint = Constraint{};
    for (element.attributes.items) |attribute| {
        if (std.mem.eql(u8, attribute.name, "width")) {
            constraint.width = try parseConstraintDimension(attribute.value);
        } else if (std.mem.eql(u8, attribute.name, "height")) {
            constraint.height = try parseConstraintDimension(attribute.value);
        }
    }
    return constraint;
}

fn parseConstraintDimension(value: []const u8) !?f32 {
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    if (trimmed.len == 0) return null;
    if (std.mem.eql(u8, trimmed, "wrap_content")) return null;
    if (std.mem.eql(u8, trimmed, "match_parent")) return null;
    return try parseDimensionValue(trimmed);
}

fn parseResources(allocator: std.mem.Allocator, element: *const XmlElement, resources: *Resources) !void {
    for (element.children.items) |*child| {
        if (std.mem.eql(u8, child.name, "color")) {
            try parseColorResource(allocator, child, resources);
        } else if (std.mem.eql(u8, child.name, "font")) {
            try parseFontResource(allocator, child, resources);
        }
    }
}

fn parseColorResource(
    allocator: std.mem.Allocator,
    element: *const XmlElement,
    resources: *Resources,
) !void {
    var name: ?[]const u8 = null;
    var value_attr: ?[]const u8 = null;

    for (element.attributes.items) |attribute| {
        if (std.mem.eql(u8, attribute.name, "name")) {
            name = attribute.value;
        } else if (std.mem.eql(u8, attribute.name, "value")) {
            value_attr = attribute.value;
        }
    }

    const key = name orelse return ParseError.InvalidColorResource;
    const value_str = value_attr orelse return ParseError.InvalidColorResource;
    const color = try parseColorLiteral(value_str, ParseError.InvalidColorResource);
    try resources.colors.put(allocator, key, color);
}

fn parseFontResource(
    allocator: std.mem.Allocator,
    element: *const XmlElement,
    resources: *Resources,
) !void {
    var name: ?[]const u8 = null;
    var char_width: ?f32 = null;
    var line_height: ?f32 = null;

    for (element.attributes.items) |attribute| {
        if (std.mem.eql(u8, attribute.name, "name")) {
            name = attribute.value;
        } else if (std.mem.eql(u8, attribute.name, "charWidth")) {
            char_width = try parseFloatAttribute(attribute.value);
        } else if (std.mem.eql(u8, attribute.name, "lineHeight")) {
            line_height = try parseFloatAttribute(attribute.value);
        }
    }

    const key = name orelse return ParseError.InvalidFontResource;
    var metrics = types.FontMetrics.defaults();
    if (char_width) |cw| metrics.char_width = cw;
    if (line_height) |lh| metrics.line_height = lh;
    try resources.fonts.put(allocator, key, metrics);
}

fn parseFloatAttribute(value: []const u8) !f32 {
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    if (trimmed.len == 0) return ParseError.InvalidFontResource;
    return std.fmt.parseFloat(f32, trimmed) catch ParseError.InvalidFontResource;
}

fn parseColorLiteral(value: []const u8, comptime invalid_error: ParseError) !types.Color {
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    if (trimmed.len < 2 or trimmed[0] != '#') return invalid_error;
    const hex = trimmed[1..];

    return switch (hex.len) {
        3 => types.Color{
            .a = 0xFF,
            .r = try dupNibble(hex[0], invalid_error),
            .g = try dupNibble(hex[1], invalid_error),
            .b = try dupNibble(hex[2], invalid_error),
        },
        4 => types.Color{
            .a = try dupNibble(hex[0], invalid_error),
            .r = try dupNibble(hex[1], invalid_error),
            .g = try dupNibble(hex[2], invalid_error),
            .b = try dupNibble(hex[3], invalid_error),
        },
        6 => types.Color{
            .a = 0xFF,
            .r = try hexPair(hex[0], hex[1], invalid_error),
            .g = try hexPair(hex[2], hex[3], invalid_error),
            .b = try hexPair(hex[4], hex[5], invalid_error),
        },
        8 => types.Color{
            .a = try hexPair(hex[0], hex[1], invalid_error),
            .r = try hexPair(hex[2], hex[3], invalid_error),
            .g = try hexPair(hex[4], hex[5], invalid_error),
            .b = try hexPair(hex[6], hex[7], invalid_error),
        },
        else => return invalid_error,
    };
}

fn dupNibble(c: u8, comptime invalid_error: ParseError) !u8 {
    const nib = try hexNibble(c, invalid_error);
    return nib * 16 + nib;
}

fn hexPair(high: u8, low: u8, comptime invalid_error: ParseError) !u8 {
    const hi = try hexNibble(high, invalid_error);
    const lo = try hexNibble(low, invalid_error);
    return hi * 16 + lo;
}

fn hexNibble(c: u8, comptime invalid_error: ParseError) !u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => invalid_error,
    };
}

fn resolveColor(value: []const u8, resources: *const Resources) !?types.Color {
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    if (trimmed.len == 0) return null;

    if (trimmed[0] == '@') {
        const prefix = "@color/";
        if (!std.mem.startsWith(u8, trimmed, prefix)) return ParseError.InvalidColorReference;
        const name = trimmed[prefix.len..];
        if (name.len == 0) return ParseError.InvalidColorReference;
        if (resources.getColor(name)) |color| return color;
        return ParseError.UnknownColorResource;
    }

    if (trimmed[0] == '#') {
        return try parseColorLiteral(trimmed, ParseError.InvalidColorReference);
    }

    return ParseError.InvalidColorReference;
}

fn resolveFont(value: []const u8, resources: *const Resources) !?types.FontMetrics {
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    if (trimmed.len == 0) return null;

    const prefix = "@font/";
    if (!std.mem.startsWith(u8, trimmed, prefix)) return ParseError.InvalidFontReference;
    const name = trimmed[prefix.len..];
    if (name.len == 0) return ParseError.InvalidFontReference;

    if (resources.getFont(name)) |font| return font;
    return ParseError.UnknownFontResource;
}

fn buildLayoutNode(allocator: std.mem.Allocator, element: *const XmlElement, resources: *const Resources) !LayoutNode {
    const view_type = try parseViewType(element.name);
    var node_instance = LayoutNode{
        .view_type = view_type,
        .params = .{},
        .text = null,
        .text_owned = false,
        .orientation = .vertical,
        .background_color = null,
        .text_color = null,
        .font = null,
        .children = .{},
    };
    errdefer node_instance.deinit(allocator);

    try applyAttributes(allocator, &node_instance, element, resources);

    for (element.children.items) |*child_element| {
        var child_node = try buildLayoutNode(allocator, child_element, resources);
        node_instance.children.append(allocator, child_node) catch |err| {
            child_node.deinit(allocator);
            return err;
        };
    }
    return node_instance;
}

fn parseViewType(name: []const u8) !types.ViewType {
    return views.inferViewType(name);
}

fn applyAttributes(
    allocator: std.mem.Allocator,
    node_instance: *LayoutNode,
    element: *const XmlElement,
    resources: *const Resources,
) !void {
    for (element.attributes.items) |attribute| {
        if (std.mem.eql(u8, attribute.name, "android:layout_width")) {
            node_instance.params.width = try parseSizeSpec(attribute.value);
        } else if (std.mem.eql(u8, attribute.name, "android:layout_height")) {
            node_instance.params.height = try parseSizeSpec(attribute.value);
        } else if (std.mem.eql(u8, attribute.name, "android:orientation")) {
            node_instance.orientation = try parseOrientation(attribute.value);
        } else if (std.mem.eql(u8, attribute.name, "android:text")) {
            const duplicated = try decodeXmlEntities(allocator, attribute.value);
            node_instance.text = duplicated;
            node_instance.text_owned = true;
        } else if (std.mem.eql(u8, attribute.name, "android:padding")) {
            const v = try parseDimensionValue(attribute.value);
            node_instance.params.padding = types.EdgeInsets.uniform(v);
        } else if (std.mem.eql(u8, attribute.name, "android:paddingLeft")) {
            node_instance.params.padding.left = try parseDimensionValue(attribute.value);
        } else if (std.mem.eql(u8, attribute.name, "android:paddingTop")) {
            node_instance.params.padding.top = try parseDimensionValue(attribute.value);
        } else if (std.mem.eql(u8, attribute.name, "android:paddingRight")) {
            node_instance.params.padding.right = try parseDimensionValue(attribute.value);
        } else if (std.mem.eql(u8, attribute.name, "android:paddingBottom")) {
            node_instance.params.padding.bottom = try parseDimensionValue(attribute.value);
        } else if (std.mem.eql(u8, attribute.name, "android:layout_margin")) {
            const v = try parseDimensionValue(attribute.value);
            node_instance.params.margin = types.EdgeInsets.uniform(v);
        } else if (std.mem.eql(u8, attribute.name, "android:layout_marginLeft")) {
            node_instance.params.margin.left = try parseDimensionValue(attribute.value);
        } else if (std.mem.eql(u8, attribute.name, "android:layout_marginTop")) {
            node_instance.params.margin.top = try parseDimensionValue(attribute.value);
        } else if (std.mem.eql(u8, attribute.name, "android:layout_marginRight")) {
            node_instance.params.margin.right = try parseDimensionValue(attribute.value);
        } else if (std.mem.eql(u8, attribute.name, "android:layout_marginBottom")) {
            node_instance.params.margin.bottom = try parseDimensionValue(attribute.value);
        } else if (std.mem.eql(u8, attribute.name, "android:background")) {
            node_instance.background_color = try resolveColor(attribute.value, resources);
        } else if (std.mem.eql(u8, attribute.name, "android:textColor")) {
            node_instance.text_color = try resolveColor(attribute.value, resources);
        } else if (std.mem.eql(u8, attribute.name, "android:fontFamily")) {
            node_instance.font = try resolveFont(attribute.value, resources);
        }
    }
    if (node_instance.view_type == .text and node_instance.text == null) {
        return ParseError.InvalidText;
    }
}

fn parseSizeSpec(value: []const u8) !types.SizeSpec {
    const ws = " \t\r\n";
    const t = std.mem.trim(u8, value, ws);

    if (std.ascii.eqlIgnoreCase(t, "wrap_content")) return .wrap_content;
    if (std.ascii.eqlIgnoreCase(t, "match_parent") or std.ascii.eqlIgnoreCase(t, "fill_parent"))
        return .match_parent;

    const dim = try parseDimensionValue(t);
    return .{ .exact = dim };
}

fn parseOrientation(value: []const u8) !types.Orientation {
    const ws = " \t\r\n";
    const t = std.mem.trim(u8, value, ws);

    if (std.ascii.eqlIgnoreCase(t, "horizontal")) return .horizontal;
    if (std.ascii.eqlIgnoreCase(t, "vertical")) return .vertical;

    return ParseError.InvalidOrientation;
}

fn parseDimensionValue(value: []const u8) !f32 {
    const ws = " \t\r\n";
    const t = std.mem.trim(u8, value, ws);
    if (t.len == 0) return ParseError.InvalidDimension;

    // Parse a simple float prefix: optional sign, digits, optional '.', digits
    // (same as before; no exponents or units).
    var i: usize = 0;

    // optional sign
    if (i < t.len and (t[i] == '+' or t[i] == '-')) i += 1;

    var saw_digit = false;
    while (i < t.len and t[i] >= '0' and t[i] <= '9') : (i += 1) saw_digit = true;

    if (i < t.len and t[i] == '.') {
        i += 1;
        while (i < t.len and t[i] >= '0' and t[i] <= '9') : (i += 1) saw_digit = true;
    }

    if (!saw_digit) return ParseError.InvalidDimension;

    const num = t[0..i];
    // No trailing garbage allowed (exactly like your original behavior)
    const suffix = t[i..];
    if (suffix.len != 0) {
        if (!std.ascii.eqlIgnoreCase(suffix, "dp") and
            !std.ascii.eqlIgnoreCase(suffix, "dip") and
            !std.ascii.eqlIgnoreCase(suffix, "sp") and
            !std.ascii.eqlIgnoreCase(suffix, "px"))
        {
            return ParseError.InvalidDimension;
        }
    }

    return std.fmt.parseFloat(f32, num) catch ParseError.InvalidDimension;
}

fn decodeXmlEntities(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    // Fast path: no '&' → duplicate input
    if (std.mem.indexOfScalar(u8, value, '&') == null)
        return allocator.dupe(u8, value);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var i: usize = 0;
    while (i < value.len) {
        const c = value[i];
        if (c != '&') {
            try out.append(allocator, c);
            i += 1;
            continue;
        }

        // Find terminating ';'
        var end = i + 1;
        while (end < value.len and value[end] != ';') : (end += 1) {}
        if (end == value.len) return ParseError.InvalidXml;

        const entity = value[i + 1 .. end];
        if (entity.len == 0) return ParseError.InvalidXml;

        // Five XML predefined entities
        if (std.mem.eql(u8, entity, "amp")) {
            try out.append(allocator, '&');
        } else if (std.mem.eql(u8, entity, "lt")) {
            try out.append(allocator, '<');
        } else if (std.mem.eql(u8, entity, "gt")) {
            try out.append(allocator, '>');
        } else if (std.mem.eql(u8, entity, "quot")) {
            try out.append(allocator, '"');
        } else if (std.mem.eql(u8, entity, "apos")) {
            try out.append(allocator, '\'');
        } else if (entity[0] == '#') {
            // Numeric character reference: decimal "&#123;" or hex "&#x7B;"
            var cp_u32: u32 = 0;
            if (entity.len >= 2 and (entity[1] == 'x' or entity[1] == 'X')) {
                if (entity.len == 2) return ParseError.InvalidXml; // "&#x;"
                cp_u32 = std.fmt.parseInt(u32, entity[2..], 16) catch return ParseError.InvalidXml;
            } else {
                if (entity.len == 1) return ParseError.InvalidXml; // "&#;"
                cp_u32 = std.fmt.parseInt(u32, entity[1..], 10) catch return ParseError.InvalidXml;
            }

            // XML validity checks:
            // - Max code point U+10FFFF
            // - Disallow UTF-16 surrogate range U+D800..U+DFFF
            if (cp_u32 > 0x10_FFFF) return ParseError.InvalidXml;
            if (cp_u32 >= 0xD800 and cp_u32 <= 0xDFFF) return ParseError.InvalidXml;

            const cp: u21 = @intCast(cp_u32);
            var utf8_buf: [4]u8 = undefined;
            const n = std.unicode.utf8Encode(cp, &utf8_buf) catch return ParseError.InvalidXml;
            try out.appendSlice(allocator, utf8_buf[0..n]);
        } else {
            // Not a predefined XML entity
            return ParseError.InvalidXml;
        }

        i = end + 1; // advance past ';'
    }

    return try out.toOwnedSlice(allocator);
}

fn emitSuccess(
    writer: *std.Io.Writer,
    id: ?[]u8,
    rendered: *const layoutlib.RenderedNode,
    image_base64: []const u8,
) !void {
    try writer.writeAll("{\n");

    // optional id
    if (id) |identifier| {
        try writer.writeAll("  \"id\": \"");
        try writeJsonEscaped(writer, identifier);
        try writer.writeAll("\",\n");
    }

    // status
    try writer.writeAll("  \"status\": \"ok\",\n");

    // result { image, root }
    try writer.writeAll("  \"result\": {\n");
    try writer.writeAll("    \"image\": \"");
    try writer.writeAll(image_base64);
    try writer.writeAll("\",\n");
    try writer.writeAll("    \"root\": ");
    try writeRenderedNodeJson(writer, rendered, 2);
    try writer.writeAll("\n  }\n}\n");
}

fn emitError(
    writer: *std.Io.Writer,
    id: ?[]u8,
    message: []const u8,
) !void {
    try writer.writeAll("{\n");

    // optional id
    if (id) |identifier| {
        try writer.writeAll("  \"id\": \"");
        try writeJsonEscaped(writer, identifier);
        try writer.writeAll("\",\n");
    }

    // status + error object
    try writer.writeAll("  \"status\": \"error\",\n");
    try writer.writeAll("  \"error\": {\n");
    try writer.writeAll("    \"message\": \"");
    try writeJsonEscaped(writer, message);
    try writer.writeAll("\"\n");
    try writer.writeAll("  }\n}\n");
}

fn writeRenderedNodeJson(
    writer: *std.Io.Writer,
    rendered: *const layoutlib.RenderedNode,
    indent: usize,
) !void {
    try writer.writeAll("{\n");

    // --- type ---
    try writeIndent(writer, indent + 1);
    try writer.writeAll("\"type\": \"");
    try writer.writeAll(viewTypeName(rendered.view_type));
    try writer.writeAll("\",\n");

    // --- frame ---
    try writeIndent(writer, indent + 1);
    try writer.writeAll("\"frame\": {\n");
    try writeIndent(writer, indent + 2);
    try writer.print("\"x\": {d},\n", .{rendered.frame.x});
    try writeIndent(writer, indent + 2);
    try writer.print("\"y\": {d},\n", .{rendered.frame.y});
    try writeIndent(writer, indent + 2);
    try writer.print("\"width\": {d},\n", .{rendered.frame.width});
    try writeIndent(writer, indent + 2);
    try writer.print("\"height\": {d}\n", .{rendered.frame.height});
    try writeIndent(writer, indent + 1);
    try writer.writeAll("},\n");

    // --- margin ---
    try writeIndent(writer, indent + 1);
    try writer.writeAll("\"margin\": {\n");
    try writeIndent(writer, indent + 2);
    try writer.print("\"left\": {d},\n", .{rendered.margin.left});
    try writeIndent(writer, indent + 2);
    try writer.print("\"top\": {d},\n", .{rendered.margin.top});
    try writeIndent(writer, indent + 2);
    try writer.print("\"right\": {d},\n", .{rendered.margin.right});
    try writeIndent(writer, indent + 2);
    try writer.print("\"bottom\": {d}\n", .{rendered.margin.bottom});
    try writeIndent(writer, indent + 1);
    try writer.writeAll("},\n");

    // --- padding ---
    try writeIndent(writer, indent + 1);
    try writer.writeAll("\"padding\": {\n");
    try writeIndent(writer, indent + 2);
    try writer.print("\"left\": {d},\n", .{rendered.padding.left});
    try writeIndent(writer, indent + 2);
    try writer.print("\"top\": {d},\n", .{rendered.padding.top});
    try writeIndent(writer, indent + 2);
    try writer.print("\"right\": {d},\n", .{rendered.padding.right});
    try writeIndent(writer, indent + 2);
    try writer.print("\"bottom\": {d}\n", .{rendered.padding.bottom});
    try writeIndent(writer, indent + 1);
    try writer.writeAll("},\n");

    if (rendered.background_color) |bg| {
        try writeColorField(writer, indent + 1, "background_color", bg);
    }

    // --- optional text ---
    if (rendered.text) |txt| {
        try writeIndent(writer, indent + 1);
        try writer.writeAll("\"text\": \"");
        try writeJsonEscaped(writer, txt);
        try writer.writeAll("\",\n");
    }

    if (rendered.text_color) |fg| {
        try writeColorField(writer, indent + 1, "text_color", fg);
    }

    // --- optional orientation ---
    if (rendered.orientation) |orient| {
        try writeIndent(writer, indent + 1);
        try writer.print("\"orientation\": \"{s}\",\n", .{orientationName(orient)});
    }

    if (rendered.font) |font| {
        try writeIndent(writer, indent + 1);
        try writer.writeAll("\"font\": {\n");
        try writeIndent(writer, indent + 2);
        try writer.print("\"char_width\": {d},\n", .{font.char_width});
        try writeIndent(writer, indent + 2);
        try writer.print("\"line_height\": {d}\n", .{font.line_height});
        try writeIndent(writer, indent + 1);
        try writer.writeAll("},\n");
    }

    // --- children ---
    try writeIndent(writer, indent + 1);
    try writer.writeAll("\"children\": [");
    if (rendered.children.items.len == 0) {
        try writer.writeAll("]\n");
        try writeIndent(writer, indent);
        try writer.writeAll("}");
        return;
    }

    try writer.writeAll("\n");
    var i: usize = 0;
    while (i < rendered.children.items.len) : (i += 1) {
        try writeIndent(writer, indent + 2);
        try writeRenderedNodeJson(writer, &rendered.children.items[i], indent + 2);
        if (i + 1 < rendered.children.items.len) {
            try writer.writeAll(",\n");
        } else {
            try writer.writeAll("\n");
        }
    }

    try writeIndent(writer, indent + 1);
    try writer.writeAll("]\n");
    try writeIndent(writer, indent);
    try writer.writeAll("}");
}

fn writeColorField(
    writer: *std.Io.Writer,
    indent: usize,
    label: []const u8,
    color: types.Color,
) !void {
    try writeIndent(writer, indent);
    try writer.writeByte('"');
    try writer.writeAll(label);
    try writer.writeAll("\": \"");
    try writeColorHex(writer, color);
    try writer.writeAll("\",\n");
}

fn writeColorHex(writer: *std.Io.Writer, color: types.Color) !void {
    if (color.a != 0xFF) {
        try writer.print("#{X:0>2}{X:0>2}{X:0>2}{X:0>2}", .{ color.a, color.r, color.g, color.b });
    } else {
        try writer.print("#{X:0>2}{X:0>2}{X:0>2}", .{ color.r, color.g, color.b });
    }
}

fn writeIndent(writer: *std.Io.Writer, indent: usize) !void {
    var i: usize = 0;
    while (i < indent) : (i += 1) try writer.writeAll("  ");
}

fn viewTypeName(view_type: types.ViewType) []const u8 {
    return views.label(view_type);
}

fn orientationName(orientation: types.Orientation) []const u8 {
    return switch (orientation) {
        .horizontal => "horizontal",
        .vertical => "vertical",
    };
}

fn writeJsonEscaped(writer: *std.Io.Writer, value: []const u8) !void {
    for (value) |c| {
        switch (c) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => {
                if (c < 0x20) {
                    try writer.print("\\u{X:0>4}", .{@as(u16, c)});
                } else try writer.writeByte(c);
            },
        }
    }
}

// --------------------
// Minimal smoke tests (zig test this file)
// --------------------
test "readLineAlloc handles CRLF and size cap" {
    var reader = std.Io.Reader.fixed("Content-Length: 42\r\nHELLO");
    const out = try readLineAlloc(std.testing.allocator, &reader, 4096);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.eql(u8, out, "Content-Length: 42"));
}

test "readExact reads exactly N or errors UnexpectedEof" {
    var reader = std.Io.Reader.fixed("abcdef");
    var buf: [3]u8 = undefined;
    try readExact(&reader, buf[0..]);
    try std.testing.expect(std.mem.eql(u8, &buf, "abc"));
    try std.testing.expectError(error.UnexpectedEof, readExact(&reader, buf[0..4]));
}
