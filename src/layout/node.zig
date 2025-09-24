const std = @import("std");
const types = @import("types.zig");

pub const LayoutNode = struct {
    view_type: types.ViewType,
    params: types.LayoutParams = .{},
    text: ?[]const u8 = null,
    text_owned: bool = false,
    orientation: types.Orientation = .vertical,
    children: std.ArrayListUnmanaged(LayoutNode) = .{},

    pub fn setGeneric(params: types.LayoutParams) LayoutNode {
        return LayoutNode{
            .view_type = .generic,
            .params = params,
            .text = null,
            .text_owned = false,
            .orientation = .vertical,
            .children = .{},
        };
    }

    pub fn setText(params: types.LayoutParams, content: []const u8) LayoutNode {
        return LayoutNode{
            .view_type = .text,
            .params = params,
            .text = content,
            .text_owned = false,
            .orientation = .vertical,
            .children = .{},
        };
    }

    pub fn setLinearLayout(params: types.LayoutParams, orientation: types.Orientation) LayoutNode {
        return LayoutNode{
            .view_type = .linear_layout,
            .params = params,
            .text = null,
            .text_owned = false,
            .orientation = orientation,
            .children = .{},
        };
    }

    pub fn addChild(self: *LayoutNode, allocator: std.mem.Allocator, child: LayoutNode) !void {
        try self.children.append(allocator, child);
    }

    pub fn deinit(self: *LayoutNode, allocator: std.mem.Allocator) void {
        if (self.text_owned) {
            if (self.text) |owned| {
                allocator.free(owned);
            }
            self.text = null;
            self.text_owned = false;
        }
        for (self.children.items) |*child| {
            child.deinit(allocator);
        }
        self.children.deinit(allocator);
    }

    pub fn childCount(self: LayoutNode) usize {
        return self.children.items.len;
    }
};
