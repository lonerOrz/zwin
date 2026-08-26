const std = @import("std");
const builtin = @import("builtin");
const t = @import("platform/win32.zig");
const App = @import("app.zig").App;

pub fn main() !void {
    const mutex_name = @import("app.zig").single_instance_mutex_name;
    const mutex = t.CreateMutexW(null, 1, mutex_name);
    if (t.GetLastError() == t.ERROR_ALREADY_EXISTS) {
        if (mutex) |m| _ = t.CloseHandle(m);
        return;
    }

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
