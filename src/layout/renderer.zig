const std = @import("std");
const types = @import("types.zig");
const node = @import("node.zig");
const views = @import("view_registry.zig");

pub const Constraint = struct {
    width: ?f32 = null,
    height: ?f32 = null,

    pub fn bounded(width: f32, height: f32) Constraint {
        return Constraint{ .width = width, .height = height };
    }

    pub fn unbounded() Constraint {
        return Constraint{};
    }
};

pub const RenderedNode = struct {
    view_type: types.ViewType,
    frame: types.Rect = .{},
    margin: types.EdgeInsets = .{},
    padding: types.EdgeInsets = .{},
    text: ?[]const u8 = null,
    orientation: ?types.Orientation = null,
    children: std.ArrayListUnmanaged(RenderedNode) = .{},

    pub fn deinit(self: *RenderedNode, allocator: std.mem.Allocator) void {
        for (self.children.items) |*child| {
            child.deinit(allocator);
        }
        self.children.deinit(allocator);
    }
};

pub const Renderer = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Renderer {
        return Renderer{ .allocator = allocator };
    }

    pub fn render(self: *Renderer, root: *const node.LayoutNode, constraint: Constraint) error{OutOfMemory}!RenderedNode {
        var rendered = try self.layoutNode(root, constraint);
        rendered.frame.x = 0;
        rendered.frame.y = 0;
        return rendered;
    }

    fn layoutNode(self: *Renderer, layout_node: *const node.LayoutNode, constraint: Constraint) error{OutOfMemory}!RenderedNode {
        const behavior = views.behavior(layout_node.view_type);

        var result = RenderedNode{
            .view_type = layout_node.view_type,
            .frame = .{},
            .margin = layout_node.params.margin,
            .padding = layout_node.params.padding,
            .text = layout_node.text,
            .orientation = if (behavior == .linear_container) layout_node.orientation else null,
            .children = .{},
        };
        errdefer result.deinit(self.allocator);

        try result.children.ensureTotalCapacity(self.allocator, layout_node.children.items.len);

        const margin_horizontal = layout_node.params.margin.totalHorizontal();
        const margin_vertical = layout_node.params.margin.totalVertical();
        const padding_horizontal = layout_node.params.padding.totalHorizontal();
        const padding_vertical = layout_node.params.padding.totalVertical();

        const available_width = types.subtractInsets(constraint.width, margin_horizontal);
        const available_height = types.subtractInsets(constraint.height, margin_vertical);

        const content_width_limit = types.subtractInsets(available_width, padding_horizontal);
        const content_height_limit = types.subtractInsets(available_height, padding_vertical);

        switch (behavior) {
            .text_leaf => {
                const measurement = measureText(layout_node.text orelse "", content_width_limit);
                const measured_width = measurement.width + padding_horizontal;
                const measured_height = measurement.height + padding_vertical;

                result.frame.width = finalizeDimension(layout_node.params.width, measured_width, available_width);
                result.frame.height = finalizeDimension(layout_node.params.height, measured_height, available_height);
            },
            .generic_container => {
                const dims = try self.layoutFreeform(layout_node, content_width_limit, content_height_limit, &result);
                const measured_width = dims.width + padding_horizontal;
                const measured_height = dims.height + padding_vertical;

                result.frame.width = finalizeDimension(layout_node.params.width, measured_width, available_width);
                result.frame.height = finalizeDimension(layout_node.params.height, measured_height, available_height);
            },
            .linear_container => {
                const dims = try self.layoutLinear(layout_node, content_width_limit, content_height_limit, &result);
                const measured_width = dims.width + padding_horizontal;
                const measured_height = dims.height + padding_vertical;

                result.frame.width = finalizeDimension(layout_node.params.width, measured_width, available_width);
                result.frame.height = finalizeDimension(layout_node.params.height, measured_height, available_height);
            },
        }

        return result;
    }

    fn layoutLinear(self: *Renderer, layout_node: *const node.LayoutNode, width_limit: ?f32, height_limit: ?f32, result: *RenderedNode) error{OutOfMemory}!types.Size {
        var content_width: f32 = 0;
        var content_height: f32 = 0;

        switch (layout_node.orientation) {
            .vertical => {
                var cursor_y = layout_node.params.padding.top;
                var max_width: f32 = 0;

                var index: usize = 0;
                while (index < layout_node.children.items.len) : (index += 1) {
                    const child = &layout_node.children.items[index];
                    var child_rendered = try self.layoutNode(child, Constraint{ .width = width_limit, .height = height_limit });

                    const offset_x = layout_node.params.padding.left + child.params.margin.left;
                    const offset_y = cursor_y + child.params.margin.top;
                    child_rendered.frame.x = offset_x;
                    child_rendered.frame.y = offset_y;

                    const total_width = child.params.margin.left + child_rendered.frame.width + child.params.margin.right;
                    max_width = types.max(max_width, total_width);

                    cursor_y = offset_y + child_rendered.frame.height + child.params.margin.bottom;

                    result.children.appendAssumeCapacity(child_rendered);
                }

                content_width = max_width;
                content_height = cursor_y - layout_node.params.padding.top;
            },
            .horizontal => {
                var cursor_x = layout_node.params.padding.left;
                var max_height: f32 = 0;

                var index: usize = 0;
                while (index < layout_node.children.items.len) : (index += 1) {
                    const child = &layout_node.children.items[index];
                    var child_rendered = try self.layoutNode(child, Constraint{ .width = width_limit, .height = height_limit });

                    const offset_x = cursor_x + child.params.margin.left;
                    const offset_y = layout_node.params.padding.top + child.params.margin.top;
                    child_rendered.frame.x = offset_x;
                    child_rendered.frame.y = offset_y;

                    const total_height = child.params.margin.top + child_rendered.frame.height + child.params.margin.bottom;
                    max_height = types.max(max_height, total_height);

                    cursor_x = offset_x + child_rendered.frame.width + child.params.margin.right;

                    result.children.appendAssumeCapacity(child_rendered);
                }

                content_width = cursor_x - layout_node.params.padding.left;
                content_height = max_height;
            },
        }

        return types.Size{ .width = content_width, .height = content_height };
    }

    fn layoutFreeform(self: *Renderer, layout_node: *const node.LayoutNode, width_limit: ?f32, height_limit: ?f32, result: *RenderedNode) error{OutOfMemory}!types.Size {
        const padding_horizontal = layout_node.params.padding.totalHorizontal();
        const padding_vertical = layout_node.params.padding.totalVertical();

        var measured_width = padding_horizontal;
        var measured_height = padding_vertical;

        var index: usize = 0;
        while (index < layout_node.children.items.len) : (index += 1) {
            const child = &layout_node.children.items[index];
            var child_rendered = try self.layoutNode(child, Constraint{ .width = width_limit, .height = height_limit });

            const offset_x = layout_node.params.padding.left + child.params.margin.left;
            const offset_y = layout_node.params.padding.top + child.params.margin.top;
            child_rendered.frame.x = offset_x;
            child_rendered.frame.y = offset_y;

            const candidate_width = offset_x + child_rendered.frame.width + child.params.margin.right + layout_node.params.padding.right;
            const candidate_height = offset_y + child_rendered.frame.height + child.params.margin.bottom + layout_node.params.padding.bottom;

            measured_width = types.max(measured_width, candidate_width);
            measured_height = types.max(measured_height, candidate_height);

            result.children.appendAssumeCapacity(child_rendered);
        }

        const content_width = types.sanitize(measured_width - padding_horizontal);
        const content_height = types.sanitize(measured_height - padding_vertical);

        return types.Size{ .width = content_width, .height = content_height };
    }
};

fn finalizeDimension(spec: types.SizeSpec, measured: f32, available: ?f32) f32 {
    return types.sanitize(types.resolveDimension(spec, measured, available));
}

fn measureText(text: []const u8, width_limit: ?f32) types.Size {
    const char_width: f32 = 7.0;
    const line_height: f32 = 16.0;

    if (text.len == 0) {
        return types.Size{ .width = 0, .height = 0 };
    }

    var lines: usize = 1;
    var max_width: f32 = 0;
    var current_width: f32 = 0;

    for (text) |c| {
        if (c == '\n') {
            max_width = types.max(max_width, current_width);
            current_width = 0;
            lines += 1;
            continue;
        }

        if (width_limit) |limit| {
            if (current_width + char_width > limit and current_width > 0) {
                max_width = types.max(max_width, current_width);
                current_width = char_width;
                lines += 1;
            } else {
                current_width += char_width;
            }
        } else {
            current_width += char_width;
        }
    }

    max_width = types.max(max_width, current_width);
    const resolved_width = if (width_limit) |limit| types.clampToAvailable(max_width, limit) else max_width;
    const resolved_height = @as(f32, @floatFromInt(lines)) * line_height;

    return types.Size{ .width = resolved_width, .height = resolved_height };
}
