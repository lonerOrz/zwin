const std = @import("std");
const t = @import("../platform/win32.zig");
const Paths = @import("../platform/paths.zig").Paths;
const logger = @import("logger.zig");

pub const ConfigWatcher = struct {
    pub const CONFIG_CHANGED_EVENT: u32 = 0x9000;

    thread: ?std.Thread = null,
    running: std.atomic.Value(bool) = std.atomic.Value(bool).init(true),
    notify_hwnd: ?t.HWND = null,

    pub fn start(self: *ConfigWatcher, notify_hwnd: t.HWND) !void {
        self.notify_hwnd = notify_hwnd;
        self.running.store(true, .release);
        self.thread = try std.Thread.spawn(.{}, watcherLoop, .{self});
    }

    pub fn stop(self: *ConfigWatcher) void {
        self.running.store(false, .release);
        if (self.thread) |th| {
            th.join();
            self.thread = null;
        }
    }

    fn watcherLoop(self: *ConfigWatcher) void {
        const pa = std.heap.page_allocator;
        const dir = Paths.getXdgConfigDir(pa) catch return;
        defer pa.free(dir);

        const wide_dir = Paths.toWide(pa, dir) catch return;
        defer pa.free(wide_dir);

        const h_dir = t.CreateFileW(
            wide_dir.ptr,
            t.GENERIC_READ,
            t.FILE_SHARE_READ | t.FILE_SHARE_WRITE | t.FILE_SHARE_DELETE,
            null,
            t.OPEN_EXISTING,
            t.FILE_FLAG_BACKUP_SEMANTICS | t.FILE_FLAG_OVERLAPPED,
            null,
        );
        if (h_dir == t.INVALID_HANDLE_VALUE) return;
        defer _ = t.CloseHandle(h_dir);

        const ev = t.CreateEventW(null, t.TRUE, t.FALSE, null) orelse return;
        defer _ = t.CloseHandle(ev);

        logger.info("Watcher", "config directory watch started", .{});

        var buf: [1024]u8 align(@alignOf(u32)) = undefined;
        while (self.running.load(.acquire)) {
            var ov: t.OVERLAPPED = .{};
            ov.hEvent = ev;
            _ = t.ResetEvent(ev);

            var returned: u32 = 0;
            if (t.ReadDirectoryChangesW(
                h_dir,
                &buf,
                buf.len,
                t.FALSE,
                t.FILE_NOTIFY_CHANGE_LAST_WRITE | t.FILE_NOTIFY_CHANGE_FILE_NAME,
                &returned,
                &ov,
                null,
            ) == 0) break;

            while (self.running.load(.acquire)) {
                if (t.WaitForSingleObject(ev, 200) == t.WAIT_OBJECT_0) break;
            }
            if (!self.running.load(.acquire)) {
                // The kernel still holds &ov/&buf; cancel the pending request
                // and drain it before this stack frame is destroyed.
                _ = t.CancelIoEx(h_dir, &ov);
                var dropped: u32 = 0;
                _ = t.GetOverlappedResult(h_dir, &ov, &dropped, t.TRUE);
                break;
            }

            if (t.GetOverlappedResult(h_dir, &ov, &returned, t.FALSE) != 0 and returned > 0) {
                t.Sleep(150);
                if (self.notify_hwnd) |hwnd| {
                    _ = t.PostMessageW(hwnd, t.WM_APP_EVENT, CONFIG_CHANGED_EVENT, 0);
                    logger.info("Watcher", "config change detected, reload posted", .{});
                }
            }
        }
    }
};
