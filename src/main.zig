const std = @import("std");
const builtin = @import("builtin");
const t = @import("platform/win32.zig");
const App = @import("app.zig").App;

pub fn main() !void {
    const mutex_name = std.unicode.utf8ToUtf16LeStringLiteral("zwin_SingleInstance_Mutex");
    const mutex = t.CreateMutexW(null, 1, mutex_name);
    if (t.GetLastError() == t.ERROR_ALREADY_EXISTS) return;
    defer {
        if (mutex) |m| _ = t.CloseHandle(m);
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

    try app.start(hinst);

    var msg: t.MSG = undefined;
    while (t.GetMessageW(&msg, null, 0, 0) > 0) {
        _ = t.TranslateMessage(&msg);
        _ = t.DispatchMessageW(&msg);
    }
}
