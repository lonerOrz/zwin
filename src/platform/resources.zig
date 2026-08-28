const std = @import("std");
const t = @import("win32.zig");

fn intResource(id: usize) [*:0]align(1) const u16 {
    return @ptrFromInt(id);
}

pub const MessageWindow = struct {
    hwnd: t.HWND,

    pub fn create(
        hinst: ?t.HINSTANCE,
        wnd_proc: *const fn (t.HWND, u32, t.WPARAM, t.LPARAM) callconv(.winapi) t.LRESULT,
    ) !MessageWindow {
        const class_name = std.unicode.utf8ToUtf16LeStringLiteral("zwin_MsgWindow");
        const wnd_class = t.WNDCLASSEXW{
            .lpfnWndProc = wnd_proc,
            .hInstance = hinst,
            .lpszClassName = class_name,
        };
        _ = t.RegisterClassExW(&wnd_class);

        const hwnd = t.CreateWindowExW(
            0,
            class_name,
            class_name,
            0,
            0,
            0,
            0,
            0,
            null,
            null,
            hinst,
            null,
        ) orelse return error.WindowCreationFailed;

        return .{ .hwnd = hwnd };
    }

    pub fn destroy(self: *MessageWindow) void {
        _ = t.DestroyWindow(self.hwnd);
    }

    pub fn setTimer(self: MessageWindow, id: usize, elapse_ms: u32) void {
        _ = t.SetTimer(self.hwnd, id, elapse_ms, null);
    }

    pub fn killTimer(self: MessageWindow, id: usize) void {
        _ = t.KillTimer(self.hwnd, id);
    }
};

pub const TrayIcon = struct {
    nid: t.NOTIFYICONDATAW,
    hicon_enabled: ?t.HICON,
    hicon_disabled: ?t.HICON,

    pub fn init(hwnd: t.HWND, hinst: ?t.HINSTANCE) TrayIcon {
        const h_en = t.LoadIconW(hinst, intResource(3)) orelse t.LoadIconW(null, intResource(32512));
        const h_dis = t.LoadIconW(hinst, intResource(2)) orelse t.LoadIconW(null, intResource(32515));

        return .{
            .nid = .{
                .hWnd = hwnd,
                .uID = 1,
                .uFlags = t.NIF_MESSAGE | t.NIF_ICON | t.NIF_TIP,
                .uCallbackMessage = t.WM_TRAY,
                .hIcon = h_en,
            },
            .hicon_enabled = h_en,
            .hicon_disabled = h_dis,
        };
    }

    pub fn addToTaskbar(self: *TrayIcon) bool {
        return t.Shell_NotifyIconW(t.NIM_ADD, &self.nid) != 0;
    }

    pub fn update(self: *TrayIcon, is_paused: bool, tip_utf16: [*:0]const u16) void {
        var len: usize = 0;
        while (len < self.nid.szTip.len - 1 and tip_utf16[len] != 0) : (len += 1) {}
        @memcpy(self.nid.szTip[0..len], tip_utf16[0..len]);
        self.nid.szTip[len] = 0;

        self.nid.hIcon = if (is_paused) self.hicon_disabled else self.hicon_enabled;
        self.nid.uFlags = t.NIF_ICON | t.NIF_TIP;
        _ = t.Shell_NotifyIconW(t.NIM_MODIFY, &self.nid);
    }

    pub fn deinit(self: *TrayIcon) void {
        _ = t.Shell_NotifyIconW(t.NIM_DELETE, &self.nid);
    }
};

pub const WinEventHooks = struct {
    pub const CallbackFn = fn (t.HWINEVENTHOOK, u32, t.HWND, i32, i32, u32, u32) callconv(.winapi) void;

    fg_hook: ?t.HWINEVENTHOOK = null,
    loc_hook: ?t.HWINEVENTHOOK = null,
    obj_hook: ?t.HWINEVENTHOOK = null,

    pub fn install(callback: *const CallbackFn) WinEventHooks {
        return .{
            .fg_hook = t.SetWinEventHook(t.EVENT_SYSTEM_FOREGROUND, t.EVENT_SYSTEM_MINIMIZEEND, null, callback, 0, 0, t.WINEVENT_OUTOFCONTEXT),
            // Track location changes to refresh topmost badge/highlight when windows move
            .loc_hook = t.SetWinEventHook(t.EVENT_OBJECT_LOCATIONCHANGE, t.EVENT_OBJECT_LOCATIONCHANGE, null, callback, 0, 0, t.WINEVENT_OUTOFCONTEXT),
            .obj_hook = t.SetWinEventHook(t.EVENT_OBJECT_DESTROY, t.EVENT_OBJECT_HIDE, null, callback, 0, 0, t.WINEVENT_OUTOFCONTEXT),
        };
    }

    pub fn uninstall(self: *WinEventHooks) void {
        if (self.fg_hook) |h| _ = t.UnhookWinEvent(h);
        if (self.loc_hook) |h| _ = t.UnhookWinEvent(h);
        if (self.obj_hook) |h| _ = t.UnhookWinEvent(h);
        self.fg_hook = null;
        self.loc_hook = null;
        self.obj_hook = null;
    }
};

pub const SingleInstanceMutex = struct {
    handle: ?t.HANDLE = null,

    pub fn adopt(h: ?t.HANDLE) SingleInstanceMutex {
        return .{ .handle = h };
    }

    pub fn acquire(name: [*:0]const u16) ?SingleInstanceMutex {
        const h = t.CreateMutexW(null, 1, name) orelse return null;
        if (t.GetLastError() == t.ERROR_ALREADY_EXISTS) {
            _ = t.CloseHandle(h);
            return null;
        }
        return .{ .handle = h };
    }

    pub fn release(self: *SingleInstanceMutex) void {
        if (self.handle) |h| {
            _ = t.CloseHandle(h);
            self.handle = null;
        }
    }
};
