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
        .bottom_right => {
            rc.right += delta.x;
            rc.bottom += delta.y;
        },
        .center => {
            // AltSnap-style all-directions scaling around the center
            rc.left -= delta.x;
            rc.right += delta.x;
            rc.top -= delta.y;
            rc.bottom += delta.y;
        },
    }

    if (rc.width() < min_w) {
        switch (sector) {
            .left, .top_left, .bottom_left => rc.left = rc.right - min_w,
            .center => {
                const mid_x = @divTrunc(start_bounds.left + start_bounds.right, 2);
                rc.left = mid_x - @divTrunc(min_w, 2);
                rc.right = rc.left + min_w;
            },
            else => rc.right = rc.left + min_w,
        }
    }
    if (rc.height() < min_h) {
        switch (sector) {
            .top, .top_left, .top_right => rc.top = rc.bottom - min_h,
            .center => {
                const mid_y = @divTrunc(start_bounds.top + start_bounds.bottom, 2);
                rc.top = mid_y - @divTrunc(min_h, 2);
                rc.bottom = rc.top + min_h;
            },
            else => rc.bottom = rc.top + min_h,
        }
    }

    return rc;
}

pub fn snapMoveBounds(bounds: Rect, wa: Rect, threshold: i32) Rect {
    var res = bounds;
    const w = bounds.width();
    const h = bounds.height();

    if (@abs(bounds.left - wa.left) <= threshold) {
        res.left = wa.left;
        res.right = wa.left + w;
    } else if (@abs(bounds.right - wa.right) <= threshold) {
        res.right = wa.right;
        res.left = wa.right - w;
    }

    if (@abs(bounds.top - wa.top) <= threshold) {
        res.top = wa.top;
        res.bottom = wa.top + h;
    } else if (@abs(bounds.bottom - wa.bottom) <= threshold) {
        res.bottom = wa.bottom;
        res.top = wa.bottom - h;
    }

    return res;
}

pub fn snapResizeBounds(bounds: Rect, wa: Rect, sector: Sector, threshold: i32) Rect {
    var res = bounds;

    switch (sector) {
        .left, .top_left, .bottom_left, .center => {
            if (@abs(res.left - wa.left) <= threshold) res.left = wa.left;
        },
        else => {},
    }

    switch (sector) {
        .right, .top_right, .bottom_right, .center => {
            if (@abs(res.right - wa.right) <= threshold) res.right = wa.right;
        },
        else => {},
    }

    switch (sector) {
        .top, .top_left, .top_right, .center => {
            if (@abs(res.top - wa.top) <= threshold) res.top = wa.top;
        },
        else => {},
    }

    switch (sector) {
        .bottom, .bottom_left, .bottom_right, .center => {
            if (@abs(res.bottom - wa.bottom) <= threshold) res.bottom = wa.bottom;
        },
        else => {},
    }

    return res;
}

test "calculateSector 3x3 division" {
    try std.testing.expectEqual(Sector.top_left, calculateSector(300, 300, 10, 10));
    try std.testing.expectEqual(Sector.center, calculateSector(300, 300, 150, 150));
    try std.testing.expectEqual(Sector.bottom_right, calculateSector(300, 300, 290, 290));
}

test "calculateSector degrades to center on zero or negative extents" {
    try std.testing.expectEqual(Sector.center, calculateSector(0, 0, 5, 5));
    try std.testing.expectEqual(Sector.center, calculateSector(-100, -50, 1, 1));
    try std.testing.expectEqual(Sector.center, calculateSector(300, 0, 10, 10));
}

test "calculateCenterRect keeps window inside work area for tiny windows" {
    const wa: Rect = .{ .left = 0, .top = 0, .right = 800, .bottom = 600 };
    const tiny: Rect = .{ .left = 0, .top = 0, .right = 40, .bottom = 30 };
    const c = calculateCenterRect(wa, tiny, .{});
    try std.testing.expectEqual(@as(i32, 380), c.left);
    try std.testing.expectEqual(@as(i32, 285), c.top);
}

test "calculateResizedRect clamp minimum dimensions" {
    const start: Rect = .{ .left = 100, .top = 100, .right = 300, .bottom = 300 };
    const delta: Point = .{ .x = -150, .y = -150 };
    const res = calculateResizedRect(start, delta, .bottom_right, 100, 100);

    try std.testing.expect(res.width() >= 100);
    try std.testing.expect(res.height() >= 100);
}

test "calculateResizedRect center all-directions expand" {
    const start: Rect = .{ .left = 100, .top = 100, .right = 300, .bottom = 300 };
    const delta: Point = .{ .x = 20, .y = 30 };
    const res = calculateResizedRect(start, delta, .center, 100, 100);

    try std.testing.expectEqual(@as(i32, 80), res.left);
    try std.testing.expectEqual(@as(i32, 320), res.right);
    try std.testing.expectEqual(@as(i32, 70), res.top);
    try std.testing.expectEqual(@as(i32, 330), res.bottom);
}

test "snapMoveBounds snaps edges within threshold preserving size" {
    const wa: Rect = .{ .left = 0, .top = 0, .right = 1920, .bottom = 1040 };
    const near_left: Rect = .{ .left = 12, .top = 500, .right = 212, .bottom = 600 };
    const snapped = snapMoveBounds(near_left, wa, 20);
    try std.testing.expectEqual(@as(i32, 0), snapped.left);
    try std.testing.expectEqual(@as(i32, 200), snapped.width());

    const far: Rect = .{ .left = 900, .top = 400, .right = 1100, .bottom = 500 };
    const untouched = snapMoveBounds(far, wa, 20);
    try std.testing.expectEqual(far, untouched);
}

test "snapResizeBounds snaps only the dragged edges" {
    const wa: Rect = .{ .left = 0, .top = 0, .right = 1920, .bottom = 1040 };
    const rc: Rect = .{ .left = 10, .top = 8, .right = 1902, .bottom = 1035 };
    const res = snapResizeBounds(rc, wa, .center, 20);
    try std.testing.expectEqual(@as(i32, 0), res.left);
    try std.testing.expectEqual(@as(i32, 0), res.top);
    try std.testing.expectEqual(@as(i32, 1920), res.right);
    try std.testing.expectEqual(@as(i32, 1040), res.bottom);

    const br_only: Rect = .{ .left = 100, .top = 100, .right = 1910, .bottom = 1050 };
    const br_res = snapResizeBounds(br_only, wa, .bottom_right, 20);
    try std.testing.expectEqual(@as(i32, 100), br_res.left);
    try std.testing.expectEqual(@as(i32, 1920), br_res.right);
    try std.testing.expectEqual(@as(i32, 1040), br_res.bottom);
}
