const std = @import("std");
const Language = @import("../infra/i18n.zig").Language;
pub const Color = @import("color.zig").Color;

pub const Config = struct {
    language: Language = .auto,

    key_center: u32 = 'C',
    key_topmost: u32 = 'T',
    key_close: u32 = 'Q',

    enable_border: bool = true,
    enable_wheel_opacity: bool = true,
    enable_autostart: bool = false,
    opacity_step: u8 = 15,

    active_border_color: Color = Color.rgb(255, 136, 0),

    min_window_width: i32 = 120,
    min_window_height: i32 = 100,

    log_max_days: u32 = 7,

    pub const default_json =
        \\{
        \\  "language": "auto",
        \\  "key_center": "C",
        \\  "key_topmost": "T",
        \\  "key_close": "Q",
        \\  "enable_border": true,
        \\  "enable_wheel_opacity": true,
        \\  "enable_autostart": false,
        \\  "opacity_step": 15,
        \\  "active_border_hex": "#FF8800",
        \\  "min_window_width": 120,
        \\  "min_window_height": 100,
        \\  "log_max_days": 7
        \\}
    ;

    pub fn serializeToJson(self: *const Config, allocator: std.mem.Allocator) ![]u8 {
        var hex_buf: [7]u8 = undefined;
        const hex = self.active_border_color.toHex(&hex_buf);

        return std.fmt.allocPrint(
            allocator,
            \\{{
            \\  "language": "{s}",
            \\  "key_center": "{c}",
            \\  "key_topmost": "{c}",
            \\  "key_close": "{c}",
            \\  "enable_border": {},
            \\  "enable_wheel_opacity": {},
            \\  "enable_autostart": {},
            \\  "opacity_step": {d},
            \\  "active_border_hex": "{s}",
            \\  "min_window_width": {d},
            \\  "min_window_height": {d},
            \\  "log_max_days": {d}
            \\}}
            \\
        ,
            .{
                self.language.toString(),
                @as(u8, @truncate(self.key_center)),
                @as(u8, @truncate(self.key_topmost)),
                @as(u8, @truncate(self.key_close)),
                self.enable_border,
                self.enable_wheel_opacity,
                self.enable_autostart,
                self.opacity_step,
                hex,
                self.min_window_width,
                self.min_window_height,
                self.log_max_days,
            },
        );
    }

    pub fn loadFromJson(allocator: std.mem.Allocator, json_bytes: []const u8) Config {
        var result = Config{};

        const Parsed = struct {
            language: ?[]const u8 = null,
            key_center: ?[]const u8 = null,
            key_topmost: ?[]const u8 = null,
            key_close: ?[]const u8 = null,
            enable_border: ?bool = null,
            enable_wheel_opacity: ?bool = null,
            enable_autostart: ?bool = null,
            opacity_step: ?u8 = null,
            active_border_hex: ?[]const u8 = null,
            min_window_width: ?i32 = null,
            min_window_height: ?i32 = null,
            log_max_days: ?u32 = null,
        };

        const parsed = std.json.parseFromSlice(Parsed, allocator, json_bytes, .{ .ignore_unknown_fields = true }) catch return result;
        defer parsed.deinit();

        const v = parsed.value;
        if (v.language) |lang| result.language = Language.fromString(lang);
        if (v.enable_border) |eb| result.enable_border = eb;
        if (v.enable_wheel_opacity) |wo| result.enable_wheel_opacity = wo;
        if (v.enable_autostart) |ea| result.enable_autostart = ea;
        if (v.opacity_step) |os| result.opacity_step = std.math.clamp(os, 1, 100);
        if (v.min_window_width) |mw| result.min_window_width = @max(mw, 50);
        if (v.min_window_height) |mh| result.min_window_height = @max(mh, 50);
        if (v.log_max_days) |ld| result.log_max_days = @max(ld, 1);

        if (v.key_center) |kc| if (kc.len > 0 and std.ascii.isAlphanumeric(kc[0])) {
            result.key_center = std.ascii.toUpper(kc[0]);
        };
        if (v.key_topmost) |kt| if (kt.len > 0 and std.ascii.isAlphanumeric(kt[0])) {
            result.key_topmost = std.ascii.toUpper(kt[0]);
        };
        if (v.key_close) |kc| if (kc.len > 0 and std.ascii.isAlphanumeric(kc[0])) {
            result.key_close = std.ascii.toUpper(kc[0]);
        };

        if (v.active_border_hex) |hex| {
            if (Color.fromHex(hex)) |c| result.active_border_color = c;
        }

        return result;
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
    var cfg = Config{ .language = .zh_CN, .opacity_step = 33, .min_window_width = 200 };
    cfg.key_center = 'Z';
    cfg.active_border_color = Color.rgb(0x55, 0xAA, 0x00);

    const json = try cfg.serializeToJson(allocator);
    defer allocator.free(json);

    try std.testing.expectEqual(cfg, Config.loadFromJson(allocator, json));
}
