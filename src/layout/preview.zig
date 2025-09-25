const std = @import("std");
const renderer = @import("renderer.zig");
const types = @import("types.zig");

const Crc32 = std.hash.crc.Crc32;

const Color = struct {
    r: u8,
    g: u8,
    b: u8,
};

const fill_palette = [_]Color{
    .{ .r = 0xF3, .g = 0xF4, .b = 0xF6 },
    .{ .r = 0xD0, .g = 0xE3, .b = 0xFF },
    .{ .r = 0xFE, .g = 0xF3, .b = 0xC7 },
    .{ .r = 0xDC, .g = 0xF4, .b = 0xD8 },
    .{ .r = 0xF5, .g = 0xD0, .b = 0xC5 },
};

const border_palette = [_]Color{
    .{ .r = 0x9C, .g = 0xA3, .b = 0xAF },
    .{ .r = 0x60, .g = 0x85, .b = 0xBF },
    .{ .r = 0xCA, .g = 0x8A, .b = 0x04 },
    .{ .r = 0x16, .g = 0x8F, .b = 0x52 },
    .{ .r = 0xEA, .g = 0x58, .b = 0x48 },
};

const png_signature = [_]u8{ 0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A };
const ihdr_type = [_]u8{ 'I', 'H', 'D', 'R' };
const idat_type = [_]u8{ 'I', 'D', 'A', 'T' };
const iend_type = [_]u8{ 'I', 'E', 'N', 'D' };

/// Float rect used by your renderer/layout (x,y,width,height in pixels).
pub const FRect = struct {
    x: f32,
    y: f32,
    width: f32,
    height: f32,
};

/// Integer pixel rect (inclusive-exclusive: [left,right), [top,bottom))
pub const Rect = struct {
    left: usize,
    top: usize,
    right: usize,
    bottom: usize,
};

pub fn renderBase64Preview(
    allocator: std.mem.Allocator,
    root: *const renderer.RenderedNode,
) ![]u8 {
    const width: usize = dimensionToPixel(root.frame.width);
    const height: usize = dimensionToPixel(root.frame.height);

    const pixels = try allocator.alloc(u8, width * height * 4);
    defer allocator.free(pixels);

    fillBackground(pixels, width, height, .{ .r = 0xFF, .g = 0xFF, .b = 0xFF });
    drawNode(pixels, width, height, root, 0);

    const png_bytes = try encodePng(allocator, width, height, pixels);
    defer allocator.free(png_bytes);

    const enc_len = std.base64.standard.Encoder.calcSize(png_bytes.len);
    const enc_buf = try allocator.alloc(u8, enc_len);
    // errdefer removed because we return enc_buf on success (caller frees it)

    // Encode writes into enc_buf; return the owned mutable buffer
    _ = std.base64.standard.Encoder.encode(enc_buf, png_bytes);
    return enc_buf;
}

inline fn dimensionToPixel(value: f32) usize {
    if (value <= 0) return 1;
    return @intFromFloat(@ceil(value));
}

fn fillBackground(pixels: []u8, width: usize, height: usize, color: Color) void {
    const stride = width * 4;
    var y: usize = 0;
    while (y < height) : (y += 1) {
        const row = pixels[y * stride .. y * stride + stride];
        var x: usize = 0;
        while (x < width) : (x += 1) {
            const i = x * 4;
            row[i + 0] = color.r;
            row[i + 1] = color.g;
            row[i + 2] = color.b;
            row[i + 3] = 0xFF;
        }
    }
}

fn drawNode(
    pixels: []u8,
    width: usize,
    height: usize,
    node: *const renderer.RenderedNode,
    depth: usize,
) void {
    if (frameToRect(node.frame, width, height)) |rect| {
        const fill_color = if (node.background_color) |bg|
            convertColor(bg)
        else
            fill_palette[depth % fill_palette.len];
        const border_color = if (node.background_color) |bg|
            convertColor(darkenColor(bg, 0.8))
        else
            border_palette[depth % border_palette.len];
        drawRect(pixels, width, height, rect, fill_color, border_color);
    }
    var i: usize = 0;
    while (i < node.children.items.len) : (i += 1) {
        drawNode(pixels, width, height, &node.children.items[i], depth + 1);
    }
}

/// Convert a floating rect to a clamped pixel rect inside an image of (width,height).
/// Returns null if the rect does not intersect the image.
pub fn frameToRect(frame: types.Rect, width: usize, height: usize) ?Rect {
    // Work in signed space for intermediate math; clamp before casting back.
    const iw: i64 = @intCast(width);
    const ih: i64 = @intCast(height);

    var left: i64 = floatToIntFloor(frame.x);
    var top: i64 = floatToIntFloor(frame.y);
    var right: i64 = floatToIntCeil(frame.x + frame.width);
    var bottom: i64 = floatToIntCeil(frame.y + frame.height);

    // Ensure non-empty (at least 1×1) before clamping to image.
    if (right <= left) right = left + 1;
    if (bottom <= top) bottom = top + 1;

    // Reject if completely outside.
    if (right <= 0 or bottom <= 0) return null;
    if (left >= iw or top >= ih) return null;

    // Clamp to [0, image_dim]
    if (left < 0) left = 0;
    if (top < 0) top = 0;
    if (right > iw) right = iw;
    if (bottom > ih) bottom = ih;

    if (right <= left or bottom <= top) return null;

    return Rect{
        .left = @intCast(left),
        .top = @intCast(top),
        .right = @intCast(right),
        .bottom = @intCast(bottom),
    };
}

/// Floor to integer with explicit float→int path.
inline fn floatToIntFloor(v: f32) i64 {
    // @floor(v) is f32; ensure it fits i64 (image bounds already keep it small).
    return @intFromFloat(@floor(v));
}

inline fn floatToIntCeil(v: f32) i64 {
    return @intFromFloat(@ceil(v));
}

/// Draw a filled rectangle with a 1-pixel border onto an RGBA8 image buffer.
/// `pixels` length must be width*height*4.
pub fn drawRect(
    pixels: []u8,
    width: usize,
    height: usize,
    rect: Rect,
    fill: Color,
    border: Color,
) void {
    const stride = width * 4;

    // Inclusive border edges (handle 0 safely to avoid underflow on -1)
    const right_edge: usize = if (rect.right == 0) 0 else rect.right - 1;
    const bottom_edge: usize = if (rect.bottom == 0) 0 else rect.bottom - 1;

    var y = rect.top;
    while (y < rect.bottom and y < height) : (y += 1) {
        var x = rect.left;
        const row_off = y * stride;
        while (x < rect.right and x < width) : (x += 1) {
            const idx = row_off + x * 4;
            const is_border = (x == rect.left) or (x == right_edge) or (y == rect.top) or (y == bottom_edge);
            const c = if (is_border) border else fill;

            // Write RGBA
            pixels[idx + 0] = c.r;
            pixels[idx + 1] = c.g;
            pixels[idx + 2] = c.b;
            pixels[idx + 3] = 0xFF;
        }
    }
}

fn convertColor(color: types.Color) Color {
    return .{ .r = color.r, .g = color.g, .b = color.b };
}

fn darkenColor(color: types.Color, factor: f32) types.Color {
    return .{
        .r = scaleComponent(color.r, factor),
        .g = scaleComponent(color.g, factor),
        .b = scaleComponent(color.b, factor),
        .a = color.a,
    };
}

fn scaleComponent(value: u8, factor: f32) u8 {
    const scaled = @as(f32, @floatFromInt(value)) * factor;
    const clamped = std.math.clamp(scaled, 0.0, 255.0);
    return @intFromFloat(clamped);
}

/// Encodes RGBA8 pixels (width*height*4) as a PNG.
/// Uses no PNG filter (filter 0 per row) and zlib "stored" deflate blocks.
/// Returns an owned `[]u8` on `allocator`.
pub fn encodePng(
    allocator: std.mem.Allocator,
    width: usize,
    height: usize,
    pixels: []const u8,
) ![]u8 {
    // RGBA8 sanity check
    const stride = width * 4;
    std.debug.assert(pixels.len == stride * height);

    // Build raw scanlines with filter byte per row (0 = none)
    var raw = try allocator.alloc(u8, (stride + 1) * height);
    defer allocator.free(raw);

    var off: usize = 0;
    var y: usize = 0;
    while (y < height) : (y += 1) {
        raw[off] = 0; // filter type = none
        off += 1;

        const row_start = y * stride;
        const dst = raw[off .. off + stride];
        const src = pixels[row_start .. row_start + stride];
        @memcpy(dst, src);
        off += stride;
    }

    // ---- Compress 'raw' with zlib (stored blocks) into an allocating writer
    var z = std.Io.Writer.Allocating.init(allocator);
    defer z.deinit();
    const zw: *std.Io.Writer = &z.writer;

    try writeZlibNoCompression(zw, raw);
    try zw.flush();

    var compressed_list = z.toArrayList();
    defer compressed_list.deinit(allocator);
    const compressed = compressed_list.items; // []const u8 view

    // ---- Assemble PNG into another allocating writer
    var pw = std.Io.Writer.Allocating.init(allocator);
    defer pw.deinit();
    const w: *std.Io.Writer = &pw.writer;

    // Signature
    try w.writeAll(png_signature[0..]);

    // IHDR chunk (13 bytes)
    var ihdr: [13]u8 = undefined;
    std.mem.writeInt(u32, ihdr[0..4], @intCast(width), .big);
    std.mem.writeInt(u32, ihdr[4..8], @intCast(height), .big);
    ihdr[8] = 8; // bit depth = 8
    ihdr[9] = 6; // color type = RGBA
    ihdr[10] = 0; // compression method
    ihdr[11] = 0; // filter method
    ihdr[12] = 0; // interlace method

    try writeChunk(w, ihdr_type, ihdr[0..]);

    // IDAT chunk (single chunk with whole compressed buffer)
    try writeChunk(w, idat_type, compressed);

    // IEND chunk
    const empty: [0]u8 = .{};
    try writeChunk(w, iend_type, empty[0..]);

    try w.flush();

    // Return owned bytes
    var out_list = pw.toArrayList();
    defer out_list.deinit(allocator);
    return try allocator.dupe(u8, out_list.items);
}

/// PNG-style chunk writer:
/// - length (u32 BE) of `data`
/// - 4-byte `chunk_type`
/// - `data`
/// - CRC32 (over `chunk_type || data`, u32 BE)
pub fn writeChunk(
    writer: *std.Io.Writer,
    chunk_type: [4]u8,
    data: []const u8,
) std.Io.Writer.Error!void {
    // length
    var len_buf: [4]u8 = undefined;
    std.mem.writeInt(u32, len_buf[0..], @intCast(data.len), .big);
    try writer.writeAll(len_buf[0..]);

    // type
    try writer.writeAll(chunk_type[0..]);

    // data
    try writer.writeAll(data);

    // CRC32 over type||data
    var crc = Crc32.init();
    crc.update(chunk_type[0..]);
    crc.update(data);
    const crc_val = crc.final();

    var crc_buf: [4]u8 = undefined;
    std.mem.writeInt(u32, crc_buf[0..], crc_val, .big);
    try writer.writeAll(crc_buf[0..]);
}

/// Emits: zlib header (CMF/FLG) = 0x78 0x01, one or more stored blocks, Adler-32.
pub fn writeZlibNoCompression(writer: *std.Io.Writer, data: []const u8) std.Io.Writer.Error!void {
    // CMF/FLG: 0x78 0x01 = deflate, 32K window, fastest
    try writer.writeAll(&[_]u8{ 0x78, 0x01 });

    var remaining: usize = data.len;
    var offset: usize = 0;

    while (remaining > 0) {
        const block_len: usize = if (remaining > 0xFFFF) 0xFFFF else remaining;
        const final_block = block_len == remaining;

        // Stored block header:
        //  1 byte  BFINAL|BTYPE(00)   -> 0x01 for final, 0x00 otherwise
        //  2 bytes LEN   (little endian)
        //  2 bytes NLEN  (one's complement of LEN, little endian)
        try writer.writeByte(if (final_block) 0x01 else 0x00);

        var len_buf: [2]u8 = undefined;
        std.mem.writeInt(u16, len_buf[0..], @intCast(block_len), .little);
        try writer.writeAll(len_buf[0..]);

        const nlen: u16 = ~@as(u16, @intCast(block_len));
        std.mem.writeInt(u16, len_buf[0..], nlen, .little);
        try writer.writeAll(len_buf[0..]);

        // Payload
        try writer.writeAll(data[offset .. offset + block_len]);

        offset += block_len;
        remaining -= block_len;
    }

    // Zlib trailer: Adler-32 of the *uncompressed* data, big endian
    const sum = adler32(data);
    var tail: [4]u8 = undefined;
    std.mem.writeInt(u32, tail[0..], sum, .big);
    try writer.writeAll(tail[0..]);
}

/// Tiny, straightforward Adler-32 (mod 65521).
fn adler32(bytes: []const u8) u32 {
    var s1: u32 = 1;
    var s2: u32 = 0;
    // NMAX from zlib (process in chunks to limit overflow); 5552 works well
    const NMAX: usize = 5552;

    var i: usize = 0;
    while (i < bytes.len) {
        const chunk_end = @min(i + NMAX, bytes.len);
        while (i < chunk_end) : (i += 1) {
            s1 +%= bytes[i];
            s2 +%= s1;
        }
        s1 %= 65521;
        s2 %= 65521;
    }
    return (s2 << 16) | s1;
}
