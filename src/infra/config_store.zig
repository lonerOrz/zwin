const std = @import("std");
const Paths = @import("../platform/paths.zig").Paths;
const Config = @import("../domain/config.zig").Config;
const Color = @import("../domain/color.zig").Color;
const Language = @import("i18n.zig").Language;
const binding = @import("../domain/binding.zig");
const Binding = binding.Binding;
const ModifierMask = binding.ModifierMask;
const Trigger = binding.Trigger;
const Action = binding.Action;
const cst = @import("cst.zig");
const logger = @import("logger.zig");

// Thin writer wrapper so cst.emit can target an ArrayListUnmanaged buffer
const ArrayListWriter = struct {
    list: *std.ArrayListUnmanaged(u8),
    alloc: std.mem.Allocator,
    pub fn writeAll(self: ArrayListWriter, data: []const u8) anyerror!void {
        try self.list.appendSlice(self.alloc, data);
    }
    pub fn writeByte(self: ArrayListWriter, b: u8) anyerror!void {
        try self.list.append(self.alloc, b);
    }
    pub fn print(self: ArrayListWriter, comptime fmt: []const u8, args: anytype) anyerror!void {
        var buf: [512]u8 = undefined;
        const n = std.fmt.bufPrint(&buf, fmt, args) catch return error.OutOfMemory;
        try self.list.appendSlice(self.alloc, n);
    }
};

const VK_LEFT: u32 = 0x25;
const VK_UP: u32 = 0x26;
const VK_RIGHT: u32 = 0x27;
const VK_DOWN: u32 = 0x28;

pub const KeyParser = struct {
    pub fn parseToken(tok: []const u8, mods: *ModifierMask) ?Trigger {
        if (std.ascii.eqlIgnoreCase(tok, "alt")) {
            mods.alt = true;
            return null;
        } else if (std.ascii.eqlIgnoreCase(tok, "ctrl") or std.ascii.eqlIgnoreCase(tok, "control")) {
            mods.ctrl = true;
            return null;
        } else if (std.ascii.eqlIgnoreCase(tok, "shift")) {
            mods.shift = true;
            return null;
        } else if (std.ascii.eqlIgnoreCase(tok, "win") or std.ascii.eqlIgnoreCase(tok, "super")) {
            mods.win = true;
            return null;
        }

        // Mouse buttons
        if (std.ascii.eqlIgnoreCase(tok, "mouse_left") or std.ascii.eqlIgnoreCase(tok, "left_click")) {
            return .{ .mouse = .left };
        } else if (std.ascii.eqlIgnoreCase(tok, "mouse_right") or std.ascii.eqlIgnoreCase(tok, "right_click")) {
            return .{ .mouse = .right };
        } else if (std.ascii.eqlIgnoreCase(tok, "mouse_middle") or std.ascii.eqlIgnoreCase(tok, "middle_click")) {
            return .{ .mouse = .middle };
        } else if (std.ascii.eqlIgnoreCase(tok, "mouse_wheel") or std.ascii.eqlIgnoreCase(tok, "wheel")) {
            return .{ .mouse = .wheel };
        }

        // Arrow keys
        if (std.ascii.eqlIgnoreCase(tok, "left") or std.ascii.eqlIgnoreCase(tok, "arrowleft")) return .{ .key = VK_LEFT };
        if (std.ascii.eqlIgnoreCase(tok, "up") or std.ascii.eqlIgnoreCase(tok, "arrowup")) return .{ .key = VK_UP };
        if (std.ascii.eqlIgnoreCase(tok, "right") or std.ascii.eqlIgnoreCase(tok, "arrowright")) return .{ .key = VK_RIGHT };
        if (std.ascii.eqlIgnoreCase(tok, "down") or std.ascii.eqlIgnoreCase(tok, "arrowdown")) return .{ .key = VK_DOWN };

        // Common control & function keys
        if (std.ascii.eqlIgnoreCase(tok, "esc") or std.ascii.eqlIgnoreCase(tok, "escape")) return .{ .key = 0x1B };
        if (std.ascii.eqlIgnoreCase(tok, "tab")) return .{ .key = 0x09 };
        if (std.ascii.eqlIgnoreCase(tok, "space")) return .{ .key = 0x20 };
        if (std.ascii.eqlIgnoreCase(tok, "enter") or std.ascii.eqlIgnoreCase(tok, "return")) return .{ .key = 0x0D };
        if (std.ascii.eqlIgnoreCase(tok, "backspace")) return .{ .key = 0x08 };
        if (std.ascii.eqlIgnoreCase(tok, "delete") or std.ascii.eqlIgnoreCase(tok, "del")) return .{ .key = 0x2E };
        if (std.ascii.eqlIgnoreCase(tok, "home")) return .{ .key = 0x24 };
        if (std.ascii.eqlIgnoreCase(tok, "end")) return .{ .key = 0x23 };
        if (std.ascii.eqlIgnoreCase(tok, "pageup") or std.ascii.eqlIgnoreCase(tok, "pgup")) return .{ .key = 0x21 };
        if (std.ascii.eqlIgnoreCase(tok, "pagedown") or std.ascii.eqlIgnoreCase(tok, "pgdn")) return .{ .key = 0x22 };

        // F1 - F12
        if (tok.len >= 2 and (tok[0] == 'f' or tok[0] == 'F')) {
            if (std.fmt.parseInt(u8, tok[1..], 10)) |f_num| {
                if (f_num >= 1 and f_num <= 12) return .{ .key = 0x70 + @as(u32, f_num) - 1 };
            } else |_| {}
        }

        // Single alphanumeric character
        if (tok.len == 1 and std.ascii.isAlphanumeric(tok[0])) {
            return .{ .key = std.ascii.toUpper(tok[0]) };
        }
        return null;
    }
};

const DEFAULT_CONFIG_TOML =
    \\# ==========================================
    \\# zwin configuration file - modern window gesture and tiling manager
    \\# ==========================================
    \\language = "auto"
    \\move_step = 20
    \\snap_threshold = 18
    \\opacity_step = 15
    \\enable_border = true
    \\enable_wheel_opacity = true
    \\enable_autostart = false
    \\enable_elevated = false
    \\enable_window_snap = true
    \\active_border_hex = "#FF8800"
    \\min_window_width = 120
    \\min_window_height = 100
    \\log_max_days = 7
    \\
    \\# Directional focus (Alt + H/J/K/L)
    \\[[bind]]
    \\keys = ["alt", "h"]
    \\action = "focus_left"
    \\
    \\[[bind]]
    \\keys = ["alt", "j"]
    \\action = "focus_down"
    \\
    \\[[bind]]
    \\keys = ["alt", "k"]
    \\action = "focus_up"
    \\
    \\[[bind]]
    \\keys = ["alt", "l"]
    \\action = "focus_right"
    \\
    \\# Window step displacement (Alt + Ctrl + H/J/K/L)
    \\[[bind]]
    \\keys = ["alt", "ctrl", "h"]
    \\action = "move_left"
    \\
    \\[[bind]]
    \\keys = ["alt", "ctrl", "j"]
    \\action = "move_down"
    \\
    \\[[bind]]
    \\keys = ["alt", "ctrl", "k"]
    \\action = "move_up"
    \\
    \\[[bind]]
    \\keys = ["alt", "ctrl", "l"]
    \\action = "move_right"
    \\
    \\# Common actions
    \\[[bind]]
    \\keys = ["alt", "c"]
    \\action = "center"
    \\
    \\[[bind]]
    \\keys = ["alt", "t"]
    \\action = "toggle_topmost"
    \\
    \\[[bind]]
    \\keys = ["alt", "q"]
    \\action = "close"
    \\
    \\[[bind]]
    \\keys = ["alt", "m"]
    \\action = "toggle_maximize"
    \\
    \\[[bind]]
    \\keys = ["alt", "n"]
    \\action = "restore_last_minimized"
    \\
    \\# Mouse streaming gestures
    \\[[bind]]
    \\keys = ["alt", "mouse_left"]
    \\action = "drag_move"
    \\
    \\[[bind]]
    \\keys = ["alt", "mouse_right"]
    \\action = "drag_resize"
    \\
    \\[[bind]]
    \\keys = ["alt", "mouse_middle"]
    \\action = "minimize"
    \\
    \\[[bind]]
    \\keys = ["alt", "mouse_wheel"]
    \\action = "adjust_opacity"
;

pub const ConfigStore = struct {
    pub fn load(allocator: std.mem.Allocator) Config {
        const cfg_dir = Paths.getConfigDir(allocator) catch return .{};
        defer allocator.free(cfg_dir);
        Paths.makeDirs(cfg_dir);

        const cfg_path = std.fmt.allocPrint(allocator, "{s}\\config.toml", .{cfg_dir}) catch return .{};
        defer allocator.free(cfg_path);

        const bytes = Paths.readSmallFile(allocator, cfg_path, 128 * 1024) catch |err| {
            if (err == error.FileNotFound) {
                Paths.writeFile(cfg_path, DEFAULT_CONFIG_TOML) catch {};
                return parseToml(allocator, DEFAULT_CONFIG_TOML);
            }
            return .{};
        };
        defer allocator.free(bytes);

        return parseToml(allocator, bytes);
    }

    /// When a tray toggle changes a boolean option, mutate the TOML CST in place preserving all user comments and layout
    pub fn updateBoolOption(allocator: std.mem.Allocator, key: []const u8, value: bool) void {
        const cfg_dir = Paths.getConfigDir(allocator) catch return;
        defer allocator.free(cfg_dir);
        const cfg_path = std.fmt.allocPrint(allocator, "{s}\\config.toml", .{cfg_dir}) catch return;
        defer allocator.free(cfg_path);

        const bytes = Paths.readSmallFile(allocator, cfg_path, 128 * 1024) catch return;
        defer allocator.free(bytes);

        var doc = cst.CstDocument.parse(allocator, bytes) catch return;
        defer doc.deinit();

        doc.setKeyValue(key, .{ .boolean = value }) catch return;

        var out = std.ArrayListUnmanaged(u8).empty;
        defer out.deinit(allocator);
        const w = ArrayListWriter{ .list = &out, .alloc = allocator };
        doc.emit(w) catch return;

        Paths.writeFile(cfg_path, out.items) catch |err| {
            logger.err("Config", "failed to atomically save option {s}: {s}", .{ key, @errorName(err) });
        };
    }

    fn parseToml(allocator: std.mem.Allocator, text: []const u8) Config {
        var cfg = Config{};
        var doc = cst.CstDocument.parse(allocator, text) catch return cfg;
        defer doc.deinit();

        var bindings_list = std.ArrayListUnmanaged(Binding).empty;
        var in_bind_table = false;
        var cur_keys = std.ArrayListUnmanaged([]const u8).empty;
        defer cur_keys.deinit(allocator);
        var cur_action: ?Action = null;

        const flush_binding = struct {
            fn run(b_list: *std.ArrayListUnmanaged(Binding), k_list: *std.ArrayListUnmanaged([]const u8), act_opt: ?Action, alloc: std.mem.Allocator) void {
                if (act_opt) |act| {
                    var mods = ModifierMask{};
                    var final_trigger: ?Trigger = null;
                    for (k_list.items) |tok| {
                        if (KeyParser.parseToken(tok, &mods)) |trig| {
                            final_trigger = trig;
                        }
                    }
                    if (final_trigger) |trig| {
                        b_list.append(alloc, .{
                            .mods = mods,
                            .trigger = trig,
                            .action = act,
                        }) catch {};
                    }
                }
                k_list.clearRetainingCapacity();
            }
        }.run;

        for (doc.nodes.items) |node| {
            switch (node) {
                .table_array_header => |th| {
                    if (in_bind_table) {
                        flush_binding(&bindings_list, &cur_keys, cur_action, allocator);
                        cur_action = null;
                    }
                    in_bind_table = std.ascii.eqlIgnoreCase(th.name, "bind");
                },
                .key_value => |kv| {
                    if (in_bind_table) {
                        if (std.ascii.eqlIgnoreCase(kv.key, "keys")) {
                            switch (kv.value) {
                                .array => |arr| {
                                    for (arr.items) |item| {
                                        if (item == .string) cur_keys.append(allocator, item.string) catch {};
                                    }
                                },
                                else => {},
                            }
                        } else if (std.ascii.eqlIgnoreCase(kv.key, "action")) {
                            if (kv.value == .string) {
                                cur_action = Action.fromString(kv.value.string);
                            }
                        }
                    } else {
                        // Root-level config options
                        if (std.ascii.eqlIgnoreCase(kv.key, "language") and kv.value == .string) {
                            cfg.language = Language.fromString(kv.value.string);
                        }
                        if (std.ascii.eqlIgnoreCase(kv.key, "enable_border") and kv.value == .boolean) cfg.enable_border = kv.value.boolean;
                        if (std.ascii.eqlIgnoreCase(kv.key, "enable_wheel_opacity") and kv.value == .boolean) cfg.enable_wheel_opacity = kv.value.boolean;
                        if (std.ascii.eqlIgnoreCase(kv.key, "enable_autostart") and kv.value == .boolean) cfg.enable_autostart = kv.value.boolean;
                        if (std.ascii.eqlIgnoreCase(kv.key, "enable_elevated") and kv.value == .boolean) cfg.enable_elevated = kv.value.boolean;
                        if (std.ascii.eqlIgnoreCase(kv.key, "enable_window_snap") and kv.value == .boolean) cfg.enable_window_snap = kv.value.boolean;
                        if (std.ascii.eqlIgnoreCase(kv.key, "move_step") and kv.value == .integer) cfg.move_step = @intCast(kv.value.integer);
                        if (std.ascii.eqlIgnoreCase(kv.key, "snap_threshold") and kv.value == .integer) cfg.snap_threshold = @intCast(kv.value.integer);
                        if (std.ascii.eqlIgnoreCase(kv.key, "opacity_step") and kv.value == .integer) cfg.opacity_step = @intCast(kv.value.integer);
                        if (std.ascii.eqlIgnoreCase(kv.key, "active_border_hex") and kv.value == .string) {
                            if (Color.fromHex(kv.value.string)) |c| cfg.active_border_color = c;
                        }
                        if (std.ascii.eqlIgnoreCase(kv.key, "min_window_width") and kv.value == .integer) cfg.min_window_width = @intCast(kv.value.integer);
                        if (std.ascii.eqlIgnoreCase(kv.key, "min_window_height") and kv.value == .integer) cfg.min_window_height = @intCast(kv.value.integer);
                        if (std.ascii.eqlIgnoreCase(kv.key, "log_max_days") and kv.value == .integer) cfg.log_max_days = @intCast(kv.value.integer);
                        if (std.ascii.eqlIgnoreCase(kv.key, "ignore_processes") and kv.value == .array) {
                            var list = std.ArrayListUnmanaged([]const u8).empty;
                            for (kv.value.array.items) |item| {
                                if (item == .string) {
                                    if (allocator.dupe(u8, item.string)) |dup| list.append(allocator, dup) catch allocator.free(dup) else |_| {}
                                }
                            }
                            cfg.ignore_processes = list.toOwnedSlice(allocator) catch &.{};
                        }
                        if (std.ascii.eqlIgnoreCase(kv.key, "ignore_classes") and kv.value == .array) {
                            var list = std.ArrayListUnmanaged([]const u8).empty;
                            for (kv.value.array.items) |item| {
                                if (item == .string) {
                                    if (allocator.dupe(u8, item.string)) |dup| list.append(allocator, dup) catch allocator.free(dup) else |_| {}
                                }
                            }
                            cfg.ignore_classes = list.toOwnedSlice(allocator) catch &.{};
                        }
                    }
                },
                else => {},
            }
        }

        if (in_bind_table) {
            flush_binding(&bindings_list, &cur_keys, cur_action, allocator);
        }

        cfg.bindings = bindings_list.toOwnedSlice(allocator) catch &.{};
        cfg.updateActiveModifiersUnion();
        return cfg;
    }
};

test "KeyParser parses modifier + key tokens" {
    var mods = ModifierMask{};

    try std.testing.expect(KeyParser.parseToken("alt", &mods) == null);
    try std.testing.expect(mods.alt);

    mods = ModifierMask{};
    try std.testing.expect(KeyParser.parseToken("ctrl", &mods) == null);
    try std.testing.expect(mods.ctrl);

    mods = ModifierMask{};
    const trig = KeyParser.parseToken("h", &mods) orelse unreachable;
    try std.testing.expectEqual(@as(u32, 'H'), switch (trig) {
        .key => |v| v,
        .mouse => unreachable,
    });

    mods = ModifierMask{};
    const mtrig = KeyParser.parseToken("mouse_left", &mods) orelse unreachable;
    try std.testing.expectEqual(binding.MouseTrigger.left, switch (mtrig) {
        .mouse => |m| m,
        .key => unreachable,
    });
}

test "ConfigStore TOML roundtrip preserves bindings" {
    const allocator = std.testing.allocator;
    var cfg = ConfigStore.parseToml(allocator, DEFAULT_CONFIG_TOML);
    defer cfg.deinit(allocator);

    try std.testing.expectEqual(@as(i32, 20), cfg.move_step);
    try std.testing.expectEqual(true, cfg.enable_border);
    try std.testing.expect(cfg.bindings.len > 0);
}
