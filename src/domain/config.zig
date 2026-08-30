const std = @import("std");
const Language = @import("../infra/i18n.zig").Language;
const types = @import("types.zig");
const Color = types.Color;
const Binding = types.Binding;
const ModifierMask = types.ModifierMask;
const MouseTrigger = types.MouseTrigger;
const Action = types.Action;

pub const Config = struct {
    language: Language = .auto,
    autostart: bool = false,
    run_as_admin: bool = false,
    log_retention_days: u32 = 7,

    move_step: i32 = 20,
    opacity_step: u8 = 15,
    window_snap: bool = true,
    snap_threshold: i32 = 18,
    min_width: i32 = 120,
    min_height: i32 = 100,

    border: bool = true,
    border_color: Color = Color.rgb(255, 136, 0),

    ignore_processes: []const []const u8 = &.{},
    ignore_classes: []const []const u8 = &.{},

    bindings: []const Binding = &.{},
    active_modifiers_union: ModifierMask = .{},

    pub fn updateActiveModifiersUnion(self: *Config) void {
        var raw_union: u8 = 0;
        for (self.bindings) |b| {
            raw_union |= @as(u8, @bitCast(b.mods));
        }
        self.active_modifiers_union = @as(ModifierMask, @bitCast(raw_union));
    }

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

    pub fn matchMouseBinding(self: *const Config, current_mods: ModifierMask, trigger: MouseTrigger) ?Action {
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
