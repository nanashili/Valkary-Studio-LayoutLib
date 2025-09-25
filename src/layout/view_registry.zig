const std = @import("std");
const types = @import("types.zig");

pub const Behavior = enum {
    generic_container,
    linear_container,
    text_leaf,
};

pub const ViewRegistration = struct {
    view_type: types.ViewType,
    canonical_name: []const u8,
    aliases: []const []const u8 = &.{},
    label: []const u8,
    behavior: Behavior,
};

pub const registry = [_]ViewRegistration{
    .{
        .view_type = .generic,
        .canonical_name = "View",
        .aliases = &.{ "android.view.View", "ViewGroup", "android.view.ViewGroup" },
        .label = "generic",
        .behavior = .generic_container,
    },
    .{
        .view_type = .text,
        .canonical_name = "TextView",
        .aliases = &.{ "android.widget.TextView", "androidx.appcompat.widget.AppCompatTextView" },
        .label = "text",
        .behavior = .text_leaf,
    },
    .{
        .view_type = .linear_layout,
        .canonical_name = "LinearLayout",
        .aliases = &.{ "android.widget.LinearLayout", "androidx.appcompat.widget.LinearLayoutCompat" },
        .label = "linear_layout",
        .behavior = .linear_container,
    },
    .{
        .view_type = .frame_layout,
        .canonical_name = "FrameLayout",
        .aliases = &.{ "android.widget.FrameLayout", "androidx.appcompat.widget.ContentFrameLayout" },
        .label = "frame_layout",
        .behavior = .generic_container,
    },
    .{
        .view_type = .relative_layout,
        .canonical_name = "RelativeLayout",
        .aliases = &.{"android.widget.RelativeLayout"},
        .label = "relative_layout",
        .behavior = .generic_container,
    },
    .{
        .view_type = .constraint_layout,
        .canonical_name = "ConstraintLayout",
        .aliases = &.{"androidx.constraintlayout.widget.ConstraintLayout"},
        .label = "constraint_layout",
        .behavior = .generic_container,
    },
};

pub fn inferViewType(name: []const u8) types.ViewType {
    return lookup(name) orelse .generic;
}

pub fn lookup(name: []const u8) ?types.ViewType {
    if (name.len == 0) return null;

    const trimmed = std.mem.trim(u8, name, " \t\r\n");
    if (trimmed.len == 0) return null;

    const simple = simpleName(trimmed);

    for (registry) |entry| {
        if (matches(entry.canonical_name, trimmed, simple)) return entry.view_type;
        for (entry.aliases) |alias| {
            if (matches(alias, trimmed, simple)) return entry.view_type;
        }
    }

    return null;
}

pub fn behavior(view_type: types.ViewType) Behavior {
    for (registry) |entry| {
        if (entry.view_type == view_type) return entry.behavior;
    }
    return .generic_container;
}

pub fn label(view_type: types.ViewType) []const u8 {
    for (registry) |entry| {
        if (entry.view_type == view_type) return entry.label;
    }
    return "generic";
}

fn simpleName(name: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, name, '.')) |idx| {
        if (idx + 1 < name.len) return name[idx + 1 ..];
    }
    return name;
}

fn matches(candidate: []const u8, value: []const u8, simple: []const u8) bool {
    return std.mem.eql(u8, value, candidate) or std.mem.eql(u8, simple, candidate);
}

fn ensureCovered() void {
    comptime {
        for (@typeInfo(types.ViewType).Enum.fields) |field| {
            const vt = @field(types.ViewType, field.name);
            var found = false;
            for (registry) |entry| {
                if (entry.view_type == vt) {
                    found = true;
                    break;
                }
            }
            if (!found) @compileError("View type not registered: " ++ field.name);
        }
    }
}

const _ = ensureCovered;

test "fully qualified names resolve to known view types" {
    try std.testing.expectEqual(types.ViewType.linear_layout, lookup("android.widget.LinearLayout").?);
    try std.testing.expectEqual(types.ViewType.frame_layout, lookup("androidx.appcompat.widget.ContentFrameLayout").?);
    try std.testing.expectEqual(types.ViewType.constraint_layout, lookup("androidx.constraintlayout.widget.ConstraintLayout").?);
}
