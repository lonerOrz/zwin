const std = @import("std");
const builtin = @import("builtin");
const t = @import("platform/win32.zig");
const App = @import("app.zig").App;
const resources = @import("platform/resources.zig");
const single_instance_mutex_name = @import("app.zig").single_instance_mutex_name;
const ConfigStore = @import("infra/config_store.zig").ConfigStore;

pub fn main() !void {
    // Declare Per-Monitor V2 DPI awareness before any window/GDI calls
    // to prevent DWM from applying blurry upscaling and coordinate drift
    const DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2: isize = -4;
    _ = t.SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);

    var gpa = if (builtin.mode == .Debug) std.heap.DebugAllocator(.{}){} else {};
    defer if (builtin.mode == .Debug) {
        _ = gpa.deinit();
    };
    const allocator = if (builtin.mode == .Debug) gpa.allocator() else std.heap.smp_allocator;

    // Enforce single instance before elevation to avoid redundant UAC prompts
    var mutex = t.CreateMutexW(null, 1, single_instance_mutex_name);
    if (t.GetLastError() == t.ERROR_ALREADY_EXISTS) {
        if (mutex) |m| _ = t.CloseHandle(m);
        return;
    }

    // Load config before elevation check so the same instance is reused
    const cfg = ConfigStore.load(allocator);

    // Early elevation handoff before initializing subsystems; fall back on cancel
    if (t.IsUserAnAdmin() == 0) {
        if (cfg.enable_elevated) {
            var path_buf: [1024]u16 = undefined;
            const len = t.GetModuleFileNameW(null, &path_buf, path_buf.len);
            if (len > 0 and len < path_buf.len) {
                if (mutex) |m| _ = t.CloseHandle(m);
                mutex = null;

                const res = t.ShellExecuteW(null, std.unicode.utf8ToUtf16LeStringLiteral("runas"), path_buf[0..len :0].ptr, null, null, 1);
                if (@intFromPtr(res) > 32) return;

                // Reclaim single instance mutex if elevation was canceled or failed
                mutex = t.CreateMutexW(null, 1, single_instance_mutex_name);
                if (t.GetLastError() == t.ERROR_ALREADY_EXISTS) {
                    if (mutex) |m| _ = t.CloseHandle(m);
                    return;
                }
            }
        }
    }

    const hinst = t.GetModuleHandleW(null);
    var app = try App.init(allocator, cfg);
    defer app.deinit();

    // Transfer mutex ownership to App for restart and deinit lifecycle management
    app.mutex = resources.SingleInstanceMutex.adopt(mutex);

    try app.start(hinst);

    var msg: t.MSG = undefined;
    while (t.GetMessageW(&msg, null, 0, 0) > 0) {
        _ = t.TranslateMessage(&msg);
        _ = t.DispatchMessageW(&msg);
    }
}
