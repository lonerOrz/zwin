const std = @import("std");
const t = @import("../platform/win32.zig");

pub const Language = enum {
    auto,
    en,
    zh_CN,

    pub fn fromString(str: []const u8) Language {
        if (std.ascii.eqlIgnoreCase(str, "zh") or
            std.ascii.eqlIgnoreCase(str, "zh_cn") or
            std.ascii.eqlIgnoreCase(str, "zh-cn"))
        {
            return .zh_CN;
        }
        if (std.ascii.eqlIgnoreCase(str, "en") or
            std.ascii.eqlIgnoreCase(str, "en_us") or
            std.ascii.eqlIgnoreCase(str, "en-us"))
        {
            return .en;
        }
        return .auto;
    }

    pub fn toString(self: Language) []const u8 {
        return switch (self) {
            .auto => "auto",
            .en => "en",
            .zh_CN => "zh_CN",
        };
    }
};

pub const Strings = struct {
    tray_running: [*:0]const u16,
    tray_paused: [*:0]const u16,
    menu_pause: [*:0]const u16,
    menu_border: [*:0]const u16,
    menu_autostart: [*:0]const u16,
    menu_admin: [*:0]const u16,
    menu_normal: [*:0]const u16,
    menu_reload: [*:0]const u16,
    menu_restart: [*:0]const u16,
    menu_open_config: [*:0]const u16,
    menu_open_log: [*:0]const u16,
    menu_exit: [*:0]const u16,
};

const STRINGS_EN = blk: {
    @setEvalBranchQuota(20000);
    break :blk Strings{
        .tray_running = std.unicode.utf8ToUtf16LeStringLiteral("zwin (Running)"),
        .tray_paused = std.unicode.utf8ToUtf16LeStringLiteral("zwin (Paused)"),
        .menu_pause = std.unicode.utf8ToUtf16LeStringLiteral("Pause Interception (&Pause)"),
        .menu_border = std.unicode.utf8ToUtf16LeStringLiteral("Border Highlight (&Border)"),
        .menu_autostart = std.unicode.utf8ToUtf16LeStringLiteral("Run on Startup (&Autostart)"),
        .menu_admin = std.unicode.utf8ToUtf16LeStringLiteral("Run as Administrator (&Admin)"),
        .menu_normal = std.unicode.utf8ToUtf16LeStringLiteral("Run without Administrator (&Normal)"),
        .menu_reload = std.unicode.utf8ToUtf16LeStringLiteral("Reload Config (&Reload)"),
        .menu_restart = std.unicode.utf8ToUtf16LeStringLiteral("Restart zwin (&Restart)"),
        .menu_open_config = std.unicode.utf8ToUtf16LeStringLiteral("Open Config Folder..."),
        .menu_open_log = std.unicode.utf8ToUtf16LeStringLiteral("Open Log Folder..."),
        .menu_exit = std.unicode.utf8ToUtf16LeStringLiteral("Exit zwin (&Exit)"),
    };
};

const STRINGS_ZH = blk: {
    @setEvalBranchQuota(20000);
    break :blk Strings{
        .tray_running = std.unicode.utf8ToUtf16LeStringLiteral("zwin (运行中)"),
        .tray_paused = std.unicode.utf8ToUtf16LeStringLiteral("zwin (已暂停)"),
        .menu_pause = std.unicode.utf8ToUtf16LeStringLiteral("暂停拦截 (&Pause)"),
        .menu_border = std.unicode.utf8ToUtf16LeStringLiteral("边框高亮 (&Border)"),
        .menu_autostart = std.unicode.utf8ToUtf16LeStringLiteral("开机自启 (&Autostart)"),
        .menu_admin = std.unicode.utf8ToUtf16LeStringLiteral("以管理员身份运行 (&Admin)"),
        .menu_normal = std.unicode.utf8ToUtf16LeStringLiteral("退出管理员模式 (&Normal)"),
        .menu_reload = std.unicode.utf8ToUtf16LeStringLiteral("重载配置 (&Reload)"),
        .menu_restart = std.unicode.utf8ToUtf16LeStringLiteral("重启 zwin (&Restart)"),
        .menu_open_config = std.unicode.utf8ToUtf16LeStringLiteral("打开配置目录..."),
        .menu_open_log = std.unicode.utf8ToUtf16LeStringLiteral("打开日志目录..."),
        .menu_exit = std.unicode.utf8ToUtf16LeStringLiteral("退出 zwin (&Exit)"),
    };
};

pub const I18n = struct {
    pub fn resolveLanguage(lang: Language) Language {
        if (lang != .auto) return lang;
        const lang_id = t.GetUserDefaultUILanguage();
        // LANGID 主语言低 10 位；中文各变体（0x0804/0x0404/0x0C04...）主语言均为 0x04
        if ((lang_id & 0x03FF) == 0x0004) return .zh_CN;
        return .en;
    }

    pub fn getStrings(lang: Language) Strings {
        return switch (resolveLanguage(lang)) {
            .zh_CN => STRINGS_ZH,
            else => STRINGS_EN,
        };
    }
};

test "language string roundtrip" {
    try std.testing.expectEqual(Language.zh_CN, Language.fromString("zh_CN"));
    try std.testing.expectEqual(Language.zh_CN, Language.fromString("ZH-CN"));
    try std.testing.expectEqual(Language.en, Language.fromString("en"));
    try std.testing.expectEqual(Language.auto, Language.fromString("fr"));
}
