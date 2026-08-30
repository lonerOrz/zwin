const std = @import("std");
const t = @import("../platform/win32.zig");
const geom = @import("../calc/geometry.zig");

// ─── Color ───────────────────────────────────────────────────────────────────

pub const Color = struct {
    r: u8,
    g: u8,
    b: u8,

    pub fn rgb(r: u8, g: u8, b: u8) Color {
        return .{ .r = r, .g = g, .b = b };
    }

    pub inline fn toColorRef(self: Color) u32 {
        return @as(u32, self.r) | (@as(u32, self.g) << 8) | (@as(u32, self.b) << 16);
    }

    pub fn fromColorRef(cref: u32) Color {
        return .{
            .r = @truncate(cref & 0xFF),
            .g = @truncate((cref >> 8) & 0xFF),
            .b = @truncate((cref >> 16) & 0xFF),
        };
    }

    pub fn toHex(self: Color, buf: *[7]u8) []const u8 {
        return std.fmt.bufPrint(buf, "#{X:0>2}{X:0>2}{X:0>2}", .{ self.r, self.g, self.b }) catch unreachable;
    }

    pub fn fromHex(hex: []const u8) ?Color {
        var str = hex;
        if (std.mem.startsWith(u8, str, "#")) str = str[1..];
        if (str.len != 6) return null;
        const rgb_val = std.fmt.parseInt(u24, str, 16) catch return null;
        return .{
            .r = @truncate((rgb_val >> 16) & 0xFF),
            .g = @truncate((rgb_val >> 8) & 0xFF),
            .b = @truncate(rgb_val & 0xFF),
        };
    }
};

// ─── ModifierMask ─────────────────────────────────────────────────────────────

pub const ModifierMask = packed struct(u8) {
    alt: bool = false,
    ctrl: bool = false,
    shift: bool = false,
    win: bool = false,
    _pad: u4 = 0,

    pub inline fn isEmpty(self: ModifierMask) bool {
        return @as(u8, @bitCast(self)) == 0;
    }

    pub inline fn eql(self: ModifierMask, other: ModifierMask) bool {
        return @as(u8, @bitCast(self)) == @as(u8, @bitCast(other));
    }

    pub inline fn contains(self: ModifierMask, other: ModifierMask) bool {
        const a = @as(u8, @bitCast(self));
        const b = @as(u8, @bitCast(other));
        return (a & b) == b;
    }
};

// ─── Trigger / Action / Binding ────────────────────────────────────────────────

pub const MouseTrigger = enum(u2) {
    left,
    right,
    middle,
    wheel,
};

pub const Trigger = union(enum) {
    key: u32,
    mouse: MouseTrigger,
};

pub const Action = enum {
    focus_left,
    focus_right,
    focus_up,
    focus_down,
    move_left,
    move_right,
    move_up,
    move_down,
    center,
    toggle_topmost,
    toggle_maximize,
    restore_last_minimized,
    close,
    drag_move,
    drag_resize,
    adjust_opacity,
    minimize,

    pub fn toUserIntent(self: Action) ?UserIntent {
        return switch (self) {
            .focus_left => .{ .focus_direction = .left },
            .focus_right => .{ .focus_direction = .right },
            .focus_up => .{ .focus_direction = .up },
            .focus_down => .{ .focus_direction = .down },
            .move_left => .{ .move_window_direction = .left },
            .move_right => .{ .move_window_direction = .right },
            .move_up => .{ .move_window_direction = .up },
            .move_down => .{ .move_window_direction = .down },
            .center => .center_active_window,
            .toggle_topmost => .toggle_active_topmost,
            .toggle_maximize => .toggle_active_maximize,
            .restore_last_minimized => .restore_last_minimized,
            .close => .close_active_window,
            .drag_move, .drag_resize, .adjust_opacity, .minimize => null,
        };
    }

    pub fn fromString(str: []const u8) ?Action {
        const map = std.StaticStringMap(Action).initComptime(.{
            .{ "focus_left", .focus_left },
            .{ "focus_right", .focus_right },
            .{ "focus_up", .focus_up },
            .{ "focus_down", .focus_down },
            .{ "move_left", .move_left },
            .{ "move_right", .move_right },
            .{ "move_up", .move_up },
            .{ "move_down", .move_down },
            .{ "center", .center },
            .{ "toggle_topmost", .toggle_topmost },
            .{ "toggle_maximize", .toggle_maximize },
            .{ "restore_last_minimized", .restore_last_minimized },
            .{ "close", .close },
            .{ "drag_move", .drag_move },
            .{ "drag_resize", .drag_resize },
            .{ "adjust_opacity", .adjust_opacity },
            .{ "minimize", .minimize },
        });
        return map.get(str);
    }
};

pub const Binding = struct {
    mods: ModifierMask = .{},
    trigger: Trigger,
    action: Action,
};

// ─── UserIntent ────────────────────────────────────────────────────────────────

pub const UserIntent = union(enum) {
    center_active_window,
    toggle_active_topmost,
    toggle_active_maximize,
    close_active_window,
    restore_last_minimized,
    focus_direction: geom.Direction,
    move_window_direction: geom.Direction,
    abort_gesture,
    minimize_at: struct { pt: geom.Point },
    adjust_opacity_at: struct { pt: geom.Point, delta: i32 },
    foreground_changed: t.HWND,
    window_closed_or_hidden: t.HWND,
};

// ─── WindowTarget ──────────────────────────────────────────────────────────────

pub const WindowTarget = struct {
    hwnd: t.HWND,
    session_id: u64,

    pub inline fn isValid(self: WindowTarget, current_active_session: u64) bool {
        return self.session_id == current_active_session and t.IsWindow(self.hwnd) != 0;
    }
};

test "Color conversions" {
    const c = Color.fromHex("#FF8800").?;
    try std.testing.expectEqual(@as(u8, 0xFF), c.r);
    try std.testing.expectEqual(@as(u8, 0x88), c.g);
    try std.testing.expectEqual(@as(u8, 0x00), c.b);
    try std.testing.expectEqual(@as(u32, 0x000088FF), c.toColorRef());
    try std.testing.expectEqual(Color.fromColorRef(0x000088FF), c);

    var buf: [7]u8 = undefined;
    try std.testing.expectEqualStrings("#FF8800", c.toHex(&buf));

    try std.testing.expectEqual(Color.rgb(1, 2, 3), Color.fromHex("010203").?);
    try std.testing.expectEqual(@as(?Color, null), Color.fromHex("#XYZ"));
    try std.testing.expectEqual(@as(?Color, null), Color.fromHex("#12345"));
}

test "ModifierMask bit ops" {
    const m1: ModifierMask = .{ .alt = true, .ctrl = false };
    const m2: ModifierMask = .{ .alt = true, .ctrl = true };
    try std.testing.expect(!m1.isEmpty());
    try std.testing.expect(m1.eql(m1));
    try std.testing.expect(!m1.eql(m2));
    try std.testing.expect(m2.contains(m1));
    try std.testing.expect(!m1.contains(m2));
}

test "Action.fromString roundtrip" {
    const actions = [_]Action{
        .focus_left, .focus_right,    .focus_up,        .focus_down,
        .move_left,  .move_right,     .move_up,         .move_down,
        .center,     .toggle_topmost, .toggle_maximize, .restore_last_minimized,
        .close,      .drag_move,      .drag_resize,     .adjust_opacity,
        .minimize,
    };
    for (actions) |a| {
        try std.testing.expectEqual(a, Action.fromString(@tagName(a)).?);
    }
}
