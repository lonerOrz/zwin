const std = @import("std");
const Language = @import("../infra/i18n.zig").Language;
const Color = @import("color.zig").Color;

pub const Config = struct {
    // Language setting
    language: Language = .auto,

    // Keyboard window movement step
    move_step: i32 = 20,

    // Base hotkeys: Alt + Key
    key_center: u32 = 'C',
    key_topmost: u32 = 'T',
    key_close: u32 = 'Q',
    key_maximize: u32 = 'M',
    key_restore_min: u32 = 'N',
    key_focus_left: u32 = 'H',
    key_focus_down: u32 = 'J',
    key_focus_up: u32 = 'K',
    key_focus_right: u32 = 'L',

    // Window movement hotkeys: Alt + Shift + Key
    key_move_left: u32 = 'H',
    key_move_down: u32 = 'J',
    key_move_up: u32 = 'K',
    key_move_right: u32 = 'L',

    // Feature toggles
    enable_border: bool = true,
    enable_wheel_opacity: bool = true,
    enable_autostart: bool = false,
    enable_elevated: bool = false,
    enable_window_snap: bool = true,

    // Thresholds and steps
    snap_threshold: i32 = 18,
    opacity_step: u8 = 15,

    // Appearance and limits
    active_border_color: Color = Color.rgb(255, 136, 0),
    min_window_width: i32 = 120,
    min_window_height: i32 = 100,
    log_max_days: u32 = 7,

    // Blacklist filters
    ignore_processes: []const []const u8 = &.{},
    ignore_classes: []const []const u8 = &.{},

    pub fn deinit(self: *Config, allocator: std.mem.Allocator) void {
        for (self.ignore_processes) |item| allocator.free(item);
        if (self.ignore_processes.len > 0) allocator.free(self.ignore_processes);

        for (self.ignore_classes) |item| allocator.free(item);
        if (self.ignore_classes.len > 0) allocator.free(self.ignore_classes);

        self.ignore_processes = &.{};
        self.ignore_classes = &.{};
    }
};
