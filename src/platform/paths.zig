const std = @import("std");

const t = @import("win32.zig");

pub const Paths = struct {
    pub fn getConfigDir(allocator: std.mem.Allocator) ![]u8 {
        return envDir(allocator, "APPDATA", "zwin");
    }

    pub fn getLogDir(allocator: std.mem.Allocator) ![]u8 {
        return envDir(allocator, "LOCALAPPDATA", "zwin\\logs");
    }

    pub fn toWide(allocator: std.mem.Allocator, path_u8: []const u8) ![:0]u16 {
        return std.unicode.utf8ToUtf16LeAllocZ(allocator, path_u8);
    }

    /// Pure stack conversion for short-lived paths (no heap allocation).
    /// Capacity is judged in UTF-16 code units, not UTF-8 bytes: multibyte
    /// sequences shrink on conversion, so a byte-length precheck would
    /// wrongly reject valid non-ASCII paths. std.unicode.utf8ToUtf16Le has
    /// no NoSpaceLeft error (it would overflow), hence the exact count here.
    pub fn toWideFixed(path_u8: []const u8, out_buf: *[t.MAX_PATH:0]u16) ![:0]const u16 {
        const units = std.unicode.calcUtf16LeLen(path_u8) catch return error.InvalidPath;
        if (units >= t.MAX_PATH) return error.PathTooLong;
        const len = std.unicode.utf8ToUtf16Le(out_buf, path_u8) catch return error.InvalidPath;
        out_buf[len] = 0;
        return out_buf[0..len :0];
    }

    pub fn makeDirs(path_u8: []const u8) void {
        var buf: [t.MAX_PATH:0]u16 = undefined;
        const wide = toWideFixed(path_u8, &buf) catch return;
        const n = wide.len;

        var i: usize = 0;
        if (n >= 3 and buf[1] == ':' and buf[2] == '\\') {
            i = 3;
        }
        while (i < n) : (i += 1) {
            if (buf[i] == '\\' and i > 0) {
                buf[i] = 0;
                _ = t.CreateDirectoryW(@ptrCast(&buf), null);
                buf[i] = '\\';
            }
        }
        _ = t.CreateDirectoryW(@ptrCast(&buf), null);
    }

    pub fn openAppend(path_u8: []const u8) !t.HANDLE {
        var wide_buf: [t.MAX_PATH:0]u16 = undefined;
        const wide = try toWideFixed(path_u8, &wide_buf);
        const h = t.CreateFileW(wide.ptr, t.FILE_APPEND_DATA, t.FILE_SHARE_READ, null, t.OPEN_ALWAYS, t.FILE_ATTRIBUTE_NORMAL, null);
        if (h == t.INVALID_HANDLE_VALUE) return error.OpenFailed;
        return h;
    }

    pub fn openRead(path_u8: []const u8) !t.HANDLE {
        var wide_buf: [t.MAX_PATH:0]u16 = undefined;
        const wide = try toWideFixed(path_u8, &wide_buf);
        const h = t.CreateFileW(wide.ptr, t.GENERIC_READ, t.FILE_SHARE_READ | t.FILE_SHARE_WRITE, null, t.OPEN_EXISTING, t.FILE_ATTRIBUTE_NORMAL, null);
        if (h == t.INVALID_HANDLE_VALUE) {
            // Callers must be able to tell "no config yet" apart from a
            // transient sharing conflict so they never overwrite real data.
            return switch (t.GetLastError()) {
                t.ERROR_FILE_NOT_FOUND, t.ERROR_PATH_NOT_FOUND => error.FileNotFound,
                t.ERROR_SHARING_VIOLATION => error.SharingViolation,
                else => error.OpenFailed,
            };
        }
        return h;
    }

    pub fn writeFile(path_u8: []const u8, content: []const u8) !void {
        var wide_buf: [t.MAX_PATH:0]u16 = undefined;
        const wide = try toWideFixed(path_u8, &wide_buf);
        const h = t.CreateFileW(wide.ptr, t.GENERIC_WRITE, t.FILE_SHARE_READ, null, t.CREATE_ALWAYS, t.FILE_ATTRIBUTE_NORMAL, null);
        if (h == t.INVALID_HANDLE_VALUE) return error.CreateFailed;
        defer _ = t.CloseHandle(h);

        var written: u32 = 0;
        _ = t.WriteFile(h, content.ptr, @intCast(content.len), &written, null);
    }

    pub fn openFolderInExplorer(allocator: std.mem.Allocator, path_u8: []const u8) void {
        const wide = toWide(allocator, path_u8) catch return;
        defer allocator.free(wide);
        _ = t.ShellExecuteW(null, std.unicode.utf8ToUtf16LeStringLiteral("open"), wide.ptr, null, null, 1);
    }

    pub fn readSmallFile(allocator: std.mem.Allocator, path_u8: []const u8, max_bytes: usize) ![]u8 {
        const h = try openRead(path_u8);
        defer _ = t.CloseHandle(h);

        var cap = @min(max_bytes, 64 * 1024 * 1024);
        var size: i64 = 0;
        if (t.GetFileSizeEx(h, &size) != 0 and size > 0) {
            cap = @min(cap, @as(usize, @intCast(size)));
        }
        if (cap == 0) return allocator.alloc(u8, 0);

        const buf = try allocator.alloc(u8, cap);
        errdefer allocator.free(buf);

        var total: usize = 0;
        while (total < cap) {
            var read: u32 = 0;
            if (t.ReadFile(h, buf[total..].ptr, @intCast(cap - total), &read, null) == 0 or read == 0) break;
            total += read;
        }
        if (total == 0) {
            allocator.free(buf);
            return allocator.alloc(u8, 0);
        }
        return allocator.realloc(buf, total) catch buf[0..total];
    }

    pub fn deleteOldFiles(allocator: std.mem.Allocator, dir_u8: []const u8, comptime ascii_prefix: []const u8, comptime ascii_suffix: []const u8, max_days: u32) void {
        const prefix = std.unicode.utf8ToUtf16LeStringLiteral(ascii_prefix);
        const suffix = std.unicode.utf8ToUtf16LeStringLiteral(ascii_suffix);

        const pattern = std.fmt.allocPrint(allocator, "{s}\\*", .{dir_u8}) catch return;
        defer allocator.free(pattern);
        const pattern_wide = toWide(allocator, pattern) catch return;
        defer allocator.free(pattern_wide);

        const dir_wide = toWide(allocator, dir_u8) catch return;
        defer allocator.free(dir_wide);

        var fd: t.WIN32_FIND_DATAW = std.mem.zeroes(t.WIN32_FIND_DATAW);
        const handle = t.FindFirstFileW(pattern_wide.ptr, &fd);
        if (handle == t.INVALID_HANDLE_VALUE) return;
        defer _ = t.FindClose(handle);

        const now = t.unixNow();
        const max_diff: i64 = @as(i64, max_days) * 86400;

        var full_buf: [1080]u16 = undefined;
        while (true) {
            const name_len = std.mem.indexOfScalar(u16, &fd.cFileName, 0) orelse fd.cFileName.len;
            const name = fd.cFileName[0..name_len];
            if (name.len > prefix.len + suffix.len and
                std.mem.startsWith(u16, name, prefix) and
                std.mem.endsWith(u16, name, suffix))
            {
                const age = now - fd.ftLastWriteTime.toUnixSeconds();
                if (age > max_diff) {
                    const full_len = dir_wide.len + 1 + name.len;
                    if (full_len < full_buf.len) {
                        @memcpy(full_buf[0..dir_wide.len], dir_wide);
                        full_buf[dir_wide.len] = '\\';
                        @memcpy(full_buf[dir_wide.len + 1 ..][0..name.len], name);
                        full_buf[full_len] = 0;
                        _ = t.DeleteFileW(@ptrCast(&full_buf));
                    }
                }
            }
            if (t.FindNextFileW(handle, &fd) == 0) break;
        }
    }
};

fn envDir(allocator: std.mem.Allocator, comptime env_var: [:0]const u8, comptime sub_path: []const u8) ![]u8 {
    var wide_buf: [1024]u16 = undefined;
    const n = t.GetEnvironmentVariableW(std.unicode.utf8ToUtf16LeStringLiteral(env_var), &wide_buf, wide_buf.len);
    if (n == 0 or n > wide_buf.len) return error.CannotResolveDir;

    const base = try std.unicode.utf16LeToUtf8Alloc(allocator, wide_buf[0..n]);

    return std.fmt.allocPrint(allocator, "{s}\\{s}", .{ base, sub_path });
}

test "toWideFixed stack conversion contract" {
    var buf: [t.MAX_PATH:0]u16 = undefined;

    const wide = try Paths.toWideFixed("C:\\foo\\bar.txt", &buf);
    try std.testing.expectEqual(@as(usize, 14), wide.len);
    try std.testing.expectEqual(@as(u16, 'C'), wide[0]);
    try std.testing.expectEqual(@as(u16, 0), buf[wide.len]);

    // Exactly MAX_PATH - 1 bytes must fit.
    const max_ok = "a" ** (t.MAX_PATH - 1);
    const wide_max = try Paths.toWideFixed(max_ok, &buf);
    try std.testing.expectEqual(t.MAX_PATH - 1, wide_max.len);

    // MAX_PATH and beyond must fail without writing out of bounds.
    try std.testing.expectError(error.PathTooLong, Paths.toWideFixed("a" ** t.MAX_PATH, &buf));
    try std.testing.expectError(error.PathTooLong, Paths.toWideFixed("a" ** 400, &buf));

    // Multibyte UTF-8 shrinks to fewer UTF-16 units: 300 CJK bytes (>=
    // MAX_PATH in bytes) convert to only 100 units and must be accepted.
    const wide_cjk = try Paths.toWideFixed("中" ** 100, &buf);
    try std.testing.expectEqual(@as(usize, 100), wide_cjk.len);

    // Invalid UTF-8 must surface as InvalidPath, not crash.
    try std.testing.expectError(error.InvalidPath, Paths.toWideFixed("\xff\xfe bad", &buf));
}
