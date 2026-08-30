const std = @import("std");
const Language = @import("../infra/i18n.zig").Language;
const Color = @import("color.zig").Color;
const binding = @import("binding.zig");
const Binding = binding.Binding;
const ModifierMask = binding.ModifierMask;
const Trigger = binding.Trigger;
const Action = binding.Action;

pub const Config = struct {
    language: Language = .auto,
    move_step: i32 = 20,
    snap_threshold: i32 = 18,
    opacity_step: u8 = 15,

    enable_border: bool = true,
    enable_wheel_opacity: bool = true,
    enable_autostart: bool = false,
    enable_elevated: bool = false,
    enable_window_snap: bool = true,

    active_border_color: Color = Color.rgb(255, 136, 0),
    min_window_width: i32 = 120,
    min_window_height: i32 = 100,
    log_max_days: u32 = 7,

    ignore_processes: []const []const u8 = &.{},
    ignore_classes: []const []const u8 = &.{},

    bindings: []const Binding = &.{},

    // Union of all modifiers used across every binding (for fast pruning)
    active_modifiers_union: ModifierMask = .{},

    pub fn updateActiveModifiersUnion(self: *Config) void {
        var raw_union: u8 = 0;
        for (self.bindings) |b| {
            raw_union |= @as(u8, @bitCast(b.mods));
        }
        self.active_modifiers_union = @as(ModifierMask, @bitCast(raw_union));
    }

    /// If the currently pressed modifiers share no bits with any configured rule, the low-level hook can let it through immediately
    pub inline fn hasMatchingModifierSubset(self: *const Config, current: ModifierMask) bool {
        const u = @as(u8, @bitCast(self.active_modifiers_union));
        const c = @as(u8, @bitCast(current));
        return (u & c) != 0;
    }

    pub fn matchKeyBinding(self: *const Config, current_mods: ModifierMask, vk: u32) ?Action {
        for (self.bindings) |b| {
            if (b.mods.eql(current_mods)) {
                switch (b.trigger) {
                    .key => |target_vk| if (target_vk == vk) return b.action,
                    else => {},
                }
            }
        }
        return null;
    }

    pub fn matchMouseBinding(self: *const Config, current_mods: ModifierMask, trigger: binding.MouseTrigger) ?Action {
        for (self.bindings) |b| {
            if (b.mods.eql(current_mods)) {
                switch (b.trigger) {
                    .mouse => |m| if (m == trigger) return b.action,
                    else => {},
                }
            }
        }
        return null;
    }

    pub fn deinit(self: *Config, allocator: std.mem.Allocator) void {
        for (self.ignore_processes) |item| allocator.free(item);
        if (self.ignore_processes.len > 0) allocator.free(self.ignore_processes);

        for (self.ignore_classes) |item| allocator.free(item);
        if (self.ignore_classes.len > 0) allocator.free(self.ignore_classes);

        if (self.bindings.len > 0) allocator.free(self.bindings);

        self.ignore_processes = &.{};
        self.ignore_classes = &.{};
        self.bindings = &.{};
    }
};
