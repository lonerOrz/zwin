const std = @import("std");
const Paths = @import("../platform/paths.zig").Paths;
const Config = @import("../domain/config.zig").Config;
const Color = @import("../domain/color.zig").Color;
const Language = @import("i18n.zig").Language;
const logger = @import("logger.zig");

// Win32 VK code aliases used for parsing config values
const VK_LEFT: u32 = 0x25;
const VK_UP: u32 = 0x26;
const VK_RIGHT: u32 = 0x27;
const VK_DOWN: u32 = 0x28;

pub const KeyMapper = struct {
    const TableEntry = struct { name: []const u8, vk: u32 };

    const named_keys = [_]TableEntry{
        .{ .name = "Left", .vk = VK_LEFT },
        .{ .name = "ArrowLeft", .vk = VK_LEFT },
        .{ .name = "Up", .vk = VK_UP },
        .{ .name = "ArrowUp", .vk = VK_UP },
        .{ .name = "Right", .vk = VK_RIGHT },
        .{ .name = "ArrowRight", .vk = VK_RIGHT },
        .{ .name = "Down", .vk = VK_DOWN },
        .{ .name = "ArrowDown", .vk = VK_DOWN },
    };

    pub fn parse(raw: []const u8) ?u32 {
        if (raw.len == 0) return null;
        for (named_keys) |entry| {
            if (std.ascii.eqlIgnoreCase(raw, entry.name)) return entry.vk;
        }
        if (raw.len == 1 and std.ascii.isAlphanumeric(raw[0])) {
            return std.ascii.toUpper(raw[0]);
        }
        return null;
    }

    pub fn format(vk: u32, buf: *[16]u8) []const u8 {
        return switch (vk) {
            VK_LEFT => "Left",
            VK_UP => "Up",
            VK_RIGHT => "Right",
            VK_DOWN => "Down",
            'A'...'Z', '0'...'9' => std.fmt.bufPrint(buf, "{c}", .{@as(u8, @truncate(vk))}) catch "Unknown",
            else => "Unknown",
        };
    }
};

pub const ConfigStore = struct {
    pub fn load(allocator: std.mem.Allocator) Config {
        const cfg_dir = Paths.getConfigDir(allocator) catch return .{};
        defer allocator.free(cfg_dir);
        Paths.makeDirs(cfg_dir);

        const cfg_path = std.fmt.allocPrint(allocator, "{s}\\config.json", .{cfg_dir}) catch return .{};
        defer allocator.free(cfg_path);

        const bytes = Paths.readSmallFile(allocator, cfg_path, 64 * 1024) catch |err| {
            if (err == error.FileNotFound) {
                const default_cfg = Config{};
                save(allocator, &default_cfg);
            }
            return .{};
        };
        defer allocator.free(bytes);

        const cfg = deserialize(allocator, bytes);

        // Auto-migrate: if the on-disk file is missing new keys, rewrite it in-place
        if (hasMissingKeys(bytes)) {
            save(allocator, &cfg);
            logger.info("Config", "migrated old config to include new settings", .{});
        }

        return cfg;
    }

    pub fn save(allocator: std.mem.Allocator, config: *const Config) void {
        const cfg_dir = Paths.getConfigDir(allocator) catch return;
        defer allocator.free(cfg_dir);

        const cfg_path = std.fmt.allocPrint(allocator, "{s}\\config.json", .{cfg_dir}) catch return;
        defer allocator.free(cfg_path);

        const json_content = serialize(allocator, config) catch return;
        defer allocator.free(json_content);

        Paths.writeFile(cfg_path, json_content) catch |err| {
            logger.err("Config", "save failed: {s}", .{@errorName(err)});
        };
    }

    fn hasMissingKeys(json_bytes: []const u8) bool {
        const required = [_][]const u8{
            "\"move_step\"",
            "\"key_move_left\"",
            "\"key_move_down\"",
            "\"key_move_up\"",
            "\"key_move_right\"",
        };
        for (required) |k| {
            if (std.mem.indexOf(u8, json_bytes, k) == null) return true;
        }
        return false;
    }

    fn serialize(allocator: std.mem.Allocator, cfg: *const Config) ![]u8 {
        var list = std.array_list.Managed(u8).init(allocator);
        defer list.deinit();

        var b1: [16]u8 = undefined;
        var b2: [16]u8 = undefined;
        var b3: [16]u8 = undefined;
        var b4: [16]u8 = undefined;
        var b5: [16]u8 = undefined;
        var b6: [16]u8 = undefined;
        var b7: [16]u8 = undefined;
        var b8: [16]u8 = undefined;
        var b9: [16]u8 = undefined;
        var bm1: [16]u8 = undefined;
        var bm2: [16]u8 = undefined;
        var bm3: [16]u8 = undefined;
        var bm4: [16]u8 = undefined;
        var hex_buf: [7]u8 = undefined;

        try list.print(
            \\{{
            \\  "language": "{s}",
            \\  "move_step": {d},
            \\  "key_center": "{s}",
            \\  "key_topmost": "{s}",
            \\  "key_close": "{s}",
            \\  "key_maximize": "{s}",
            \\  "key_restore_min": "{s}",
            \\  "key_focus_left": "{s}",
            \\  "key_focus_down": "{s}",
            \\  "key_focus_up": "{s}",
            \\  "key_focus_right": "{s}",
            \\  "key_move_left": "{s}",
            \\  "key_move_down": "{s}",
            \\  "key_move_up": "{s}",
            \\  "key_move_right": "{s}",
            \\  "enable_border": {},
            \\  "enable_wheel_opacity": {},
            \\  "enable_autostart": {},
            \\  "enable_elevated": {},
            \\  "enable_window_snap": {},
            \\  "snap_threshold": {d},
            \\  "opacity_step": {d},
            \\  "active_border_hex": "{s}",
            \\  "min_window_width": {d},
            \\  "min_window_height": {d},
            \\  "log_max_days": {d},
            \\  "ignore_processes": [
        , .{
            cfg.language.toString(),
            cfg.move_step,
            KeyMapper.format(cfg.key_center, &b1),
            KeyMapper.format(cfg.key_topmost, &b2),
            KeyMapper.format(cfg.key_close, &b3),
            KeyMapper.format(cfg.key_maximize, &b4),
            KeyMapper.format(cfg.key_restore_min, &b5),
            KeyMapper.format(cfg.key_focus_left, &b6),
            KeyMapper.format(cfg.key_focus_down, &b7),
            KeyMapper.format(cfg.key_focus_up, &b8),
            KeyMapper.format(cfg.key_focus_right, &b9),
            KeyMapper.format(cfg.key_move_left, &bm1),
            KeyMapper.format(cfg.key_move_down, &bm2),
            KeyMapper.format(cfg.key_move_up, &bm3),
            KeyMapper.format(cfg.key_move_right, &bm4),
            cfg.enable_border,
            cfg.enable_wheel_opacity,
            cfg.enable_autostart,
            cfg.enable_elevated,
            cfg.enable_window_snap,
            cfg.snap_threshold,
            cfg.opacity_step,
            cfg.active_border_color.toHex(&hex_buf),
            cfg.min_window_width,
            cfg.min_window_height,
            cfg.log_max_days,
        });

        for (cfg.ignore_processes, 0..) |p, i| {
            try list.print("\"{s}\"{s}", .{ p, if (i + 1 < cfg.ignore_processes.len) ", " else "" });
        }
        try list.appendSlice("],\n  \"ignore_classes\": [");
        for (cfg.ignore_classes, 0..) |c, i| {
            try list.print("\"{s}\"{s}", .{ c, if (i + 1 < cfg.ignore_classes.len) ", " else "" });
        }
        try list.appendSlice("]\n}\n");

        return list.toOwnedSlice();
    }

    fn deserialize(allocator: std.mem.Allocator, json_bytes: []const u8) Config {
        var res = Config{};

        const Parsed = struct {
            language: ?[]const u8 = null,
            move_step: ?i32 = null,
            key_center: ?[]const u8 = null,
            key_topmost: ?[]const u8 = null,
            key_close: ?[]const u8 = null,
            key_maximize: ?[]const u8 = null,
            key_restore_min: ?[]const u8 = null,
            key_focus_left: ?[]const u8 = null,
            key_focus_down: ?[]const u8 = null,
            key_focus_up: ?[]const u8 = null,
            key_focus_right: ?[]const u8 = null,
            key_move_left: ?[]const u8 = null,
            key_move_down: ?[]const u8 = null,
            key_move_up: ?[]const u8 = null,
            key_move_right: ?[]const u8 = null,
            enable_border: ?bool = null,
            enable_wheel_opacity: ?bool = null,
            enable_autostart: ?bool = null,
            enable_elevated: ?bool = null,
            enable_window_snap: ?bool = null,
            snap_threshold: ?i32 = null,
            opacity_step: ?u8 = null,
            active_border_hex: ?[]const u8 = null,
            min_window_width: ?i32 = null,
            min_window_height: ?i32 = null,
            log_max_days: ?u32 = null,
            ignore_processes: ?[][]const u8 = null,
            ignore_classes: ?[][]const u8 = null,
        };

        const parsed = std.json.parseFromSlice(Parsed, allocator, json_bytes, .{ .ignore_unknown_fields = true }) catch return res;
        defer parsed.deinit();

        const v = parsed.value;
        if (v.language) |l| res.language = Language.fromString(l);
        if (v.move_step) |ms| res.move_step = std.math.clamp(ms, 1, 300);
        if (v.enable_border) |eb| res.enable_border = eb;
        if (v.enable_wheel_opacity) |wo| res.enable_wheel_opacity = wo;
        if (v.enable_autostart) |ea| res.enable_autostart = ea;
        if (v.enable_elevated) |ee| res.enable_elevated = ee;
        if (v.enable_window_snap) |es| res.enable_window_snap = es;
        if (v.snap_threshold) |st| res.snap_threshold = std.math.clamp(st, 0, 50);
        if (v.opacity_step) |os| res.opacity_step = std.math.clamp(os, 1, 100);
        if (v.min_window_width) |mw| res.min_window_width = @max(mw, 50);
        if (v.min_window_height) |mh| res.min_window_height = @max(mh, 50);
        if (v.log_max_days) |ld| res.log_max_days = @max(ld, 1);

        if (v.key_center) |k| if (KeyMapper.parse(k)) |vk| {
            res.key_center = vk;
        };
        if (v.key_topmost) |k| if (KeyMapper.parse(k)) |vk| {
            res.key_topmost = vk;
        };
        if (v.key_close) |k| if (KeyMapper.parse(k)) |vk| {
            res.key_close = vk;
        };
        if (v.key_maximize) |k| if (KeyMapper.parse(k)) |vk| {
            res.key_maximize = vk;
        };
        if (v.key_restore_min) |k| if (KeyMapper.parse(k)) |vk| {
            res.key_restore_min = vk;
        };

        if (v.key_focus_left) |k| if (KeyMapper.parse(k)) |vk| {
            res.key_focus_left = vk;
        };
        if (v.key_focus_down) |k| if (KeyMapper.parse(k)) |vk| {
            res.key_focus_down = vk;
        };
        if (v.key_focus_up) |k| if (KeyMapper.parse(k)) |vk| {
            res.key_focus_up = vk;
        };
        if (v.key_focus_right) |k| if (KeyMapper.parse(k)) |vk| {
            res.key_focus_right = vk;
        };

        if (v.key_move_left) |k| if (KeyMapper.parse(k)) |vk| {
            res.key_move_left = vk;
        };
        if (v.key_move_down) |k| if (KeyMapper.parse(k)) |vk| {
            res.key_move_down = vk;
        };
        if (v.key_move_up) |k| if (KeyMapper.parse(k)) |vk| {
            res.key_move_up = vk;
        };
        if (v.key_move_right) |k| if (KeyMapper.parse(k)) |vk| {
            res.key_move_right = vk;
        };

        if (v.active_border_hex) |hex| if (Color.fromHex(hex)) |c| {
            res.active_border_color = c;
        };

        if (v.ignore_processes) |procs| {
            var list = std.array_list.Managed([]const u8).init(allocator);
            for (procs) |item| {
                if (allocator.dupe(u8, item)) |dup| list.append(dup) catch allocator.free(dup) else |_| {}
            }
            res.ignore_processes = list.toOwnedSlice() catch &.{};
        }

        if (v.ignore_classes) |classes| {
            var list = std.array_list.Managed([]const u8).init(allocator);
            for (classes) |item| {
                if (allocator.dupe(u8, item)) |dup| list.append(dup) catch allocator.free(dup) else |_| {}
            }
            res.ignore_classes = list.toOwnedSlice() catch &.{};
        }

        return res;
    }
};

test "KeyMapper parse & format" {
    var buf: [16]u8 = undefined;

    try std.testing.expectEqual(@as(?u32, VK_LEFT), KeyMapper.parse("Left"));
    try std.testing.expectEqual(@as(?u32, VK_LEFT), KeyMapper.parse("arrowleft"));
    try std.testing.expectEqual(@as(?u32, 'H'), KeyMapper.parse("h"));
    try std.testing.expectEqual(@as(?u32, 'M'), KeyMapper.parse("m"));

    try std.testing.expectEqualStrings("Left", KeyMapper.format(VK_LEFT, &buf));
    try std.testing.expectEqualStrings("Up", KeyMapper.format(VK_UP, &buf));
    try std.testing.expectEqualStrings("H", KeyMapper.format('H', &buf));
}

test "ConfigStore serialize & deserialize roundtrip" {
    const allocator = std.testing.allocator;
    var cfg = Config{
        .move_step = 25,
        .key_move_left = VK_LEFT,
        .key_move_right = VK_RIGHT,
    };
    const json = try ConfigStore.serialize(allocator, &cfg);
    defer allocator.free(json);

    var loaded = ConfigStore.deserialize(allocator, json);
    defer loaded.deinit(allocator);

    try std.testing.expectEqual(@as(i32, 25), loaded.move_step);
    try std.testing.expectEqual(VK_LEFT, loaded.key_move_left);
    try std.testing.expectEqual(VK_RIGHT, loaded.key_move_right);
}
