const std = @import("std");
const Language = @import("../infra/i18n.zig").Language;
pub const Color = @import("color.zig").Color;

pub const Config = struct {
    language: Language = .auto,

    // Keybindings (Alt + Key)
    key_center: u32 = 'C',
    key_topmost: u32 = 'T',
    key_close: u32 = 'Q',
    key_maximize: u32 = 'M',
    key_restore_min: u32 = 'N',
    key_focus_left: u32 = 'H',
    key_focus_down: u32 = 'J',
    key_focus_up: u32 = 'K',
    key_focus_right: u32 = 'L',

    // Features
    enable_border: bool = true,
    enable_wheel_opacity: bool = true,
    enable_autostart: bool = false,
    enable_elevated: bool = false,
    enable_window_snap: bool = true,
    snap_threshold: i32 = 18,
    opacity_step: u8 = 15,

    active_border_color: Color = Color.rgb(255, 136, 0),

    min_window_width: i32 = 120,
    min_window_height: i32 = 100,

    log_max_days: u32 = 7,

    // Blacklist filter patterns (e.g. "photoshop.exe", "*blender*", "UnityWndClass")
    ignore_processes: []const []const u8 = &.{},
    ignore_classes: []const []const u8 = &.{},

    pub const default_json =
        \\{
        \\  "language": "auto",
        \\  "key_center": "C",
        \\  "key_topmost": "T",
        \\  "key_close": "Q",
        \\  "key_maximize": "M",
        \\  "key_restore_min": "N",
        \\  "key_focus_left": "H",
        \\  "key_focus_down": "J",
        \\  "key_focus_up": "K",
        \\  "key_focus_right": "L",
        \\  "enable_border": true,
        \\  "enable_wheel_opacity": true,
        \\  "enable_autostart": false,
        \\  "enable_elevated": false,
        \\  "enable_window_snap": true,
        \\  "snap_threshold": 18,
        \\  "opacity_step": 15,
        \\  "active_border_hex": "#FF8800",
        \\  "min_window_width": 120,
        \\  "min_window_height": 100,
        \\  "log_max_days": 7
        \\}
    ;

    /// Releases dynamic memory allocated for blacklist strings.
    pub fn deinit(self: *Config, allocator: std.mem.Allocator) void {
        for (self.ignore_processes) |item| allocator.free(item);
        if (self.ignore_processes.len > 0) allocator.free(self.ignore_processes);
        for (self.ignore_classes) |item| allocator.free(item);
        if (self.ignore_classes.len > 0) allocator.free(self.ignore_classes);
        self.ignore_processes = &.{};
        self.ignore_classes = &.{};
    }

    /// Serializes configuration to a formatted JSON string.
    pub fn serializeToJson(self: *const Config, allocator: std.mem.Allocator) ![]u8 {
        var hex_buf: [7]u8 = undefined;
        const hex = self.active_border_color.toHex(&hex_buf);

        var list = std.array_list.Managed(u8).init(allocator);
        defer list.deinit();

        try list.print(
            \\{{
            \\  "language": "{s}",
            \\  "key_center": "{c}",
            \\  "key_topmost": "{c}",
            \\  "key_close": "{c}",
            \\  "key_maximize": "{c}",
            \\  "key_restore_min": "{c}",
            \\  "key_focus_left": "{c}",
            \\  "key_focus_down": "{c}",
            \\  "key_focus_up": "{c}",
            \\  "key_focus_right": "{c}",
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
        ,
            .{
                self.language.toString(),
                @as(u8, @truncate(self.key_center)),
                @as(u8, @truncate(self.key_topmost)),
                @as(u8, @truncate(self.key_close)),
                @as(u8, @truncate(self.key_maximize)),
                @as(u8, @truncate(self.key_restore_min)),
                @as(u8, @truncate(self.key_focus_left)),
                @as(u8, @truncate(self.key_focus_down)),
                @as(u8, @truncate(self.key_focus_up)),
                @as(u8, @truncate(self.key_focus_right)),
                self.enable_border,
                self.enable_wheel_opacity,
                self.enable_autostart,
                self.enable_elevated,
                self.enable_window_snap,
                self.snap_threshold,
                self.opacity_step,
                hex,
                self.min_window_width,
                self.min_window_height,
                self.log_max_days,
            },
        );

        for (self.ignore_processes, 0..) |p, i| {
            try list.print("\"{s}\"{s}", .{ p, if (i + 1 < self.ignore_processes.len) ", " else "" });
        }
        try list.appendSlice("],\n  \"ignore_classes\": [");
        for (self.ignore_classes, 0..) |c, i| {
            try list.print("\"{s}\"{s}", .{ c, if (i + 1 < self.ignore_classes.len) ", " else "" });
        }
        try list.appendSlice("]\n}\n");

        return list.toOwnedSlice();
    }

    // Parse configuration from JSON with fallback to defaults and value clamping
    pub fn loadFromJson(allocator: std.mem.Allocator, json_bytes: []const u8) Config {
        var result = Config{};

        const Parsed = struct {
            language: ?[]const u8 = null,
            key_center: ?[]const u8 = null,
            key_topmost: ?[]const u8 = null,
            key_close: ?[]const u8 = null,
            key_maximize: ?[]const u8 = null,
            key_restore_min: ?[]const u8 = null,
            key_focus_left: ?[]const u8 = null,
            key_focus_down: ?[]const u8 = null,
            key_focus_up: ?[]const u8 = null,
            key_focus_right: ?[]const u8 = null,
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

        const parsed = std.json.parseFromSlice(Parsed, allocator, json_bytes, .{ .ignore_unknown_fields = true }) catch return result;
        defer parsed.deinit();

        const v = parsed.value;
        if (v.language) |lang| result.language = Language.fromString(lang);
        if (v.enable_border) |eb| result.enable_border = eb;
        if (v.enable_wheel_opacity) |wo| result.enable_wheel_opacity = wo;
        if (v.enable_autostart) |ea| result.enable_autostart = ea;
        if (v.enable_elevated) |ee| result.enable_elevated = ee;
        if (v.enable_window_snap) |es| result.enable_window_snap = es;
        if (v.snap_threshold) |st| result.snap_threshold = std.math.clamp(st, 0, 50);
        if (v.opacity_step) |os| result.opacity_step = std.math.clamp(os, 1, 100);
        if (v.min_window_width) |mw| result.min_window_width = @max(mw, 50);
        if (v.min_window_height) |mh| result.min_window_height = @max(mh, 50);
        if (v.log_max_days) |ld| result.log_max_days = @max(ld, 1);

        if (v.ignore_processes) |procs| {
            var list = std.array_list.Managed([]const u8).init(allocator);
            for (procs) |item| {
                if (allocator.dupe(u8, item)) |dup| {
                    list.append(dup) catch allocator.free(dup);
                } else |_| {}
            }
            result.ignore_processes = list.toOwnedSlice() catch &.{};
        }

        if (v.ignore_classes) |classes| {
            var list = std.array_list.Managed([]const u8).init(allocator);
            for (classes) |item| {
                if (allocator.dupe(u8, item)) |dup| {
                    list.append(dup) catch allocator.free(dup);
                } else |_| {}
            }
            result.ignore_classes = list.toOwnedSlice() catch &.{};
        }

        parseKey(&result.key_center, v.key_center);
        parseKey(&result.key_topmost, v.key_topmost);
        parseKey(&result.key_close, v.key_close);
        parseKey(&result.key_maximize, v.key_maximize);
        parseKey(&result.key_restore_min, v.key_restore_min);
        parseKey(&result.key_focus_left, v.key_focus_left);
        parseKey(&result.key_focus_down, v.key_focus_down);
        parseKey(&result.key_focus_up, v.key_focus_up);
        parseKey(&result.key_focus_right, v.key_focus_right);

        if (v.active_border_hex) |hex| {
            if (Color.fromHex(hex)) |c| result.active_border_color = c;
        }

        return result;
    }

    fn parseKey(target: *u32, raw: ?[]const u8) void {
        if (raw) |k| if (k.len > 0 and std.ascii.isAlphanumeric(k[0])) {
            target.* = std.ascii.toUpper(k[0]);
        };
    }

    /// Returns true if the JSON source is missing any field newer than the prior release,
    /// indicating the disk file needs a write-back to keep the template complete.
    pub fn hasMissingFields(json_bytes: []const u8) bool {
        const needle = [_][]const u8{
            "\"key_maximize\"",       "\"key_restore_min\"",
            "\"key_focus_left\"",     "\"key_focus_down\"",
            "\"key_focus_up\"",       "\"key_focus_right\"",
            "\"enable_window_snap\"", "\"snap_threshold\"",
            "\"ignore_processes\"",   "\"ignore_classes\"",
        };
        var has_all_new = true;
        for (needle) |n| {
            if (std.mem.indexOf(u8, json_bytes, n) == null) {
                has_all_new = false;
                break;
            }
        }
        return !has_all_new;
    }
};

test "loadFromJson overrides defaults" {
    const c = Config.loadFromJson(std.testing.allocator, "{\"active_border_hex\":\"#00FF00\",\"opacity_step\":40,\"unknown_field\":1}");
    try std.testing.expectEqual(Color.rgb(0, 255, 0), c.active_border_color);
    try std.testing.expectEqual(@as(u8, 40), c.opacity_step);
    try std.testing.expectEqual(Config{}, Config.loadFromJson(std.testing.allocator, "not json"));
}

test "loadFromJson keeps default color on malformed hex without crashing" {
    const c = Config.loadFromJson(std.testing.allocator, "{\"active_border_hex\":\"#XYZ\"}");
    try std.testing.expectEqual(Config{}, c);

    const short = Config.loadFromJson(std.testing.allocator, "{\"active_border_hex\":\"FF880\"}");
    try std.testing.expectEqual(Config{}, short);
}

test "loadFromJson clamps out-of-range numeric settings" {
    const allocator = std.testing.allocator;
    const c = Config.loadFromJson(allocator, "{\"min_window_width\":-40,\"min_window_height\":0,\"log_max_days\":0,\"opacity_step\":255}");
    try std.testing.expectEqual(@as(i32, 50), c.min_window_width);
    try std.testing.expectEqual(@as(i32, 50), c.min_window_height);
    try std.testing.expectEqual(@as(u32, 1), c.log_max_days);
    try std.testing.expectEqual(@as(u8, 100), c.opacity_step);

    const low = Config.loadFromJson(allocator, "{\"opacity_step\":0}");
    try std.testing.expectEqual(@as(u8, 1), low.opacity_step);
}

test "serializeToJson roundtrips through loadFromJson" {
    const allocator = std.testing.allocator;
    var cfg = Config{ .language = .zh_CN, .enable_elevated = true, .opacity_step = 33, .min_window_width = 200 };
    cfg.key_center = 'Z';
    cfg.active_border_color = Color.rgb(0x55, 0xAA, 0x00);

    const json = try cfg.serializeToJson(allocator);
    defer allocator.free(json);

    try std.testing.expectEqual(cfg, Config.loadFromJson(allocator, json));
}

test "loadFromJson parses new keybindings and snap settings" {
    const allocator = std.testing.allocator;
    const c = Config.loadFromJson(allocator, "{\"key_maximize\":\"X\",\"key_restore_min\":\"R\",\"key_focus_left\":\"A\",\"enable_window_snap\":false,\"snap_threshold\":25}");
    try std.testing.expectEqual(@as(u32, 'X'), c.key_maximize);
    try std.testing.expectEqual(@as(u32, 'R'), c.key_restore_min);
    try std.testing.expectEqual(@as(u32, 'A'), c.key_focus_left);
    try std.testing.expect(!c.enable_window_snap);
    try std.testing.expectEqual(@as(i32, 25), c.snap_threshold);
}

test "Config blacklist roundtrip" {
    const allocator = std.testing.allocator;
    const json =
        \\{
        \\  "ignore_processes": ["photoshop.exe", "*blender*"],
        \\  "ignore_classes": ["UnityWndClass"]
        \\}
    ;
    var cfg = Config.loadFromJson(allocator, json);
    defer cfg.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), cfg.ignore_processes.len);
    try std.testing.expectEqualStrings("photoshop.exe", cfg.ignore_processes[0]);
    try std.testing.expectEqualStrings("*blender*", cfg.ignore_processes[1]);
    try std.testing.expectEqual(@as(usize, 1), cfg.ignore_classes.len);
    try std.testing.expectEqualStrings("UnityWndClass", cfg.ignore_classes[0]);

    const serialized = try cfg.serializeToJson(allocator);
    defer allocator.free(serialized);

    var roundtrip_cfg = Config.loadFromJson(allocator, serialized);
    defer roundtrip_cfg.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), roundtrip_cfg.ignore_processes.len);
    try std.testing.expectEqualStrings("photoshop.exe", roundtrip_cfg.ignore_processes[0]);
}

test "hasMissingFields detects old config without new keys" {
    // Old config missing new keys
    const old = "{\"language\":\"en\",\"key_center\":\"C\"}";
    try std.testing.expect(Config.hasMissingFields(old));

    // New config with all keys present
    const new_json = "{\"language\":\"en\",\"key_maximize\":\"M\",\"key_restore_min\":\"N\",\"key_focus_left\":\"H\",\"key_focus_down\":\"J\",\"key_focus_up\":\"K\",\"key_focus_right\":\"L\",\"enable_window_snap\":true,\"snap_threshold\":18,\"ignore_processes\":[],\"ignore_classes\":[]}";
    try std.testing.expect(!Config.hasMissingFields(new_json));
}
