const std = @import("std");
const t = @import("../platform/win32.zig");
const geom = @import("../calc/geometry.zig");
const UserIntent = @import("../domain/intent.zig").UserIntent;
const WindowTarget = @import("../domain/window_target.zig").WindowTarget;
const Window = @import("../platform/window.zig").Window;
const logger = @import("../infra/logger.zig");
const GestureStateMachine = @import("gesture.zig").GestureStateMachine;
const Config = @import("../domain/config.zig").Config;

pub const AltProtocolState = enum {
    idle,
    alt_held_passthrough,
    alt_held_consumed,
};

// Intent ring capacity; hooks enqueue, the main message pump drains.
const intent_cap = 8;

/// Low-level hook driver and Alt input-protocol state machine.
///
/// State transition invariants:
/// 1. neutralizeMenuState() runs on Alt release if and only if
///    alt_state == .alt_held_consumed.
/// 2. middle_pending is force-reset on every Alt release.
/// 3. While paused, all hook events pass straight through untouched.
///
/// Hooks never perform Win32 window probing or heavy work: they classify
/// input into a UserIntent and wake the main thread via WM_APP_INTENT.
pub const InputEngine = struct {
    kb_hook: ?t.HHOOK = null,
    mouse_hook: ?t.HHOOK = null,
    gesture: *GestureStateMachine,
    config: *const Config,
    paused: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    alt_state: AltProtocolState = .idle,
    middle_pending: bool = false,

    notify_hwnd: t.HWND = undefined,

    lock: t.SRWLOCK = .{},
    intents: [intent_cap]UserIntent = undefined,
    intent_head: usize = 0,
    intent_len: usize = 0,

    pub var global: ?*InputEngine = null;

    pub fn init(gesture: *GestureStateMachine, config: *const Config) InputEngine {
        return .{
            .gesture = gesture,
            .config = config,
        };
    }

    pub fn install(self: *InputEngine, hinst: ?t.HINSTANCE, notify_hwnd: t.HWND) !void {
        self.notify_hwnd = notify_hwnd;
        InputEngine.global = self;
        errdefer self.uninstall();
        self.kb_hook = t.SetWindowsHookExW(t.WH_KEYBOARD_LL, keyboardCallback, hinst, 0) orelse return error.KbHookFailed;
        self.mouse_hook = t.SetWindowsHookExW(t.WH_MOUSE_LL, mouseCallback, hinst, 0) orelse return error.MouseHookFailed;
        logger.info("Hook", "low-level hooks installed", .{});
    }

    pub fn uninstall(self: *InputEngine) void {
        if (self.kb_hook) |kh| _ = t.UnhookWindowsHookEx(kh);
        if (self.mouse_hook) |mh| _ = t.UnhookWindowsHookEx(mh);
        self.kb_hook = null;
        self.mouse_hook = null;
        InputEngine.global = null;
    }

    pub fn isAltDown(self: *InputEngine) bool {
        return self.alt_state != .idle or (@as(u16, @bitCast(t.GetAsyncKeyState(t.VK_MENU_I32))) & 0x8000) != 0;
    }

    fn neutralizeMenuState() void {
        const KEYEVENTF_KEYUP: u16 = 0x0002;
        const INPUT_KEYBOARD: u32 = 1;
        const inputs = [_]t.INPUT{
            .{ .type = INPUT_KEYBOARD, .unnamed = .{ .ki = .{ .wVk = t.VK_CONTROL, .wScan = 0, .dwFlags = 0, .time = 0, .dwExtraInfo = 0 } } },
            .{ .type = INPUT_KEYBOARD, .unnamed = .{ .ki = .{ .wVk = t.VK_CONTROL, .wScan = 0, .dwFlags = KEYEVENTF_KEYUP, .time = 0, .dwExtraInfo = 0 } } },
        };
        _ = t.SendInput(2, &inputs, @sizeOf(t.INPUT));
    }

    /// Called from hook threads. Never blocks on I/O; drops with a warn
    /// when the ring is full (main thread stalled longer than 8 intents).
    fn enqueueIntent(self: *InputEngine, intent: UserIntent) void {
        var full = false;
        t.AcquireSRWLockExclusive(&self.lock);
        if (self.intent_len < intent_cap) {
            self.intents[(self.intent_head + self.intent_len) % intent_cap] = intent;
            self.intent_len += 1;
        } else {
            full = true;
        }
        t.ReleaseSRWLockExclusive(&self.lock);
        _ = t.PostMessageW(self.notify_hwnd, t.WM_APP_INTENT, 0, 0);
        if (full) logger.warn("Hook", "intent queue full, dropped intent", .{});
    }

    /// Pop one pending intent; called from the main thread only.
    pub fn nextIntent(self: *InputEngine) ?UserIntent {
        t.AcquireSRWLockExclusive(&self.lock);
        defer t.ReleaseSRWLockExclusive(&self.lock);
        if (self.intent_len == 0) return null;
        const intent = self.intents[self.intent_head];
        self.intent_head = (self.intent_head + 1) % intent_cap;
        self.intent_len -= 1;
        return intent;
    }
};

fn keyboardCallback(nCode: i32, wParam: t.WPARAM, lParam: t.LPARAM) callconv(.winapi) t.LRESULT {
    if (nCode != 0) return t.CallNextHookEx(null, nCode, wParam, lParam);
    const self = InputEngine.global orelse return t.CallNextHookEx(null, nCode, wParam, lParam);
    if (self.paused.load(.acquire)) return t.CallNextHookEx(null, nCode, wParam, lParam);

    const kbd: *const t.KBDLLHOOKSTRUCT = @ptrFromInt(@as(usize, @bitCast(lParam)));
    const is_down = (wParam == t.WM_KEYDOWN or wParam == t.WM_SYSKEYDOWN);
    const is_up = (wParam == t.WM_KEYUP or wParam == t.WM_SYSKEYUP);

    if (kbd.vkCode == t.VK_MENU or kbd.vkCode == t.VK_LMENU or kbd.vkCode == t.VK_RMENU) {
        if (is_down) {
            // Key-repeat fires extra downs; never downgrade consumed state.
            if (self.alt_state == .idle) self.alt_state = .alt_held_passthrough;
        } else if (is_up) {
            const was_consumed = self.alt_state == .alt_held_consumed;
            self.alt_state = .idle;
            self.middle_pending = false;
            if (was_consumed) InputEngine.neutralizeMenuState();
        }
        return t.CallNextHookEx(null, nCode, wParam, lParam);
    }

    if (self.isAltDown() and is_down) {
        if (kbd.vkCode == self.config.key_center) {
            self.alt_state = .alt_held_consumed;
            self.enqueueIntent(.center_active_window);
            return 1;
        } else if (kbd.vkCode == self.config.key_topmost) {
            self.alt_state = .alt_held_consumed;
            self.enqueueIntent(.toggle_active_topmost);
            return 1;
        } else if (kbd.vkCode == self.config.key_close) {
            self.alt_state = .alt_held_consumed;
            self.enqueueIntent(.close_active_window);
            return 1;
        }
    }

    return t.CallNextHookEx(null, nCode, wParam, lParam);
}

fn mouseCallback(nCode: i32, wParam: t.WPARAM, lParam: t.LPARAM) callconv(.winapi) t.LRESULT {
    if (nCode != 0) return t.CallNextHookEx(null, nCode, wParam, lParam);
    const self = InputEngine.global orelse return t.CallNextHookEx(null, nCode, wParam, lParam);
    const mouse: *const t.MSLLHOOKSTRUCT = @ptrFromInt(@as(usize, @bitCast(lParam)));
    const pt: geom.Point = .{ .x = mouse.pt.x, .y = mouse.pt.y };

    if (self.isAltDown() and !self.paused.load(.acquire)) {
        switch (wParam) {
            t.WM_LBUTTONDOWN => {
                // The gesture state machine must start synchronously with the
                // physical button press: an async intent can be overtaken by
                // this click's own WM_LBUTTONUP (main thread not scheduled
                // yet), starting a drag with the button already up — a stuck
                // ghost-drag. Probing here stays cheap (<30us) and, as a side
                // effect, clicks on non-actionable surfaces pass through.
                if (actionableWindowAt(mouse.pt)) |win| {
                    win.ensureRestored();
                    _ = t.SetForegroundWindow(win.hwnd);
                    const target = WindowTarget{
                        .hwnd = win.hwnd,
                        .session_id = self.gesture.worker.invalidateSession(),
                    };
                    self.alt_state = .alt_held_consumed;
                    self.gesture.startDrag(target, pt, win.getPhysicalBounds(), win.getShadowPadding());
                    return 1;
                }
            },
            t.WM_RBUTTONDOWN => {
                if (actionableWindowAt(mouse.pt)) |win| {
                    win.ensureRestored();
                    _ = t.SetForegroundWindow(win.hwnd);
                    const target = WindowTarget{
                        .hwnd = win.hwnd,
                        .session_id = self.gesture.worker.invalidateSession(),
                    };
                    const bounds = win.getPhysicalBounds();
                    const pad = win.getShadowPadding();
                    const sector = geom.calculateSector(bounds.width(), bounds.height(), pt.x - bounds.left, pt.y - bounds.top);
                    self.alt_state = .alt_held_consumed;
                    self.gesture.startResize(target, pt, bounds, sector, pad);
                    return 1;
                }
            },
            t.WM_MBUTTONDOWN => {
                self.alt_state = .alt_held_consumed;
                self.middle_pending = true;
                self.enqueueIntent(.{ .minimize_at = .{ .pt = pt } });
                return 1;
            },
            t.WM_MOUSEWHEEL => {
                if (self.config.enable_wheel_opacity) {
                    const delta_raw: i16 = @bitCast(@as(u16, @intCast((mouse.mouseData >> 16) & 0xFFFF)));
                    const step: i32 = @intCast(self.config.opacity_step);
                    const change: i32 = if (delta_raw > 0) step else -step;
                    self.alt_state = .alt_held_consumed;
                    self.enqueueIntent(.{ .adjust_opacity_at = .{ .pt = pt, .delta = change } });
                    return 1;
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

fn actionableWindowAt(pt: t.POINT) ?Window {
    const raw_hwnd = t.WindowFromPoint(pt) orelse return null;
    const top = Window.getTrueTopLevel(raw_hwnd) orelse return null;
    const win = Window.init(top);
    if (win.isExclusiveFullScreen()) return null;
    return win;
}
