const std = @import("std");
const builtin = @import("builtin");
const t = @import("platform/win32.zig");
const App = @import("app.zig").App;
const ConfigStore = @import("infra/config_store.zig").ConfigStore;

pub fn main() !void {
    var gpa = if (builtin.mode == .Debug)
        std.heap.DebugAllocator(.{}){}
    else {};
    _ = &gpa;
    defer if (builtin.mode == .Debug) {
        _ = gpa.deinit();
    };

    const allocator = if (builtin.mode == .Debug)
        gpa.allocator()
    else
        std.heap.smp_allocator;

    // Single-instance guard runs BEFORE any elevation attempt: a redundant
    // launch while zwin already runs must never pop a doomed UAC prompt.
    const mutex_name = @import("app.zig").single_instance_mutex_name;
    var mutex = t.CreateMutexW(null, 1, mutex_name);
    if (t.GetLastError() == t.ERROR_ALREADY_EXISTS) {
        if (mutex) |m| _ = t.CloseHandle(m);
        return;
    }

    // Startup privilege alignment: happens before windows, hooks, watcher or
    // logger exist, so a successful handoff abandons zero resources and a
    // declined UAC falls straight through to a normal unelevated run. This
    // is the ONLY place startup auto-elevation may occur — never in start().
    if (t.IsUserAnAdmin() == 0) {
        const cfg = ConfigStore.load(allocator);
        if (cfg.enable_elevated) {
            var path_buf: [1024]u16 = undefined;
            const len = t.GetModuleFileNameW(null, &path_buf, path_buf.len);
            if (len > 0 and len < path_buf.len) {
                if (mutex) |m| _ = t.CloseHandle(m);
                mutex = null;
                const res = t.ShellExecuteW(null, std.unicode.utf8ToUtf16LeStringLiteral("runas"), path_buf[0..len :0].ptr, null, null, 1);
                if (@intFromPtr(res) > 32) return;

                // Cancelled/failed: reclaim the single-instance slot (and
                // exit if another instance grabbed it in the meantime).
                mutex = t.CreateMutexW(null, 1, mutex_name);
                if (t.GetLastError() == t.ERROR_ALREADY_EXISTS) {
                    if (mutex) |m| _ = t.CloseHandle(m);
                    return;
                }
            }
        }
    }

    const hinst = t.GetModuleHandleW(null);

    var app = try App.init(allocator);
    defer app.deinit();
    // Ownership transfers to App: restart() must release it while the
    // process is still alive, and deinit() closes it on normal exit.
    app.single_instance_mutex = mutex;

    try app.start(hinst);

    var msg: t.MSG = undefined;
    while (t.GetMessageW(&msg, null, 0, 0) > 0) {
        _ = t.TranslateMessage(&msg);
        _ = t.DispatchMessageW(&msg);
    }
}
