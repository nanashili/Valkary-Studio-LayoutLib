const std = @import("std");

pub const types = @import("layout/types.zig");
pub const node = @import("layout/node.zig");
pub const renderer = @import("layout/renderer.zig");
pub const preview = @import("layout/preview.zig");

pub const EdgeInsets = types.EdgeInsets;
pub const LayoutParams = types.LayoutParams;
pub const Orientation = types.Orientation;
pub const SizeSpec = types.SizeSpec;
pub const ViewType = types.ViewType;
pub const Rect = types.Rect;

pub const LayoutNode = node.LayoutNode;
pub const Renderer = renderer.Renderer;
pub const Constraint = renderer.Constraint;
pub const RenderedNode = renderer.RenderedNode;

fn expectApproxEq(a: f32, b: f32) !void {
    try std.testing.expectApproxEqAbs(a, b, 0.001);
}

test "vertical linear layout positions children sequentially" {
    const allocator = std.testing.allocator;

    var root = LayoutNode.setLinearLayout(LayoutParams{
        .width = .match_parent,
        .height = .wrap_content,
        .padding = EdgeInsets.uniform(8),
    }, .vertical);
    defer root.deinit(allocator);

    try root.addChild(allocator, LayoutNode.setText(LayoutParams{}, "Hello"));
    try root.addChild(allocator, LayoutNode.setText(LayoutParams{}, "World"));

    var renderer_instance = Renderer.init(allocator);
    var rendered = try renderer_instance.render(&root, Constraint{ .width = 200, .height = null });
    defer rendered.deinit(allocator);

    try expectApproxEq(200, rendered.frame.width);
    try expectApproxEq(48, rendered.frame.height);

    try std.testing.expectEqual(@as(usize, 2), rendered.children.items.len);

    const first = rendered.children.items[0];
    const second = rendered.children.items[1];

    try expectApproxEq(8, first.frame.x);
    try expectApproxEq(8, first.frame.y);
    try expectApproxEq(35, first.frame.width);
    try expectApproxEq(16, first.frame.height);

    try expectApproxEq(8, second.frame.x);
    try expectApproxEq(24, second.frame.y);
}

test "horizontal linear layout accumulates width" {
    const allocator = std.testing.allocator;

    var root = LayoutNode.setLinearLayout(LayoutParams{
        .width = .wrap_content,
        .height = .wrap_content,
        .padding = EdgeInsets.uniform(4),
    }, .horizontal);
    defer root.deinit(allocator);

    try root.addChild(allocator, LayoutNode.setText(LayoutParams{}, "AB"));
    try root.addChild(allocator, LayoutNode.setText(LayoutParams{}, "CD"));

    var renderer_instance = Renderer.init(allocator);
    var rendered = try renderer_instance.render(&root, Constraint.unbounded());
    defer rendered.deinit(allocator);

    try expectApproxEq(4 + 14 + 14 + 4, rendered.frame.width);
    try expectApproxEq(4 + 16 + 4, rendered.frame.height);

    const first = rendered.children.items[0];
    const second = rendered.children.items[1];

    try expectApproxEq(4, first.frame.x);
    try expectApproxEq(4, first.frame.y);
    try expectApproxEq(14, first.frame.width);

    try expectApproxEq(18, second.frame.x);
}

test "text measurement wraps when constrained" {
    const allocator = std.testing.allocator;
    var text_node = LayoutNode.setText(LayoutParams{ .padding = EdgeInsets.symmetric(2, 2) }, "HelloWorld");
    defer text_node.deinit(allocator);

    var renderer_instance = Renderer.init(allocator);
    var rendered = try renderer_instance.render(&text_node, Constraint{ .width = 30, .height = null });
    defer rendered.deinit(allocator);

    try std.testing.expect(rendered.frame.height > 16);
}
