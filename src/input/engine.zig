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

const intent_cap: usize = 16;
const intent_mask: usize = intent_cap - 1;

pub const MouseButton = enum { left, right };

const PendingAction = struct {
    kind: enum { drag, resize },
    pt: geom.Point,
    win: Window,
    button: MouseButton,
};

// Low-level hook driver and Alt input-protocol state machine
pub const InputEngine = struct {
    kb_hook: ?t.HHOOK = null,
    mouse_hook: ?t.HHOOK = null,
    gesture: *GestureStateMachine,
    config: *const Config,
    paused: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    alt_state: AltProtocolState = .idle,
    middle_pending: bool = false,
    pending_action: ?PendingAction = null,

    notify_hwnd: t.HWND = undefined,
    hinst: ?t.HINSTANCE = null,

    // Watchdog timestamp updated on every mouse move
    last_hook_mouse_ms: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    head: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    tail: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    intents: [intent_cap]UserIntent = undefined,

    dropped_count: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

    drag_threshold: i32 = 4,

    pub var global: ?*InputEngine = null;

    pub fn init(gesture: *GestureStateMachine, config: *const Config) InputEngine {
        var drag_th = t.GetSystemMetrics(t.SM_CXDRAG);
        if (drag_th <= 0) drag_th = 4;

        return .{
            .gesture = gesture,
            .config = config,
            .drag_threshold = drag_th,
        };
    }

    pub fn install(self: *InputEngine, hinst: ?t.HINSTANCE, notify_hwnd: t.HWND) !void {
        self.notify_hwnd = notify_hwnd;
        self.hinst = hinst;
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

    // Reinstall low-level hooks on watchdog recovery
    pub fn reinstall(self: *InputEngine) void {
        if (self.kb_hook) |kh| _ = t.UnhookWindowsHookEx(kh);
        if (self.mouse_hook) |mh| _ = t.UnhookWindowsHookEx(mh);
        self.kb_hook = t.SetWindowsHookExW(t.WH_KEYBOARD_LL, keyboardCallback, self.hinst, 0);
        self.mouse_hook = t.SetWindowsHookExW(t.WH_MOUSE_LL, mouseCallback, self.hinst, 0);
        if (self.kb_hook == null or self.mouse_hook == null) {
            logger.err("Hook", "watchdog reinstall failed", .{});
        } else {
            logger.info("Hook", "low-level hooks reinstalled", .{});
        }
    }

    pub fn isAltDown(self: *InputEngine) bool {
        return self.alt_state != .idle or (@as(u16, @bitCast(t.GetAsyncKeyState(t.VK_MENU_I32))) & 0x8000) != 0;
    }

    // Send dummy Ctrl keypress with ZWIN tag to prevent Windows menu activation on Alt release
    fn neutralizeMenuState() void {
        const KEYEVENTF_KEYUP: u16 = 0x0002;
        const INPUT_KEYBOARD: u32 = 1;
        const inputs = [_]t.INPUT{
            .{ .type = INPUT_KEYBOARD, .unnamed = .{ .ki = .{ .wVk = t.VK_CONTROL, .wScan = 0, .dwFlags = 0, .time = 0, .dwExtraInfo = t.ZWIN_INJECTED_TAG } } },
            .{ .type = INPUT_KEYBOARD, .unnamed = .{ .ki = .{ .wVk = t.VK_CONTROL, .wScan = 0, .dwFlags = KEYEVENTF_KEYUP, .time = 0, .dwExtraInfo = t.ZWIN_INJECTED_TAG } } },
        };
        _ = t.SendInput(2, &inputs, @sizeOf(t.INPUT));
    }

    // Forward the original mouse click through SendInput so the target app sees it
    pub fn forwardOriginalClick(button: MouseButton) void {
        const INPUT_MOUSE: u32 = 0;
        const MOUSEEVENTF_LEFTDOWN: u32 = 0x0002;
        const MOUSEEVENTF_LEFTUP: u32 = 0x0004;
        const MOUSEEVENTF_RIGHTDOWN: u32 = 0x0008;
        const MOUSEEVENTF_RIGHTUP: u32 = 0x0010;

        const down_flag = if (button == .left) MOUSEEVENTF_LEFTDOWN else MOUSEEVENTF_RIGHTDOWN;
        const up_flag = if (button == .left) MOUSEEVENTF_LEFTUP else MOUSEEVENTF_RIGHTUP;

        const inputs = [_]t.INPUT{
            .{ .type = INPUT_MOUSE, .unnamed = .{ .mi = .{ .dx = 0, .dy = 0, .mouseData = 0, .dwFlags = down_flag, .time = 0, .dwExtraInfo = t.ZWIN_INJECTED_TAG } } },
            .{ .type = INPUT_MOUSE, .unnamed = .{ .mi = .{ .dx = 0, .dy = 0, .mouseData = 0, .dwFlags = up_flag, .time = 0, .dwExtraInfo = t.ZWIN_INJECTED_TAG } } },
        };
        _ = t.SendInput(2, &inputs, @sizeOf(t.INPUT));
    }

    fn enqueueIntent(self: *InputEngine, intent: UserIntent) void {
        const current_tail = self.tail.load(.unordered);
        const next_tail = (current_tail + 1) & intent_mask;

        const current_head = self.head.load(.acquire);
        if (next_tail == current_head) {
            _ = self.dropped_count.fetchAdd(1, .monotonic);
            return;
        }

        self.intents[current_tail] = intent;
        self.tail.store(next_tail, .release);
        _ = t.PostMessageW(self.notify_hwnd, t.WM_APP_INTENT, 0, 0);
    }

    pub fn nextIntent(self: *InputEngine) ?UserIntent {
        const current_tail = self.tail.load(.acquire);
        const current_head = self.head.load(.unordered);

        if (current_head == current_tail) {
            return null;
        }

        const intent = self.intents[current_head];
        const next_head = (current_head + 1) & intent_mask;
        self.head.store(next_head, .release);
        return intent;
    }

    pub fn reportDroppedIntents(self: *InputEngine) void {
        const count = self.dropped_count.swap(0, .monotonic);
        if (count > 0) {
            logger.warn("Hook", "dropped {d} intents due to full lock-free queue", .{count});
        }
    }
};

fn keyboardCallback(nCode: i32, wParam: t.WPARAM, lParam: t.LPARAM) callconv(.winapi) t.LRESULT {
    if (nCode != 0) return t.CallNextHookEx(null, nCode, wParam, lParam);
    const self = InputEngine.global orelse return t.CallNextHookEx(null, nCode, wParam, lParam);
    if (self.paused.load(.acquire)) return t.CallNextHookEx(null, nCode, wParam, lParam);

    const kbd: *const t.KBDLLHOOKSTRUCT = @ptrFromInt(@as(usize, @bitCast(lParam)));

    if (kbd.dwExtraInfo == t.ZWIN_INJECTED_TAG) {
        return t.CallNextHookEx(null, nCode, wParam, lParam);
    }

    const is_down = (wParam == t.WM_KEYDOWN or wParam == t.WM_SYSKEYDOWN);
    const is_up = (wParam == t.WM_KEYUP or wParam == t.WM_SYSKEYUP);

    if (kbd.vkCode == t.VK_MENU or kbd.vkCode == t.VK_LMENU or kbd.vkCode == t.VK_RMENU) {
        if (is_down) {
            if (self.alt_state == .idle) self.alt_state = .alt_held_passthrough;
        } else if (is_up) {
            const was_consumed = self.alt_state == .alt_held_consumed;
            self.alt_state = .idle;
            self.middle_pending = false;
            if (was_consumed) InputEngine.neutralizeMenuState();
        }
        return t.CallNextHookEx(null, nCode, wParam, lParam);
    }

    // Abort active gesture on ESC
    if (is_down and kbd.vkCode == t.VK_ESCAPE and (self.gesture.isBusy() or self.pending_action != null)) {
        self.pending_action = null;
        self.enqueueIntent(.abort_gesture);
        return 1;
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

    if (mouse.dwExtraInfo == t.ZWIN_INJECTED_TAG) {
        return t.CallNextHookEx(null, nCode, wParam, lParam);
    }

    if (wParam == t.WM_MOUSEMOVE) {
        self.last_hook_mouse_ms.store(t.GetTickCount64(), .release);
    }

    if (self.isAltDown() and !self.paused.load(.acquire)) {
        switch (wParam) {
            t.WM_LBUTTONDOWN => {
                if (actionableWindowAt(mouse.pt)) |win| {
                    self.pending_action = .{
                        .kind = .drag,
                        .pt = pt,
                        .win = win,
                        .button = .left,
                    };
                    return 1;
                }
            },
            t.WM_RBUTTONDOWN => {
                if (actionableWindowAt(mouse.pt)) |win| {
                    self.pending_action = .{
                        .kind = .resize,
                        .pt = pt,
                        .win = win,
                        .button = .right,
                    };
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

    if (wParam == t.WM_MOUSEMOVE) {
        if (self.pending_action) |pa| {
            const dx = @abs(pt.x - pa.pt.x);
            const dy = @abs(pt.y - pa.pt.y);
            if (dx >= self.drag_threshold or dy >= self.drag_threshold) {
                if (t.IsWindow(pa.win.hwnd) == 0) {
                    self.pending_action = null;
                    return t.CallNextHookEx(null, nCode, wParam, lParam);
                }
                pa.win.ensureRestored();
                _ = t.SetForegroundWindow(pa.win.hwnd);
                const target = WindowTarget{
                    .hwnd = pa.win.hwnd,
                    .session_id = self.gesture.worker.invalidateSession(),
                };
                self.alt_state = .alt_held_consumed;

                if (pa.kind == .drag) {
                    self.gesture.startDrag(target, pa.pt, pa.win.getPhysicalBounds(), pa.win.getShadowPadding());
                } else {
                    const bounds = pa.win.getPhysicalBounds();
                    const pad = pa.win.getShadowPadding();
                    const sector = geom.calculateSector(bounds.width(), bounds.height(), pa.pt.x - bounds.left, pa.pt.y - bounds.top);
                    self.gesture.startResize(target, pa.pt, bounds, sector, pad);
                }
                self.pending_action = null;
            }
        }

        if (self.gesture.isBusy()) {
            self.gesture.updateMouseMove(pt);
        }
    }

    if (wParam == t.WM_LBUTTONUP or wParam == t.WM_RBUTTONUP) {
        if (self.pending_action) |pa| {
            self.pending_action = null;
            InputEngine.forwardOriginalClick(pa.button);
            return 1;
        }

        if (self.gesture.isBusy()) {
            self.gesture.finish();
            return 1;
        }
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
