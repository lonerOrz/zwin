const std = @import("std");

pub const Point = struct {
    x: i32,
    y: i32,
};

pub const Rect = struct {
    left: i32,
    top: i32,
    right: i32,
    bottom: i32,

    pub fn width(self: Rect) i32 {
        return self.right - self.left;
    }

    pub fn height(self: Rect) i32 {
        return self.bottom - self.top;
    }
};

pub const Padding = struct {
    l: i32 = 0,
    t: i32 = 0,
    r: i32 = 0,
    b: i32 = 0,
};

pub const Sector = enum {
    top_left,
    top,
    top_right,
    left,
    center,
    right,
    bottom_left,
    bottom,
    bottom_right,
};

pub fn calculateSector(w: i32, h: i32, rx: i32, ry: i32) Sector {
    if (w <= 0 or h <= 0) return .center;
    const col: i32 = if (rx < @divTrunc(w, 3)) 0 else if (rx >= w - @divTrunc(w, 3)) 2 else 1;
    const row: i32 = if (ry < @divTrunc(h, 3)) 0 else if (ry >= h - @divTrunc(h, 3)) 2 else 1;
    return switch (row * 3 + col) {
        0 => .top_left,
        1 => .top,
        2 => .top_right,
        3 => .left,
        4 => .center,
        5 => .right,
        6 => .bottom_left,
        7 => .bottom,
        8 => .bottom_right,
        else => .center,
    };
}

pub fn calculateCenterRect(work_area: Rect, win_bounds: Rect, pad: Padding) Rect {
    const w = win_bounds.width();
    const h = win_bounds.height();
    const work_w = work_area.width();
    const work_h = work_area.height();

    const target_x = work_area.left + @divTrunc(work_w - w, 2) - pad.l;
    const target_y = work_area.top + @divTrunc(work_h - h, 2) - pad.t;

    return .{
        .left = target_x,
        .top = target_y,
        .right = target_x + w + pad.l + pad.r,
        .bottom = target_y + h + pad.t + pad.b,
    };
}

pub fn calculateResizedRect(
    start_bounds: Rect,
    delta: Point,
    sector: Sector,
    min_w: i32,
    min_h: i32,
) Rect {
    var rc = start_bounds;

    switch (sector) {
        .top_left => {
            rc.left += delta.x;
            rc.top += delta.y;
        },
        .top => {
            rc.top += delta.y;
        },
        .top_right => {
            rc.right += delta.x;
            rc.top += delta.y;
        },
        .left => {
            rc.left += delta.x;
        },
        .right => {
            rc.right += delta.x;
        },
        .bottom_left => {
            rc.left += delta.x;
            rc.bottom += delta.y;
        },
        .bottom => {
            rc.bottom += delta.y;
        },
        .bottom_right, .center => {
            rc.right += delta.x;
            rc.bottom += delta.y;
        },
    }

    if (rc.width() < min_w) {
        switch (sector) {
            .left, .top_left, .bottom_left => rc.left = rc.right - min_w,
            else => rc.right = rc.left + min_w,
        }
    }
    if (rc.height() < min_h) {
        switch (sector) {
            .top, .top_left, .top_right => rc.top = rc.bottom - min_h,
            else => rc.bottom = rc.top + min_h,
        }
    }

    return rc;
}

test "calculateSector 3x3 division" {
    try std.testing.expectEqual(Sector.top_left, calculateSector(300, 300, 10, 10));
    try std.testing.expectEqual(Sector.center, calculateSector(300, 300, 150, 150));
    try std.testing.expectEqual(Sector.bottom_right, calculateSector(300, 300, 290, 290));
}

test "calculateResizedRect clamp minimum dimensions" {
    const start: Rect = .{ .left = 100, .top = 100, .right = 300, .bottom = 300 };
    const delta: Point = .{ .x = -150, .y = -150 };
    const res = calculateResizedRect(start, delta, .bottom_right, 100, 100);

    try std.testing.expect(res.width() >= 100);
    try std.testing.expect(res.height() >= 100);
}
