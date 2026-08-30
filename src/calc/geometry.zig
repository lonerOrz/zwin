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

    pub inline fn width(self: Rect) i32 {
        return self.right - self.left;
    }

    pub inline fn height(self: Rect) i32 {
        return self.bottom - self.top;
    }

    pub inline fn centerX(self: Rect) i32 {
        return self.left + @divTrunc(self.width(), 2);
    }

    pub inline fn centerY(self: Rect) i32 {
        return self.top + @divTrunc(self.height(), 2);
    }
};

pub const Padding = struct {
    l: i32 = 0,
    t: i32 = 0,
    r: i32 = 0,
    b: i32 = 0,
};

pub const Direction = enum {
    left,
    down,
    up,
    right,

    /// Computes a displacement vector from direction and step size.
    pub inline fn toVector(self: Direction, step: i32) Point {
        return switch (self) {
            .left => .{ .x = -step, .y = 0 },
            .right => .{ .x = step, .y = 0 },
            .up => .{ .x = 0, .y = -step },
            .down => .{ .x = 0, .y = step },
        };
    }
};

/// Translates a rectangle by a point.
pub inline fn offsetRect(rc: Rect, pt: Point) Rect {
    return .{
        .left = rc.left + pt.x,
        .top = rc.top + pt.y,
        .right = rc.right + pt.x,
        .bottom = rc.bottom + pt.y,
    };
}

pub const max_snap_targets: usize = 32;

pub const SnapTargetList = struct {
    rects: [max_snap_targets]Rect = undefined,
    len: usize = 0,

    pub fn append(self: *SnapTargetList, rc: Rect) void {
        if (self.len < max_snap_targets) {
            self.rects[self.len] = rc;
            self.len += 1;
        }
    }

    pub fn slice(self: *const SnapTargetList) []const Rect {
        return self.rects[0..self.len];
    }
};

pub const Sector = enum(u4) {
    top_left = 0,
    top = 1,
    top_right = 2,
    left = 3,
    center = 4,
    right = 5,
    bottom_left = 6,
    bottom = 7,
    bottom_right = 8,

    pub fn toWmsz(self: Sector) usize {
        return switch (self) {
            .top_left => 4,
            .top => 3,
            .top_right => 5,
            .left => 1,
            .center, .bottom_right => 8,
            .right => 2,
            .bottom_left => 7,
            .bottom => 6,
        };
    }

    pub fn cursorResourceId(self: Sector) usize {
        return switch (self) {
            .top_left, .bottom_right => 32642, // IDC_SIZENWSE
            .top_right, .bottom_left => 32643, // IDC_SIZENESW
            .left, .right => 32644, // IDC_SIZEWE
            .top, .bottom => 32645, // IDC_SIZENS
            .center => 32646, // IDC_SIZEALL
        };
    }
};

// Map click point to 3x3 sectors; fallback to center on invalid dimensions
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

// Center window within work area taking shadow padding into account
pub fn calculateCenterRect(work_area: Rect, win_bounds: Rect, pad: Padding) Rect {
    const w = win_bounds.width();
    const h = win_bounds.height();
    const target_x = work_area.left + @divTrunc(work_area.width() - w, 2) - pad.l;
    const target_y = work_area.top + @divTrunc(work_area.height() - h, 2) - pad.t;

    return .{
        .left = target_x,
        .top = target_y,
        .right = target_x + w + pad.l + pad.r,
        .bottom = target_y + h + pad.t + pad.b,
    };
}

// Calculate resized bounds by sector and clamp to minimum dimensions
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
            // Expand in all directions from center
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

// Check if two ranges [a1, a2] and [b1, b2] overlap or are near each other
inline fn isNearOrOverlap(a1: i32, a2: i32, b1: i32, b2: i32, tolerance: i32) bool {
    return (a1 <= b2 + tolerance) and (a2 >= b1 - tolerance);
}

// Snap moving window edges to work area AND other window boundaries
// Collect snap targets once at gesture start; called 0 times on the hot path.
pub fn snapMoveBoundsEx(
    bounds: Rect,
    wa: ?Rect,
    other_windows: []const Rect,
    threshold: i32,
    enable_window_snap: bool,
) Rect {
    var res = bounds;
    const w = bounds.width();
    const h = bounds.height();

    var best_dx: ?i32 = null;
    var min_dist_x: u32 = @as(u32, @intCast(@max(threshold, 0))) + 1;

    var best_dy: ?i32 = null;
    var min_dist_y: u32 = @as(u32, @intCast(@max(threshold, 0))) + 1;

    // 1. Work area edge snapping
    if (wa) |area| {
        const d_left_x = bounds.left - area.left;
        if (@abs(d_left_x) < min_dist_x) {
            min_dist_x = @abs(d_left_x);
            best_dx = area.left - bounds.left;
        }
        const d_right_x = bounds.right - area.right;
        if (@abs(d_right_x) < min_dist_x) {
            min_dist_x = @abs(d_right_x);
            best_dx = area.right - bounds.right;
        }
        const d_top_y = bounds.top - area.top;
        if (@abs(d_top_y) < min_dist_y) {
            min_dist_y = @abs(d_top_y);
            best_dy = area.top - bounds.top;
        }
        const d_bottom_y = bounds.bottom - area.bottom;
        if (@abs(d_bottom_y) < min_dist_y) {
            min_dist_y = @abs(d_bottom_y);
            best_dy = area.bottom - bounds.bottom;
        }
    }

    // 2. Magnetic snapping to other windows
    if (enable_window_snap) {
        for (other_windows) |other| {
            // Check Y overlap for X-axis snapping
            if (isNearOrOverlap(bounds.top, bounds.bottom, other.top, other.bottom, threshold)) {
                const d1: u32 = @abs(bounds.left - other.right);
                if (d1 < min_dist_x) {
                    min_dist_x = d1;
                    best_dx = other.right - bounds.left;
                }
                const d2: u32 = @abs(bounds.right - other.left);
                if (d2 < min_dist_x) {
                    min_dist_x = d2;
                    best_dx = other.left - bounds.right;
                }
                const d3: u32 = @abs(bounds.left - other.left);
                if (d3 < min_dist_x) {
                    min_dist_x = d3;
                    best_dx = other.left - bounds.left;
                }
                const d4: u32 = @abs(bounds.right - other.right);
                if (d4 < min_dist_x) {
                    min_dist_x = d4;
                    best_dx = other.right - bounds.right;
                }
            }

            // Check X overlap for Y-axis snapping
            if (isNearOrOverlap(bounds.left, bounds.right, other.left, other.right, threshold)) {
                const d1: u32 = @abs(bounds.top - other.bottom);
                if (d1 < min_dist_y) {
                    min_dist_y = d1;
                    best_dy = other.bottom - bounds.top;
                }
                const d2: u32 = @abs(bounds.bottom - other.top);
                if (d2 < min_dist_y) {
                    min_dist_y = d2;
                    best_dy = other.top - bounds.bottom;
                }
                const d3: u32 = @abs(bounds.top - other.top);
                if (d3 < min_dist_y) {
                    min_dist_y = d3;
                    best_dy = other.top - bounds.top;
                }
                const d4: u32 = @abs(bounds.bottom - other.bottom);
                if (d4 < min_dist_y) {
                    min_dist_y = d4;
                    best_dy = other.bottom - bounds.bottom;
                }
            }
        }
    }

    if (best_dx) |dx| {
        res.left += dx;
        res.right = res.left + w;
    }
    if (best_dy) |dy| {
        res.top += dy;
        res.bottom = res.top + h;
    }

    return res;
}

// Snap resizing window edges to work area AND other window boundaries
pub fn snapResizeBoundsEx(
    bounds: Rect,
    wa: ?Rect,
    other_windows: []const Rect,
    sector: Sector,
    threshold: i32,
    enable_window_snap: bool,
) Rect {
    var res = bounds;

    if (wa) |area| {
        switch (sector) {
            .left, .top_left, .bottom_left, .center => {
                if (@abs(res.left - area.left) <= threshold) res.left = area.left;
            },
            else => {},
        }
        switch (sector) {
            .right, .top_right, .bottom_right, .center => {
                if (@abs(res.right - area.right) <= threshold) res.right = area.right;
            },
            else => {},
        }
        switch (sector) {
            .top, .top_left, .top_right, .center => {
                if (@abs(res.top - area.top) <= threshold) res.top = area.top;
            },
            else => {},
        }
        switch (sector) {
            .bottom, .bottom_left, .bottom_right, .center => {
                if (@abs(res.bottom - area.bottom) <= threshold) res.bottom = area.bottom;
            },
            else => {},
        }
    }

    if (enable_window_snap) {
        for (other_windows) |other| {
            switch (sector) {
                .left, .top_left, .bottom_left => {
                    if (isNearOrOverlap(res.top, res.bottom, other.top, other.bottom, threshold)) {
                        if (@abs(res.left - other.right) <= threshold) res.left = other.right;
                        if (@abs(res.left - other.left) <= threshold) res.left = other.left;
                    }
                },
                .right, .top_right, .bottom_right => {
                    if (isNearOrOverlap(res.top, res.bottom, other.top, other.bottom, threshold)) {
                        if (@abs(res.right - other.left) <= threshold) res.right = other.left;
                        if (@abs(res.right - other.right) <= threshold) res.right = other.right;
                    }
                },
                else => {},
            }
            switch (sector) {
                .top, .top_left, .top_right => {
                    if (isNearOrOverlap(res.left, res.right, other.left, other.right, threshold)) {
                        if (@abs(res.top - other.bottom) <= threshold) res.top = other.bottom;
                        if (@abs(res.top - other.top) <= threshold) res.top = other.top;
                    }
                },
                .bottom, .bottom_left, .bottom_right => {
                    if (isNearOrOverlap(res.left, res.right, other.left, other.right, threshold)) {
                        if (@abs(res.bottom - other.top) <= threshold) res.bottom = other.top;
                        if (@abs(res.bottom - other.bottom) <= threshold) res.bottom = other.bottom;
                    }
                },
                else => {},
            }
        }
    }

    return res;
}

/// Clamps a rectangle within the monitor's work area boundary.
pub fn clampRectToWorkArea(rc: Rect, wa: Rect) Rect {
    const w = rc.width();
    const h = rc.height();
    var left = rc.left;
    var top = rc.top;

    if (w <= wa.width()) {
        left = std.math.clamp(left, wa.left, wa.right - w);
    } else {
        left = wa.left;
    }

    if (h <= wa.height()) {
        top = std.math.clamp(top, wa.top, wa.bottom - h);
    } else {
        top = wa.top;
    }

    return .{
        .left = left,
        .top = top,
        .right = left + w,
        .bottom = top + h,
    };
}

// Distance score for directional navigation: lower is better.
// Returns null when the candidate is not in the requested direction.
pub fn scoreDirectionalCandidate(current: Rect, candidate: Rect, dir: Direction) ?i64 {
    const cur_cx = current.centerX();
    const cur_cy = current.centerY();
    const cand_cx = candidate.centerX();
    const cand_cy = candidate.centerY();

    const dx = cand_cx - cur_cx;
    const dy = cand_cy - cur_cy;

    switch (dir) {
        .left => {
            if (dx >= -10) return null;
            const primary: i64 = @abs(dx);
            const secondary: i64 = @abs(dy);
            return primary + secondary * 2;
        },
        .right => {
            if (dx <= 10) return null;
            const primary: i64 = @abs(dx);
            const secondary: i64 = @abs(dy);
            return primary + secondary * 2;
        },
        .up => {
            if (dy >= -10) return null;
            const primary: i64 = @abs(dy);
            const secondary: i64 = @abs(dx);
            return primary + secondary * 2;
        },
        .down => {
            if (dy <= 10) return null;
            const primary: i64 = @abs(dy);
            const secondary: i64 = @abs(dx);
            return primary + secondary * 2;
        },
    }
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

test "Window to window magnetic snapping" {
    const wa: Rect = .{ .left = 0, .top = 0, .right = 1920, .bottom = 1080 };
    const win_a: Rect = .{ .left = 100, .top = 100, .right = 500, .bottom = 600 };
    const others = [_]Rect{win_a};

    const moving_b: Rect = .{ .left = 508, .top = 120, .right = 908, .bottom = 620 };
    const snapped = snapMoveBoundsEx(moving_b, wa, &others, 15, true);

    try std.testing.expectEqual(@as(i32, 500), snapped.left);
    try std.testing.expectEqual(@as(i32, 900), snapped.right);
}

test "Directional candidate scoring" {
    const cur: Rect = .{ .left = 500, .top = 500, .right = 700, .bottom = 700 };
    const left_win: Rect = .{ .left = 100, .top = 500, .right = 300, .bottom = 700 };
    const right_win: Rect = .{ .left = 900, .top = 500, .right = 1100, .bottom = 700 };

    try std.testing.expect(scoreDirectionalCandidate(cur, left_win, .left) != null);
    try std.testing.expect(scoreDirectionalCandidate(cur, left_win, .right) == null);
    try std.testing.expect(scoreDirectionalCandidate(cur, right_win, .right) != null);
    try std.testing.expect(scoreDirectionalCandidate(cur, right_win, .left) == null);
}

test "Rect centerX/centerY" {
    const r: Rect = .{ .left = 100, .top = 200, .right = 300, .bottom = 400 };
    try std.testing.expectEqual(@as(i32, 200), r.centerX());
    try std.testing.expectEqual(@as(i32, 300), r.centerY());
}

test "SnapTargetList capacity and slice" {
    var list = SnapTargetList{};
    try std.testing.expectEqual(@as(usize, 0), list.len);
    list.append(.{ .left = 0, .top = 0, .right = 100, .bottom = 100 });
    try std.testing.expectEqual(@as(usize, 1), list.len);
    try std.testing.expectEqual(@as(i32, 0), list.slice()[0].left);
}

test "SnapTargetList respects max capacity" {
    var list = SnapTargetList{};
    var i: usize = 0;
    while (i < max_snap_targets + 5) : (i += 1) {
        list.append(.{ .left = @intCast(i), .top = 0, .right = @intCast(i + 10), .bottom = 0 });
    }
    try std.testing.expectEqual(max_snap_targets, list.len);
}

test "snapResizeBoundsEx snaps to adjacent window edge" {
    const wa: Rect = .{ .left = 0, .top = 0, .right = 1920, .bottom = 1080 };
    const win_a: Rect = .{ .left = 0, .top = 0, .right = 900, .bottom = 1080 };
    const others = [_]Rect{win_a};

    const rc: Rect = .{ .left = 908, .top = 100, .right = 1008, .bottom = 500 };
    const snapped = snapResizeBoundsEx(rc, wa, &others, .left, 15, true);
    try std.testing.expectEqual(@as(i32, 900), snapped.left);
}

test "snapMoveBoundsEx with no snap targets is identity at distance" {
    const wa: Rect = .{ .left = 0, .top = 0, .right = 1920, .bottom = 1080 };
    const far: Rect = .{ .left = 500, .top = 300, .right = 700, .bottom = 500 };
    const others: [0]Rect = undefined;
    const result = snapMoveBoundsEx(far, wa, &others, 15, true);
    try std.testing.expectEqual(far, result);
}

/// Matches text against a wildcard pattern supporting '*' (any chars) and '?' (single char).
/// Case-insensitive, iterative, zero-allocation.
pub fn matchGlob(pattern: []const u8, text: []const u8) bool {
    var p_idx: usize = 0;
    var t_idx: usize = 0;
    var star_idx: ?usize = null;
    var match_idx: usize = 0;

    while (t_idx < text.len) {
        if (p_idx < pattern.len and (pattern[p_idx] == '?' or std.ascii.toLower(pattern[p_idx]) == std.ascii.toLower(text[t_idx]))) {
            p_idx += 1;
            t_idx += 1;
        } else if (p_idx < pattern.len and pattern[p_idx] == '*') {
            star_idx = p_idx;
            match_idx = t_idx;
            p_idx += 1;
        } else if (star_idx) |s_idx| {
            p_idx = s_idx + 1;
            match_idx += 1;
            t_idx = match_idx;
        } else {
            return false;
        }
    }

    while (p_idx < pattern.len and pattern[p_idx] == '*') {
        p_idx += 1;
    }

    return p_idx == pattern.len;
}

test "clampRectToWorkArea prevents going off-screen" {
    const wa: Rect = .{ .left = 0, .top = 0, .right = 1920, .bottom = 1080 };

    // Push past left edge
    const out_left: Rect = .{ .left = -50, .top = 100, .right = 350, .bottom = 500 };
    const clamped_l = clampRectToWorkArea(out_left, wa);
    try std.testing.expectEqual(@as(i32, 0), clamped_l.left);
    try std.testing.expectEqual(@as(i32, 400), clamped_l.width());

    // Push past right edge
    const out_right: Rect = .{ .left = 1800, .top = 100, .right = 2200, .bottom = 500 };
    const clamped_r = clampRectToWorkArea(out_right, wa);
    try std.testing.expectEqual(@as(i32, 1520), clamped_r.left);
    try std.testing.expectEqual(@as(i32, 1920), clamped_r.right);
}

test "matchGlob pattern matching" {
    try std.testing.expect(matchGlob("*.exe", "photoshop.exe"));
    try std.testing.expect(matchGlob("*.EXE", "Photoshop.exe"));
    try std.testing.expect(matchGlob("*blender*", "C:\\Program Files\\Blender Foundation\\blender.exe"));
    try std.testing.expect(matchGlob("Unity?ndClass", "UnityWndClass"));
    try std.testing.expect(!matchGlob("*.dll", "photoshop.exe"));
    try std.testing.expect(matchGlob("*", "anything"));
    try std.testing.expect(matchGlob("", ""));
    try std.testing.expect(!matchGlob("", "a"));
}
