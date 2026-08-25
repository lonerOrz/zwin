const std = @import("std");
const t = @import("../platform/win32.zig");
const geom = @import("../calc/geometry.zig");
const Window = @import("../platform/window.zig").Window;
const logger = @import("../infra/logger.zig");
const GestureStateMachine = @import("gesture.zig").GestureStateMachine;
const Config = @import("../domain/config.zig").Config;

pub const HookDispatcher = struct {
    kb_hook: ?t.HHOOK = null,
    mouse_hook: ?t.HHOOK = null,
    gesture: *GestureStateMachine,
    config: *const Config,
    paused: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    alt_pressed: bool = false,
    consumed_by_action: bool = false,
    middle_pending: bool = false,

    pub var global: ?*HookDispatcher = null;

    pub fn init(gesture: *GestureStateMachine, config: *const Config) HookDispatcher {
        return .{
            .gesture = gesture,
            .config = config,
        };
    }

    pub fn install(self: *HookDispatcher, hinst: ?t.HINSTANCE) !void {
        HookDispatcher.global = self;
        errdefer self.uninstall();
        self.kb_hook = t.SetWindowsHookExW(t.WH_KEYBOARD_LL, keyboardCallback, hinst, 0) orelse return error.KbHookFailed;
        self.mouse_hook = t.SetWindowsHookExW(t.WH_MOUSE_LL, mouseCallback, hinst, 0) orelse return error.MouseHookFailed;
        logger.info("Hook", "low-level hooks installed", .{});
    }

    pub fn uninstall(self: *HookDispatcher) void {
        if (self.kb_hook) |kh| _ = t.UnhookWindowsHookEx(kh);
        if (self.mouse_hook) |mh| _ = t.UnhookWindowsHookEx(mh);
        self.kb_hook = null;
        self.mouse_hook = null;
        HookDispatcher.global = null;
    }

    pub fn isAltDown(self: *HookDispatcher) bool {
        return self.alt_pressed or (@as(u16, @bitCast(t.GetAsyncKeyState(t.VK_MENU_I32))) & 0x8000) != 0;
    }

    pub fn neutralizeMenuState() void {
        const KEYEVENTF_KEYUP: u16 = 0x0002;
        const INPUT_KEYBOARD: u32 = 1;
        const inputs = [_]t.INPUT{
            .{ .type = INPUT_KEYBOARD, .unnamed = .{ .ki = .{ .wVk = t.VK_CONTROL, .wScan = 0, .dwFlags = 0, .time = 0, .dwExtraInfo = 0 } } },
            .{ .type = INPUT_KEYBOARD, .unnamed = .{ .ki = .{ .wVk = t.VK_CONTROL, .wScan = 0, .dwFlags = KEYEVENTF_KEYUP, .time = 0, .dwExtraInfo = 0 } } },
        };
        _ = t.SendInput(2, &inputs, @sizeOf(t.INPUT));
    }
};

fn keyboardCallback(nCode: i32, wParam: t.WPARAM, lParam: t.LPARAM) callconv(.winapi) t.LRESULT {
    if (nCode != 0) return t.CallNextHookEx(null, nCode, wParam, lParam);
    const self = HookDispatcher.global orelse return t.CallNextHookEx(null, nCode, wParam, lParam);
    if (self.paused.load(.acquire)) return t.CallNextHookEx(null, nCode, wParam, lParam);

    const kbd: *const t.KBDLLHOOKSTRUCT = @ptrFromInt(@as(usize, @bitCast(lParam)));
    const is_down = (wParam == t.WM_KEYDOWN or wParam == t.WM_SYSKEYDOWN);
    const is_up = (wParam == t.WM_KEYUP or wParam == t.WM_SYSKEYUP);

    if (kbd.vkCode == t.VK_MENU or kbd.vkCode == t.VK_LMENU or kbd.vkCode == t.VK_RMENU) {
        if (is_down) {
            self.alt_pressed = true;
        } else if (is_up) {
            self.alt_pressed = false;
            if (self.consumed_by_action) {
                HookDispatcher.neutralizeMenuState();
                self.consumed_by_action = false;
            }
        }
    }

    if (self.isAltDown() and is_down) {
        const raw_fg = t.GetForegroundWindow();
        if (raw_fg) |h| {
            const target = Window.getTrueTopLevel(h) orelse return t.CallNextHookEx(null, nCode, wParam, lParam);
            const win = Window.init(target);
            if (win.isExclusiveFullScreen()) {
                return t.CallNextHookEx(null, nCode, wParam, lParam);
            }

            if (kbd.vkCode == self.config.key_center) {
                win.ensureRestored();
                if (win.getMonitorWorkArea()) |wa| {
                    const bounds = win.getPhysicalBounds();
                    const pad = win.getShadowPadding();
                    const centered = geom.calculateCenterRect(wa, bounds, pad);
                    self.gesture.worker.post(.{
                        .hwnd = target,
                        .x = centered.left,
                        .y = centered.top,
                        .w = centered.width(),
                        .h = centered.height(),
                        .flags = t.SWP_NOACTIVATE | t.SWP_NOZORDER,
                    });
                }
                self.consumed_by_action = true;
                return 1;
            } else if (kbd.vkCode == self.config.key_topmost) {
                const ex_style = t.GetWindowLongPtrW(target, t.GWL_EXSTYLE);
                const is_topmost = (ex_style & t.WS_EX_TOPMOST) != 0;
                self.gesture.worker.post(.{
                    .hwnd = target,
                    .x = 0,
                    .y = 0,
                    .w = 0,
                    .h = 0,
                    .insert_after = if (is_topmost) t.HWND_NOTOPMOST else t.HWND_TOPMOST,
                    .flags = t.SWP_NOMOVE | t.SWP_NOSIZE | t.SWP_NOACTIVATE,
                });
                self.consumed_by_action = true;
                return 1;
            } else if (kbd.vkCode == self.config.key_close) {
                win.close();
                self.consumed_by_action = true;
                return 1;
            }
        }
    }

    return t.CallNextHookEx(null, nCode, wParam, lParam);
}

fn actionableWindowAt(pt: t.POINT) ?Window {
    const raw_hwnd = t.WindowFromPoint(pt) orelse return null;
    const top = Window.getTrueTopLevel(raw_hwnd) orelse return null;
    const win = Window.init(top);
    if (win.isExclusiveFullScreen()) return null;
    return win;
}

fn mouseCallback(nCode: i32, wParam: t.WPARAM, lParam: t.LPARAM) callconv(.winapi) t.LRESULT {
    if (nCode != 0) return t.CallNextHookEx(null, nCode, wParam, lParam);
    const self = HookDispatcher.global orelse return t.CallNextHookEx(null, nCode, wParam, lParam);
    const mouse: *const t.MSLLHOOKSTRUCT = @ptrFromInt(@as(usize, @bitCast(lParam)));
    const pt: geom.Point = .{ .x = mouse.pt.x, .y = mouse.pt.y };

    if (self.isAltDown() and !self.paused.load(.acquire)) {
        switch (wParam) {
            t.WM_LBUTTONDOWN => {
                if (actionableWindowAt(mouse.pt)) |win| {
                    win.ensureRestored();
                    _ = t.SetForegroundWindow(win.hwnd);
                    self.gesture.startDrag(win.hwnd, pt, win.getPhysicalBounds());
                    self.consumed_by_action = true;
                    return 1;
                }
            },
            t.WM_RBUTTONDOWN => {
                if (actionableWindowAt(mouse.pt)) |win| {
                    win.ensureRestored();
                    _ = t.SetForegroundWindow(win.hwnd);
                    const bounds = win.getPhysicalBounds();
                    const pad = win.getShadowPadding();
                    const sector = geom.calculateSector(bounds.width(), bounds.height(), pt.x - bounds.left, pt.y - bounds.top);
                    self.gesture.startResize(win.hwnd, pt, bounds, sector, pad);
                    self.consumed_by_action = true;
                    return 1;
                }
            },
            t.WM_MBUTTONDOWN => {
                if (actionableWindowAt(mouse.pt)) |win| {
                    win.minimize();
                    self.consumed_by_action = true;
                    self.middle_pending = true;
                    return 1;
                }
            },
            t.WM_MOUSEWHEEL => {
                if (self.config.enable_wheel_opacity) {
                    if (actionableWindowAt(mouse.pt)) |win| {
                        const delta_raw: i16 = @bitCast(@as(u16, @intCast((mouse.mouseData >> 16) & 0xFFFF)));
                        const step: i32 = @intCast(self.config.opacity_step);
                        const change: i32 = if (delta_raw > 0) step else -step;
                        win.adjustOpacity(change);
                        self.consumed_by_action = true;
                        return 1;
                    }
                }
            },
            else => {},
        }
    }

    if (wParam == t.WM_MOUSEMOVE and self.gesture.isBusy()) {
        self.gesture.updateMouseMove(pt);
    }

    if ((wParam == t.WM_LBUTTONUP or wParam == t.WM_RBUTTONUP) and self.gesture.isBusy()) {
        self.gesture.finish();
        return 1;
    }

    if (wParam == t.WM_MBUTTONUP and self.middle_pending) {
        self.middle_pending = false;
        return 1;
    }

    return t.CallNextHookEx(null, nCode, wParam, lParam);
}
