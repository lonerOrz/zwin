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

pub const KeyParser = struct {
    /// Parse a single combo string like "alt+ctrl+h" into ModifierMask + Trigger
    pub fn parseKeyCombo(combo_str: []const u8) ?struct { mods: ModifierMask, trigger: Trigger } {
        var mods = ModifierMask{};
        var final_trigger: ?Trigger = null;

        var it = std.mem.splitAny(u8, combo_str, "+");
        while (it.next()) |part| {
            const tok = std.mem.trim(u8, part, " \t\r");
            if (tok.len == 0) continue;

            if (std.ascii.eqlIgnoreCase(tok, "alt")) {
                mods.alt = true;
            } else if (std.ascii.eqlIgnoreCase(tok, "ctrl") or std.ascii.eqlIgnoreCase(tok, "control")) {
                mods.ctrl = true;
            } else if (std.ascii.eqlIgnoreCase(tok, "shift")) {
                mods.shift = true;
            } else if (std.ascii.eqlIgnoreCase(tok, "win") or std.ascii.eqlIgnoreCase(tok, "super")) {
                mods.win = true;
            } else if (std.ascii.eqlIgnoreCase(tok, "mouse_left") or std.ascii.eqlIgnoreCase(tok, "left_click")) {
                final_trigger = .{ .mouse = .left };
            } else if (std.ascii.eqlIgnoreCase(tok, "mouse_right") or std.ascii.eqlIgnoreCase(tok, "right_click")) {
                final_trigger = .{ .mouse = .right };
            } else if (std.ascii.eqlIgnoreCase(tok, "mouse_middle") or std.ascii.eqlIgnoreCase(tok, "middle_click")) {
                final_trigger = .{ .mouse = .middle };
            } else if (std.ascii.eqlIgnoreCase(tok, "mouse_wheel") or std.ascii.eqlIgnoreCase(tok, "wheel")) {
                final_trigger = .{ .mouse = .wheel };
            } else if (std.ascii.eqlIgnoreCase(tok, "left") or std.ascii.eqlIgnoreCase(tok, "arrowleft")) {
                final_trigger = .{ .key = 0x25 };
            } else if (std.ascii.eqlIgnoreCase(tok, "up") or std.ascii.eqlIgnoreCase(tok, "arrowup")) {
                final_trigger = .{ .key = 0x26 };
            } else if (std.ascii.eqlIgnoreCase(tok, "right") or std.ascii.eqlIgnoreCase(tok, "arrowright")) {
                final_trigger = .{ .key = 0x27 };
            } else if (std.ascii.eqlIgnoreCase(tok, "down") or std.ascii.eqlIgnoreCase(tok, "arrowdown")) {
                final_trigger = .{ .key = 0x28 };
            } else if (tok.len == 1 and std.ascii.isAlphanumeric(tok[0])) {
                final_trigger = .{ .key = std.ascii.toUpper(tok[0]) };
            }
        }

        if (final_trigger) |t| {
            return .{ .mods = mods, .trigger = t };
        }
        return null;
    }
};

const DEFAULT_CONFIG_TOML =
    \\# ==========================================
    \\# zwin 配置文件
    \\# ==========================================
    \\language = "auto"
    \\autostart = false
    \\run_as_admin = false
    \\log_retention_days = 7
    \\
    \\move_step = 20
    \\opacity_step = 15
    \\window_snap = true
    \\snap_threshold = 18
    \\min_width = 120
    \\min_height = 100
    \\
    \\border = true
    \\border_color = "#FF8800"
    \\
    \\ignore_processes = ["Photoshop.exe", "*blender*.exe", "mstsc.exe"]
    \\ignore_classes = ["UnityWndClass", "UnrealWindow"]
    \\
    \\[bind]
    \\"alt+h" = "focus_left"
    \\"alt+j" = "focus_down"
    \\"alt+k" = "focus_up"
    \\"alt+l" = "focus_right"
    \\"alt+ctrl+h" = "move_left"
    \\"alt+ctrl+j" = "move_down"
    \\"alt+ctrl+k" = "move_up"
    \\"alt+ctrl+l" = "move_right"
    \\"alt+c" = "center"
    \\"alt+t" = "toggle_topmost"
    \\"alt+q" = "close"
    \\"alt+m" = "toggle_maximize"
    \\"alt+n" = "restore_last_minimized"
    \\"alt+mouse_left" = "drag_move"
    \\"alt+mouse_right" = "drag_resize"
    \\"alt+mouse_middle" = "minimize"
    \\"alt+mouse_wheel" = "adjust_opacity"
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

    /// Atomically mutate a root-level boolean in the TOML CST, preserving all comments and layout
    pub fn updateBoolOption(allocator: std.mem.Allocator, key: []const u8, value: bool) void {
        const cfg_dir = Paths.getConfigDir(allocator) catch return;
        defer allocator.free(cfg_dir);
        const cfg_path = std.fmt.allocPrint(allocator, "{s}\\config.toml", .{cfg_dir}) catch return;
        defer allocator.free(cfg_path);

        const bytes = Paths.readSmallFile(allocator, cfg_path, 128 * 1024) catch return;
        defer allocator.free(bytes);

        var doc = cst.CstDocument.parse(allocator, bytes) catch return;
        defer doc.deinit();

        doc.setRootKeyValue(key, .{ .boolean = value }) catch return;

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

        for (doc.nodes.items) |node| {
            switch (node) {
                .table_header => |th| {
                    in_bind_table = std.ascii.eqlIgnoreCase(th.name, "bind");
                },
                .table_array_header => {
                    // Legacy [[bind]] support — silently skip, user should migrate
                    in_bind_table = false;
                },
                .key_value => |kv| {
                    if (in_bind_table) {
                        // New format: "alt+h" = "focus_left"
                        if (kv.value == .string) {
                            if (Action.fromString(kv.value.string)) |act| {
                                if (KeyParser.parseKeyCombo(kv.key)) |parsed| {
                                    bindings_list.append(allocator, .{
                                        .mods = parsed.mods,
                                        .trigger = parsed.trigger,
                                        .action = act,
                                    }) catch {};
                                }
                            }
                        }
                    } else {
                        if (std.ascii.eqlIgnoreCase(kv.key, "language") and kv.value == .string) cfg.language = Language.fromString(kv.value.string);
                        if (std.ascii.eqlIgnoreCase(kv.key, "autostart") and kv.value == .boolean) cfg.autostart = kv.value.boolean;
                        if (std.ascii.eqlIgnoreCase(kv.key, "run_as_admin") and kv.value == .boolean) cfg.run_as_admin = kv.value.boolean;
                        if (std.ascii.eqlIgnoreCase(kv.key, "border") and kv.value == .boolean) cfg.border = kv.value.boolean;
                        if (std.ascii.eqlIgnoreCase(kv.key, "window_snap") and kv.value == .boolean) cfg.window_snap = kv.value.boolean;
                        if (std.ascii.eqlIgnoreCase(kv.key, "move_step") and kv.value == .integer) cfg.move_step = @intCast(kv.value.integer);
                        if (std.ascii.eqlIgnoreCase(kv.key, "snap_threshold") and kv.value == .integer) cfg.snap_threshold = @intCast(kv.value.integer);
                        if (std.ascii.eqlIgnoreCase(kv.key, "opacity_step") and kv.value == .integer) cfg.opacity_step = @intCast(kv.value.integer);
                        if (std.ascii.eqlIgnoreCase(kv.key, "border_color") and kv.value == .string) {
                            if (Color.fromHex(kv.value.string)) |c| cfg.border_color = c;
                        }
                        if (std.ascii.eqlIgnoreCase(kv.key, "min_width") and kv.value == .integer) cfg.min_width = @intCast(kv.value.integer);
                        if (std.ascii.eqlIgnoreCase(kv.key, "min_height") and kv.value == .integer) cfg.min_height = @intCast(kv.value.integer);
                        if (std.ascii.eqlIgnoreCase(kv.key, "log_retention_days") and kv.value == .integer) cfg.log_retention_days = @intCast(kv.value.integer);
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

        cfg.bindings = bindings_list.toOwnedSlice(allocator) catch &.{};
        cfg.updateActiveModifiersUnion();
        return cfg;
    }
};

test "KeyParser parses modifier + key tokens" {
    const result = KeyParser.parseKeyCombo("alt+h") orelse unreachable;
    try std.testing.expect(result.mods.alt);
    try std.testing.expectEqual(@as(u32, 'H'), switch (result.trigger) {
        .key => |v| v,
        .mouse => unreachable,
    });

    const result2 = KeyParser.parseKeyCombo("alt+ctrl+h") orelse unreachable;
    try std.testing.expect(result2.mods.alt);
    try std.testing.expect(result2.mods.ctrl);
    try std.testing.expectEqual(@as(u32, 'H'), switch (result2.trigger) {
        .key => |v| v,
        .mouse => unreachable,
    });

    const result3 = KeyParser.parseKeyCombo("alt+mouse_left") orelse unreachable;
    try std.testing.expect(result3.mods.alt);
    try std.testing.expectEqual(binding.MouseTrigger.left, switch (result3.trigger) {
        .mouse => |m| m,
        .key => unreachable,
    });
}

test "ConfigStore TOML roundtrip preserves bindings" {
    const allocator = std.testing.allocator;
    var cfg = ConfigStore.parseToml(allocator, DEFAULT_CONFIG_TOML);
    defer cfg.deinit(allocator);

    try std.testing.expectEqual(@as(i32, 20), cfg.move_step);
    try std.testing.expectEqual(true, cfg.border);
    try std.testing.expectEqual(false, cfg.autostart);
    try std.testing.expectEqual(false, cfg.run_as_admin);
    try std.testing.expect(cfg.bindings.len > 0);
}
