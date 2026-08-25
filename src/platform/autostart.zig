const std = @import("std");
const t = @import("win32.zig");
const logger = @import("../infra/logger.zig");

const RUN_KEY_PATH = std.unicode.utf8ToUtf16LeStringLiteral("Software\\Microsoft\\Windows\\CurrentVersion\\Run");
const VALUE_NAME = std.unicode.utf8ToUtf16LeStringLiteral("zwin");

pub const Autostart = struct {
    pub fn isEnabled() bool {
        var hkey: t.HKEY = undefined;
        if (t.RegOpenKeyExW(t.HKEY_CURRENT_USER, RUN_KEY_PATH, 0, t.KEY_QUERY_VALUE, &hkey) != t.ERROR_SUCCESS) return false;
        defer _ = t.RegCloseKey(hkey);
        return t.RegQueryValueExW(hkey, VALUE_NAME, null, null, null, null) == t.ERROR_SUCCESS;
    }

    pub fn setEnabled(enable: bool) void {
        var hkey: t.HKEY = undefined;
        if (t.RegOpenKeyExW(t.HKEY_CURRENT_USER, RUN_KEY_PATH, 0, t.KEY_SET_VALUE | t.KEY_QUERY_VALUE, &hkey) != t.ERROR_SUCCESS) {
            logger.err("Autostart", "RegOpenKeyExW failed gle={d}", .{t.GetLastError()});
            return;
        }
        defer _ = t.RegCloseKey(hkey);

        if (!enable) {
            const s = t.RegDeleteValueW(hkey, VALUE_NAME);
            if (s == t.ERROR_SUCCESS or s == t.ERROR_FILE_NOT_FOUND) {
                logger.info("Autostart", "autostart entry removed", .{});
            } else {
                logger.warn("Autostart", "RegDeleteValueW status={d}", .{s});
            }
            return;
        }

        var path: [1024]u16 = undefined;
        const len = t.GetModuleFileNameW(null, &path, path.len);
        if (len == 0 or len >= path.len - 2) {
            logger.err("Autostart", "GetModuleFileNameW failed gle={d}", .{t.GetLastError()});
            return;
        }

        var quoted: [1027]u16 = undefined;
        quoted[0] = '"';
        @memcpy(quoted[1 .. len + 1], path[0..len]);
        quoted[len + 1] = '"';
        quoted[len + 2] = 0;

        const bytes: u32 = @intCast((len + 3) * 2);
        if (t.RegSetValueExW(hkey, VALUE_NAME, 0, t.REG_SZ, @ptrCast(&quoted), bytes) == t.ERROR_SUCCESS) {
            logger.info("Autostart", "autostart entry written", .{});
        } else {
            logger.err("Autostart", "RegSetValueExW failed", .{});
        }
    }
};
