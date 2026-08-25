const std = @import("std");

const t = @import("win32.zig");

pub const Paths = struct {
    pub fn getXdgConfigDir(allocator: std.mem.Allocator) ![]u8 {
        return envDir(allocator, "APPDATA", "XDG_CONFIG_HOME", "zwin");
    }

    pub fn getXdgLogDir(allocator: std.mem.Allocator) ![]u8 {
        return envDir(allocator, "LOCALAPPDATA", "XDG_STATE_HOME", "zwin\\logs");
    }

    pub fn toWide(allocator: std.mem.Allocator, path_u8: []const u8) ![:0]u16 {
        return std.unicode.utf8ToUtf16LeAllocZ(allocator, path_u8);
    }

    pub fn makeDirs(path_u8: []const u8) void {
        const wide = toWide(std.heap.page_allocator, path_u8) catch return;
        defer std.heap.page_allocator.free(wide);

        var buf: [1024]u16 = undefined;
        const n = @min(wide.len, buf.len - 1);
        @memcpy(buf[0..n], wide[0..n]);

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
        buf[n] = 0;
        _ = t.CreateDirectoryW(@ptrCast(&buf), null);
    }

    pub fn openAppend(path_u8: []const u8) !t.HANDLE {
        const wide = try toWide(std.heap.page_allocator, path_u8);
        defer std.heap.page_allocator.free(wide);
        const h = t.CreateFileW(wide.ptr, t.FILE_APPEND_DATA, t.FILE_SHARE_READ, null, t.OPEN_ALWAYS, t.FILE_ATTRIBUTE_NORMAL, null);
        if (h == t.INVALID_HANDLE_VALUE) return error.OpenFailed;
        return h;
    }

    pub fn openRead(path_u8: []const u8) !t.HANDLE {
        const wide = try toWide(std.heap.page_allocator, path_u8);
        defer std.heap.page_allocator.free(wide);
        const h = t.CreateFileW(wide.ptr, t.GENERIC_READ, t.FILE_SHARE_READ | t.FILE_SHARE_WRITE, null, t.OPEN_EXISTING, t.FILE_ATTRIBUTE_NORMAL, null);
        if (h == t.INVALID_HANDLE_VALUE) return error.OpenFailed;
        return h;
    }

    pub fn writeFile(path_u8: []const u8, content: []const u8) !void {
        const wide = try toWide(std.heap.page_allocator, path_u8);
        defer std.heap.page_allocator.free(wide);
        const h = t.CreateFileW(wide.ptr, t.GENERIC_WRITE, 0, null, t.CREATE_ALWAYS, t.FILE_ATTRIBUTE_NORMAL, null);
        if (h == t.INVALID_HANDLE_VALUE) return error.CreateFailed;
        defer _ = t.CloseHandle(h);

        var written: u32 = 0;
        _ = t.WriteFile(h, content.ptr, @intCast(content.len), &written, null);
    }

    pub fn openFolderInExplorer(path_u8: []const u8) void {
        const wide = toWide(std.heap.page_allocator, path_u8) catch return;
        defer std.heap.page_allocator.free(wide);
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

    pub fn deleteOldFiles(dir_u8: []const u8, comptime ascii_prefix: []const u8, comptime ascii_suffix: []const u8, max_days: u32) void {
        const prefix = std.unicode.utf8ToUtf16LeStringLiteral(ascii_prefix);
        const suffix = std.unicode.utf8ToUtf16LeStringLiteral(ascii_suffix);
        const pa = std.heap.page_allocator;

        const pattern = std.fmt.allocPrint(pa, "{s}\\*", .{dir_u8}) catch return;
        defer pa.free(pattern);
        const pattern_wide = toWide(pa, pattern) catch return;
        defer pa.free(pattern_wide);

        const dir_wide = toWide(pa, dir_u8) catch return;
        defer pa.free(dir_wide);

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

fn envDir(allocator: std.mem.Allocator, comptime primary_var: [:0]const u8, comptime fallback_var: [:0]const u8, comptime sub_path: []const u8) ![]u8 {
    var wide_buf: [1024]u16 = undefined;
    const n = t.GetEnvironmentVariableW(std.unicode.utf8ToUtf16LeStringLiteral(primary_var), &wide_buf, wide_buf.len);
    const m = if (n > 0 and n <= wide_buf.len)
        n
    else
        t.GetEnvironmentVariableW(std.unicode.utf8ToUtf16LeStringLiteral(fallback_var), &wide_buf, wide_buf.len);
    if (m == 0 or m > wide_buf.len) return error.CannotResolveDir;

    const base = try std.unicode.utf16LeToUtf8Alloc(allocator, wide_buf[0..m]);
    defer allocator.free(base);

    if (base.len > 0 and base[0] == '/') return error.InvalidWindowsPath;

    return std.fmt.allocPrint(allocator, "{s}\\{s}", .{ base, sub_path });
}
