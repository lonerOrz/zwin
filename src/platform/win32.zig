const std = @import("std");
pub const win = std.os.windows;

pub const HWND = win.HWND;
pub const BOOL = c_int;
pub const TRUE: BOOL = 1;
pub const FALSE: BOOL = 0;
pub const SRWLOCK = extern struct { ptr: ?*anyopaque = null };
pub const CONDITION_VARIABLE = extern struct { ptr: ?*anyopaque = null };
pub const INFINITE: u32 = 0xFFFFFFFF;

pub const RECT = extern struct { left: i32, top: i32, right: i32, bottom: i32 };
pub const POINT = extern struct { x: i32, y: i32 };
pub const WPARAM = usize;
pub const LPARAM = isize;
pub const LRESULT = isize;
pub const HHOOK = *opaque {};
pub const HMONITOR = *opaque {};
pub const HWINEVENTHOOK = *opaque {};
pub const HANDLE = win.HANDLE;
pub const HINSTANCE = win.HINSTANCE;
pub const HICON = *opaque {};
pub const HMENU = *opaque {};

pub const INVALID_HANDLE_VALUE: HANDLE = @ptrFromInt(std.math.maxInt(usize));

pub const MSLLHOOKSTRUCT = extern struct {
    pt: POINT,
    mouseData: u32,
    flags: u32,
    time: u32,
    dwExtraInfo: usize,
};

pub const KBDLLHOOKSTRUCT = extern struct {
    vkCode: u32,
    scanCode: u32,
    flags: u32,
    time: u32,
    dwExtraInfo: usize,
};

pub const MONITORINFO = extern struct {
    cbSize: u32 = @sizeOf(MONITORINFO),
    rcMonitor: RECT,
    rcWork: RECT,
    dwFlags: u32,
};

pub const MSG = extern struct {
    hwnd: ?HWND,
    message: u32,
    wParam: WPARAM,
    lParam: LPARAM,
    time: u32,
    pt: POINT,
    lPrivate: u32,
};

pub const WNDCLASSEXW = extern struct {
    cbSize: u32 = @sizeOf(@This()),
    style: u32 = 0,
    lpfnWndProc: *const fn (HWND, u32, WPARAM, LPARAM) callconv(.winapi) LRESULT,
    cbClsExtra: i32 = 0,
    cbWndExtra: i32 = 0,
    hInstance: ?HINSTANCE,
    hIcon: ?HICON = null,
    hCursor: ?*anyopaque = null,
    hbrBackground: ?*anyopaque = null,
    lpszMenuName: ?[*:0]const u16 = null,
    lpszClassName: [*:0]const u16,
    hIconSm: ?HICON = null,
};

pub const MOUSEINPUT = extern struct {
    dx: i32,
    dy: i32,
    mouseData: u32,
    dwFlags: u32,
    time: u32,
    dwExtraInfo: usize,
};

pub const KEYBDINPUT = extern struct {
    wVk: u16,
    wScan: u16,
    dwFlags: u32,
    time: u32,
    dwExtraInfo: usize,
};

pub const HARDWAREINPUT = extern struct {
    uMsg: u32,
    wParamL: u16,
    wParamH: u16,
};

pub const INPUT = extern struct {
    type: u32,
    pad: u32 = 0,
    unnamed: extern union {
        mi: MOUSEINPUT,
        ki: KEYBDINPUT,
        hi: HARDWAREINPUT,
    },
};

pub const GUID = extern struct {
    Data1: u32,
    Data2: u16,
    Data3: u16,
    Data4: [8]u8,
};

pub const NOTIFYICONDATAW = extern struct {
    cbSize: u32 = @sizeOf(NOTIFYICONDATAW),
    hWnd: HWND,
    uID: u32,
    uFlags: u32,
    uCallbackMessage: u32,
    hIcon: ?HICON,
    szTip: [128]u16 = [_]u16{0} ** 128,
    dwState: u32 = 0,
    dwStateMask: u32 = 0,
    szInfo: [256]u16 = [_]u16{0} ** 256,
    uTimeoutOrVersion: u32 = 0,
    szInfoTitle: [64]u16 = [_]u16{0} ** 64,
    dwInfoFlags: u32 = 0,
    guidItem: GUID = std.mem.zeroes(GUID),
    hBalloonIcon: ?HANDLE = null,
};

comptime {
    if (@sizeOf(INPUT) != 40) @compileError("INPUT layout must be 40 bytes on x64");
}

pub const WIN32_FIND_DATAW = extern struct {
    dwFileAttributes: u32,
    ftCreationTime: FILETIME,
    ftLastAccessTime: FILETIME,
    ftLastWriteTime: FILETIME,
    nFileSizeHigh: u32,
    nFileSizeLow: u32,
    dwReserved0: u32,
    dwReserved1: u32,
    cFileName: [260]u16,
    cAlternateFileName: [14]u16,
};

pub const FILETIME = extern struct {
    dwLowDateTime: u32,
    dwHighDateTime: u32,

    pub fn toUnixSeconds(self: FILETIME) i64 {
        const q: u64 = (@as(u64, self.dwHighDateTime) << 32) | self.dwLowDateTime;
        const sec: i64 = @intCast(q / 10_000_000);
        return @max(sec - 11644473600, 0);
    }
};

pub extern "kernel32" fn AcquireSRWLockExclusive(SRWLock: *SRWLOCK) callconv(.winapi) void;
pub extern "kernel32" fn ReleaseSRWLockExclusive(SRWLock: *SRWLOCK) callconv(.winapi) void;
pub extern "kernel32" fn SleepConditionVariableSRW(ConditionVariable: *CONDITION_VARIABLE, SRWLock: *SRWLOCK, dwMilliseconds: u32, Flags: u32) callconv(.winapi) BOOL;
pub extern "kernel32" fn WakeConditionVariable(ConditionVariable: *CONDITION_VARIABLE) callconv(.winapi) void;
pub extern "kernel32" fn CreateMutexW(lpMutexAttributes: ?*anyopaque, bInitialOwner: BOOL, lpName: ?[*:0]const u16) callconv(.winapi) ?HANDLE;
pub extern "kernel32" fn GetLastError() callconv(.winapi) u32;
pub extern "kernel32" fn GetModuleHandleW(lpModuleName: ?[*:0]const u16) callconv(.winapi) ?HINSTANCE;
pub extern "kernel32" fn CloseHandle(hObject: HANDLE) callconv(.winapi) BOOL;
pub extern "kernel32" fn GetCurrentThreadId() callconv(.winapi) u32;
pub extern "kernel32" fn GetTickCount64() callconv(.winapi) u64;
pub extern "kernel32" fn Sleep(dwMilliseconds: u32) callconv(.winapi) void;
pub extern "kernel32" fn GetEnvironmentVariableW(lpName: [*:0]const u16, lpBuffer: [*]u16, nSize: u32) callconv(.winapi) u32;
pub extern "kernel32" fn CreateDirectoryW(lpPathName: [*:0]const u16, lpSecurityAttributes: ?*anyopaque) callconv(.winapi) BOOL;
pub extern "kernel32" fn DeleteFileW(lpFileName: [*:0]const u16) callconv(.winapi) BOOL;
pub extern "kernel32" fn CreateFileW(lpFileName: [*:0]const u16, dwDesiredAccess: u32, dwShareMode: u32, lpSecurityAttributes: ?*anyopaque, dwCreationDisposition: u32, dwFlagsAndAttributes: u32, hTemplateFile: ?HANDLE) callconv(.winapi) HANDLE;
pub extern "kernel32" fn ReadFile(hFile: HANDLE, lpBuffer: [*]u8, nNumberOfBytesToRead: u32, lpNumberOfBytesRead: ?*u32, lpOverlapped: ?*anyopaque) callconv(.winapi) BOOL;
pub extern "kernel32" fn GetFileSizeEx(hFile: HANDLE, lpFileSize: *i64) callconv(.winapi) BOOL;
pub extern "kernel32" fn WriteFile(hFile: HANDLE, lpBuffer: [*]const u8, nNumberOfBytesToWrite: u32, lpNumberOfBytesWritten: ?*u32, lpOverlapped: ?*anyopaque) callconv(.winapi) BOOL;
pub extern "kernel32" fn ReadDirectoryChangesW(hDirectory: HANDLE, lpBuffer: [*]u8, nBufferLength: u32, bWatchSubtree: BOOL, dwNotifyFilter: u32, lpBytesReturned: ?*u32, lpOverlapped: *OVERLAPPED, lpCompletionRoutine: ?*anyopaque) callconv(.winapi) BOOL;
pub extern "kernel32" fn GetOverlappedResult(hFile: HANDLE, lpOverlapped: *OVERLAPPED, lpNumberOfBytesTransferred: *u32, bWait: BOOL) callconv(.winapi) BOOL;
pub extern "kernel32" fn CancelIoEx(hFile: HANDLE, lpOverlapped: ?*OVERLAPPED) callconv(.winapi) BOOL;
pub extern "kernel32" fn CreateEventW(lpEventAttributes: ?*anyopaque, bManualReset: BOOL, bInitialState: BOOL, lpName: ?[*:0]const u16) callconv(.winapi) ?HANDLE;
pub extern "kernel32" fn ResetEvent(hEvent: HANDLE) callconv(.winapi) BOOL;
pub extern "kernel32" fn WaitForSingleObject(hHandle: HANDLE, dwMilliseconds: u32) callconv(.winapi) u32;

pub const OVERLAPPED = extern struct {
    Internal: usize = 0,
    InternalHigh: usize = 0,
    DUMMYUNIONNAME: extern union { Offset: u32, Pointer: ?*anyopaque } = .{ .Offset = 0 },
    hEvent: ?HANDLE = null,
};
pub const WAIT_OBJECT_0: u32 = 0;
pub extern "kernel32" fn FindFirstFileW(lpFileName: [*:0]const u16, lpFindFileData: *WIN32_FIND_DATAW) callconv(.winapi) HANDLE;
pub extern "kernel32" fn FindNextFileW(hFindFile: HANDLE, lpFindFileData: *WIN32_FIND_DATAW) callconv(.winapi) BOOL;
pub extern "kernel32" fn FindClose(hFindFile: HANDLE) callconv(.winapi) BOOL;
pub extern "kernel32" fn GetSystemTimeAsFileTime(lpSystemTimeAsFileTime: *FILETIME) callconv(.winapi) void;

pub const SYSTEMTIME = extern struct {
    wYear: u16,
    wMonth: u16,
    wDayOfWeek: u16,
    wDay: u16,
    wHour: u16,
    wMinute: u16,
    wSecond: u16,
    wMilliseconds: u16,
};
pub extern "kernel32" fn GetLocalTime(lpSystemTime: *SYSTEMTIME) callconv(.winapi) void;

pub fn unixNow() i64 {
    var ft: FILETIME = undefined;
    GetSystemTimeAsFileTime(&ft);
    return ft.toUnixSeconds();
}

pub extern "user32" fn SetWindowsHookExW(idHook: i32, lpfn: *const fn (i32, WPARAM, LPARAM) callconv(.winapi) LRESULT, hmod: ?HINSTANCE, dwThreadId: u32) callconv(.winapi) ?HHOOK;
pub extern "user32" fn UnhookWindowsHookEx(hhk: HHOOK) callconv(.winapi) BOOL;
pub extern "user32" fn CallNextHookEx(hhk: ?HHOOK, nCode: i32, wParam: WPARAM, lParam: LPARAM) callconv(.winapi) LRESULT;
pub extern "user32" fn GetMessageW(lpMsg: *MSG, hWnd: ?HWND, wMsgFilterMin: u32, wMsgFilterMax: u32) callconv(.winapi) BOOL;
pub extern "user32" fn TranslateMessage(lpMsg: *const MSG) callconv(.winapi) BOOL;
pub extern "user32" fn DispatchMessageW(lpMsg: *const MSG) callconv(.winapi) LRESULT;
pub extern "user32" fn PostQuitMessage(nExitCode: i32) callconv(.winapi) void;
pub extern "user32" fn PostMessageW(hWnd: ?HWND, Msg: u32, wParam: WPARAM, lParam: LPARAM) callconv(.winapi) BOOL;
pub extern "user32" fn GetCursorPos(lpPoint: *POINT) callconv(.winapi) BOOL;
pub extern "user32" fn WindowFromPoint(Point: POINT) callconv(.winapi) ?HWND;
pub extern "user32" fn GetAncestor(hwnd: HWND, gaFlags: u32) callconv(.winapi) ?HWND;
pub extern "user32" fn GetWindowRect(hwnd: HWND, lpRect: *RECT) callconv(.winapi) BOOL;
pub extern "user32" fn SetWindowPos(hwnd: HWND, hWndInsertAfter: ?HWND, X: i32, Y: i32, cx: i32, cy: i32, uFlags: u32) callconv(.winapi) BOOL;
pub extern "user32" fn ShowWindow(hwnd: HWND, nCmdShow: i32) callconv(.winapi) BOOL;
pub extern "user32" fn IsZoomed(hwnd: HWND) callconv(.winapi) BOOL;
pub extern "user32" fn IsWindowVisible(hwnd: HWND) callconv(.winapi) BOOL;
pub extern "user32" fn IsWindow(hWnd: HWND) callconv(.winapi) BOOL;
pub extern "user32" fn SetTimer(hWnd: ?HWND, nIDEvent: usize, uElapse: u32, lpTimerFunc: ?*const anyopaque) callconv(.winapi) usize;
pub extern "user32" fn KillTimer(hWnd: ?HWND, uIDEvent: usize) callconv(.winapi) BOOL;

pub extern "kernel32" fn GetModuleFileNameW(hModule: ?HINSTANCE, lpFilename: [*]u16, nSize: u32) callconv(.winapi) u32;
pub extern "kernel32" fn GetUserDefaultUILanguage() callconv(.winapi) u16;
pub extern "user32" fn GetDpiForWindow(hwnd: HWND) callconv(.winapi) u32;

pub const HKEY = *opaque {};
pub const HKEY_CURRENT_USER: HKEY = @ptrFromInt(@as(usize, 0x80000001));
pub const KEY_QUERY_VALUE: u32 = 0x0001;
pub const KEY_SET_VALUE: u32 = 0x0002;
pub const REG_SZ: u32 = 1;
pub const ERROR_SUCCESS: i32 = 0;
pub const ERROR_FILE_NOT_FOUND: i32 = 2;

pub extern "advapi32" fn RegOpenKeyExW(hKey: HKEY, lpSubKey: [*:0]const u16, ulOptions: u32, samDesired: u32, phkResult: *HKEY) callconv(.winapi) i32;
pub extern "advapi32" fn RegQueryValueExW(hKey: HKEY, lpValueName: [*:0]const u16, lpReserved: ?*anyopaque, lpType: ?*u32, lpData: ?*anyopaque, lpcbData: ?*u32) callconv(.winapi) i32;
pub extern "advapi32" fn RegSetValueExW(hKey: HKEY, lpValueName: [*:0]const u16, Reserved: u32, dwType: u32, lpData: [*]const u8, cbData: u32) callconv(.winapi) i32;
pub extern "advapi32" fn RegDeleteValueW(hKey: HKEY, lpValueName: [*:0]const u16) callconv(.winapi) i32;
pub extern "advapi32" fn RegCloseKey(hKey: HKEY) callconv(.winapi) i32;
pub extern "user32" fn GetAsyncKeyState(vKey: i32) callconv(.winapi) i16;
pub extern "user32" fn GetClassNameW(hwnd: HWND, lpClassName: [*]u16, nMaxCount: i32) callconv(.winapi) i32;
pub extern "user32" fn GetForegroundWindow() callconv(.winapi) ?HWND;
pub extern "user32" fn SetForegroundWindow(hwnd: HWND) callconv(.winapi) BOOL;
pub extern "user32" fn MonitorFromWindow(hwnd: HWND, dwFlags: u32) callconv(.winapi) ?HMONITOR;
pub extern "user32" fn GetMonitorInfoW(hMonitor: ?HMONITOR, lpmi: *MONITORINFO) callconv(.winapi) BOOL;
pub extern "user32" fn GetWindowLongPtrW(hwnd: HWND, nIndex: i32) callconv(.winapi) isize;
pub extern "user32" fn SendInput(cInputs: u32, pInputs: [*]const INPUT, cbSize: i32) callconv(.winapi) u32;
pub extern "user32" fn SetWindowLongPtrW(hwnd: HWND, nIndex: i32, dwNewLong: isize) callconv(.winapi) isize;
pub extern "user32" fn SetLayeredWindowAttributes(hwnd: HWND, crKey: u32, bAlpha: u8, dwFlags: u32) callconv(.winapi) BOOL;
pub extern "user32" fn GetLayeredWindowAttributes(hwnd: HWND, pcrKey: ?*u32, pbAlpha: ?*u8, pdwFlags: ?*u32) callconv(.winapi) BOOL;
pub extern "user32" fn SetWinEventHook(eventMin: u32, eventMax: u32, hmod: ?HINSTANCE, pfn: *const fn (HWINEVENTHOOK, u32, HWND, i32, i32, u32, u32) callconv(.winapi) void, idProcess: u32, idThread: u32, dwFlags: u32) callconv(.winapi) ?HWINEVENTHOOK;
pub extern "user32" fn UnhookWinEvent(hWinEventHook: HWINEVENTHOOK) callconv(.winapi) BOOL;
pub extern "user32" fn CreatePopupMenu() callconv(.winapi) ?HMENU;
pub extern "user32" fn DestroyMenu(hMenu: HMENU) callconv(.winapi) BOOL;
pub extern "user32" fn AppendMenuW(hMenu: HMENU, uFlags: u32, uIDNewItem: usize, lpNewItem: ?[*:0]const u16) callconv(.winapi) BOOL;
pub extern "user32" fn TrackPopupMenu(hMenu: HMENU, uFlags: u32, x: i32, y: i32, nReserved: i32, hWnd: HWND, prcRect: ?*const RECT) callconv(.winapi) BOOL;
pub extern "user32" fn DefWindowProcW(hWnd: HWND, Msg: u32, wParam: WPARAM, lParam: LPARAM) callconv(.winapi) LRESULT;
pub extern "user32" fn RegisterClassExW(lpwcx: *const anyopaque) callconv(.winapi) u16;
pub extern "user32" fn CreateWindowExW(dwExStyle: u32, lpClassName: [*:0]const u16, lpWindowName: [*:0]const u16, dwStyle: u32, X: i32, Y: i32, nWidth: i32, nHeight: i32, hWndParent: ?HWND, hMenu: ?HMENU, hInstance: ?HINSTANCE, lpParam: ?*anyopaque) callconv(.winapi) ?HWND;
pub extern "user32" fn DestroyWindow(hWnd: HWND) callconv(.winapi) BOOL;
pub extern "user32" fn LoadIconW(hInstance: ?HINSTANCE, lpIconName: ?[*:0]const u16) callconv(.winapi) ?HICON;
pub extern "shell32" fn Shell_NotifyIconW(dwMessage: u32, lpData: *NOTIFYICONDATAW) callconv(.winapi) BOOL;
pub extern "shell32" fn ShellExecuteW(hwnd: ?HWND, lpOperation: ?[*:0]const u16, lpFile: [*:0]const u16, lpParameters: ?[*:0]const u16, lpDirectory: ?[*:0]const u16, nShowCmd: i32) callconv(.winapi) ?HINSTANCE;
pub extern "dwmapi" fn DwmGetWindowAttribute(hwnd: HWND, dwAttribute: u32, pvAttribute: *anyopaque, cbAttribute: u32) callconv(.winapi) c_int;
pub extern "dwmapi" fn DwmSetWindowAttribute(hwnd: HWND, dwAttribute: u32, pvAttribute: *const anyopaque, cbAttribute: u32) callconv(.winapi) c_int;

pub const WM_NULL: u32 = 0x0000;
pub const WM_CLOSE: u32 = 0x0010;
pub const WH_KEYBOARD_LL: i32 = 13;
pub const WH_MOUSE_LL: i32 = 14;
pub const WM_KEYDOWN: u32 = 0x0100;
pub const WM_KEYUP: u32 = 0x0101;
pub const WM_SYSKEYDOWN: u32 = 0x0104;
pub const WM_SYSKEYUP: u32 = 0x0105;
pub const WM_MOUSEMOVE: u32 = 0x0200;
pub const WM_LBUTTONDOWN: u32 = 0x0201;
pub const WM_LBUTTONUP: u32 = 0x0202;
pub const WM_LBUTTONDBLCLK: u32 = 0x0203;
pub const WM_RBUTTONDOWN: u32 = 0x0204;
pub const WM_RBUTTONUP: u32 = 0x0205;
pub const WM_MBUTTONDOWN: u32 = 0x0207;
pub const WM_MBUTTONUP: u32 = 0x0208;
pub const WM_MOUSEWHEEL: u32 = 0x020A;
pub const WM_USER: u32 = 0x0400;
pub const WM_TRAY: u32 = WM_USER + 1;
pub const WM_APP_EVENT: u32 = WM_USER + 2;
pub const WM_APP_INTENT: u32 = WM_USER + 3;
/// Win32 MAX_PATH (including the terminating NUL).
pub const MAX_PATH: usize = 260;
pub const WM_COMMAND: u32 = 0x0111;
pub const WM_SYSCOMMAND: u32 = 0x0112;
pub const WM_CONTEXTMENU: u32 = 0x007B;

pub const VK_CONTROL: u16 = 0x11;
pub const VK_MENU: u32 = 0x12;
pub const VK_LMENU: u32 = 0xA4;
pub const VK_RMENU: u32 = 0xA5;
pub const VK_MENU_I32: i32 = 0x12;

pub const GA_ROOT: u32 = 2;
pub const GA_ROOTOWNER: u32 = 3;
pub const GWL_STYLE: i32 = -16;
pub const GWL_EXSTYLE: i32 = -20;
pub const WS_CHILD: isize = 0x40000000;
pub const WS_CAPTION: isize = 0x00C00000;
pub const WS_EX_TOOLWINDOW: isize = 0x00000080;
pub const WS_EX_APPWINDOW: isize = 0x00040000;
pub const WS_EX_TOPMOST: isize = 0x00000008;
pub const WS_EX_LAYERED: isize = 0x00080000;
pub const LWA_ALPHA: u32 = 0x00000002;

pub const SWP_NOSIZE: u32 = 0x0001;
pub const SWP_NOMOVE: u32 = 0x0002;
pub const SWP_NOZORDER: u32 = 0x0004;
pub const SWP_NOACTIVATE: u32 = 0x0010;
pub const SWP_FRAMECHANGED: u32 = 0x0020;
pub const SWP_NOCOPYBITS: u32 = 0x0100;
pub const SWP_NOOWNERZORDER: u32 = 0x0200;
pub const SW_MINIMIZE: i32 = 6;
pub const SW_RESTORE: i32 = 9;

pub const MONITOR_DEFAULTTONEAREST: u32 = 2;
pub const WINEVENT_OUTOFCONTEXT: u32 = 0x0002;

pub const EVENT_SYSTEM_FOREGROUND: u32 = 0x0003;
pub const EVENT_SYSTEM_MINIMIZESTART: u32 = 0x0016;
pub const EVENT_SYSTEM_MINIMIZEEND: u32 = 0x0017;
pub const EVENT_OBJECT_DESTROY: u32 = 0x8001;
pub const EVENT_OBJECT_SHOW: u32 = 0x8002;
pub const EVENT_OBJECT_HIDE: u32 = 0x8003;
pub const OBJID_WINDOW: i32 = 0;

pub const WM_TIMER: u32 = 0x0113;
pub const DWMWA_EXTENDED_FRAME_BOUNDS: u32 = 9;
pub const DWMWA_BORDER_COLOR: u32 = 34;

pub const HWND_TOPMOST: HWND = @ptrFromInt(@as(usize, @bitCast(@as(isize, -1))));
pub const HWND_NOTOPMOST: HWND = @ptrFromInt(@as(usize, @bitCast(@as(isize, -2))));

pub const NIM_ADD: u32 = 0x00000000;
pub const NIM_MODIFY: u32 = 0x00000001;
pub const NIM_DELETE: u32 = 0x00000002;
pub const NIM_SETVERSION: u32 = 0x00000004;
pub const NIF_MESSAGE: u32 = 0x00000001;
pub const NIF_ICON: u32 = 0x00000002;
pub const NIF_TIP: u32 = 0x00000004;
pub const NIF_INFO: u32 = 0x00000010;
pub const MF_STRING: u32 = 0x00000000;
pub const MF_SEPARATOR: u32 = 0x00000800;
pub const MF_CHECKED: u32 = 0x00000008;
pub const MF_UNCHECKED: u32 = 0x00000000;
pub const TPM_RIGHTBUTTON: u32 = 0x0002;
pub const ERROR_ALREADY_EXISTS: u32 = 183;

pub const GENERIC_READ: u32 = 0x80000000;
pub const GENERIC_WRITE: u32 = 0x40000000;
pub const FILE_SHARE_READ: u32 = 0x00000001;
pub const FILE_SHARE_WRITE: u32 = 0x00000002;
pub const FILE_SHARE_DELETE: u32 = 0x00000004;
pub const OPEN_ALWAYS: u32 = 4;
pub const OPEN_EXISTING: u32 = 3;
pub const CREATE_ALWAYS: u32 = 2;
pub const FILE_ATTRIBUTE_NORMAL: u32 = 0x00000080;
pub const FILE_APPEND_DATA: u32 = 0x00000004;
pub const FILE_FLAG_BACKUP_SEMANTICS: u32 = 0x02000000;
pub const FILE_FLAG_OVERLAPPED: u32 = 0x40000000;
pub const FILE_NOTIFY_CHANGE_FILE_NAME: u32 = 0x00000001;
pub const FILE_NOTIFY_CHANGE_LAST_WRITE: u32 = 0x00000010;
