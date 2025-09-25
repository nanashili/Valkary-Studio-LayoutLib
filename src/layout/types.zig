pub const Orientation = enum {
    horizontal,
    vertical,
};

pub const ViewType = enum {
    generic,
    text,
    linear_layout,
    frame_layout,
    relative_layout,
    constraint_layout,
};

pub const SizeSpec = union(enum) {
    wrap_content,
    match_parent,
    exact: f32,
};

pub const EdgeInsets = struct {
    left: f32 = 0,
    top: f32 = 0,
    right: f32 = 0,
    bottom: f32 = 0,

    pub fn uniform(value: f32) EdgeInsets {
        return EdgeInsets{ .left = value, .top = value, .right = value, .bottom = value };
    }

    pub fn symmetric(vertical: f32, horizontal: f32) EdgeInsets {
        return EdgeInsets{ .top = vertical, .bottom = vertical, .left = horizontal, .right = horizontal };
    }

    pub fn totalHorizontal(self: EdgeInsets) f32 {
        return self.left + self.right;
    }

    pub fn totalVertical(self: EdgeInsets) f32 {
        return self.top + self.bottom;
    }
};

pub const LayoutParams = struct {
    width: SizeSpec = .wrap_content,
    height: SizeSpec = .wrap_content,
    margin: EdgeInsets = .{},
    padding: EdgeInsets = .{},
};

pub const Color = struct {
    r: u8 = 0,
    g: u8 = 0,
    b: u8 = 0,
    a: u8 = 0xFF,

    pub fn rgb(r: u8, g: u8, b: u8) Color {
        return .{ .r = r, .g = g, .b = b, .a = 0xFF };
    }
};

pub const FontMetrics = struct {
    char_width: f32 = 7.0,
    line_height: f32 = 16.0,

    pub fn defaults() FontMetrics {
        return .{};
    }
};

pub const Rect = struct {
    x: f32 = 0,
    y: f32 = 0,
    width: f32 = 0,
    height: f32 = 0,
};

pub const Size = struct {
    width: f32,
    height: f32,
};

pub fn max(a: f32, b: f32) f32 {
    return if (a > b) a else b;
}

pub fn clampToAvailable(value: f32, available: ?f32) f32 {
    if (available) |limit| {
        if (value > limit) return limit;
    }
    return value;
}

pub fn sanitize(value: f32) f32 {
    return if (value < 0) 0 else value;
}

pub fn subtractInsets(value: ?f32, amount: f32) ?f32 {
    if (value) |limit| {
        const remaining = limit - amount;
        if (remaining <= 0) return 0;
        return remaining;
    }
    return null;
}

pub fn resolveDimension(spec: SizeSpec, wrap_size: f32, available: ?f32) f32 {
    return switch (spec) {
        .wrap_content => clampToAvailable(wrap_size, available),
        .match_parent => available orelse clampToAvailable(wrap_size, available),
        .exact => |value| clampToAvailable(value, available),
    };
}
