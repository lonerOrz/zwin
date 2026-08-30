const std = @import("std");
const geom = @import("../calc/geometry.zig");
const UserIntent = @import("intent.zig").UserIntent;

/// 8-bit compact modifier key bitmask, supports Win (Super), Ctrl, Alt, Shift in any combination
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

pub const MouseTrigger = enum {
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
            // Mouse streaming actions are handled by the state machine, not transient discrete Intents
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

    pub fn toString(self: Action) []const u8 {
        return @tagName(self);
    }
};

pub const Binding = struct {
    mods: ModifierMask = .{},
    trigger: Trigger,
    action: Action,
};
