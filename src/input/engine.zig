const std = @import("std");
const t = @import("../platform/win32.zig");
const geom = @import("../calc/geometry.zig");
const types = @import("../domain/types.zig");
const UserIntent = types.UserIntent;
const WindowTarget = types.WindowTarget;
const Action = types.Action;
const MouseTrigger = types.MouseTrigger;
const ModifierMask = types.ModifierMask;
const Window = @import("../platform/window.zig").Window;
const logger = @import("../infra/logger.zig");
const GestureStateMachine = @import("gesture.zig").GestureStateMachine;
const IntentHandler = @import("../wm/intent_handler.zig").IntentHandler;
const Config = @import("../domain/config.zig").Config;

const intent_cap: usize = 16;
const intent_mask: usize = intent_cap - 1;

pub const InputEngine = struct {
    kb_hook: ?t.HHOOK = null,
    mouse_hook: ?t.HHOOK = null,
    gesture: *GestureStateMachine,
    config: *const Config,
    intent_handler: *IntentHandler,
    paused: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    consumed_alt: bool = false,
    consumed_win: bool = false,
    consumed_mbutton: bool = false,

    pending_mouse_action: ?struct {
        action: Action,
        pt: geom.Point,
        win: Window,
    } = null,

    notify_hwnd: t.HWND = undefined,
    hinst: ?t.HINSTANCE = null,

    last_hook_mouse_ms: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    head: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    tail: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    intents: [intent_cap]UserIntent = undefined,
    dropped_count: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    drag_threshold: i32 = 4,

    pub var global: ?*InputEngine = null;

    pub fn init(gesture: *GestureStateMachine, config: *const Config, intent_handler: *IntentHandler) InputEngine {
        var drag_th = t.GetSystemMetrics(t.SM_CXDRAG);
        if (drag_th <= 0) drag_th = 4;
        return .{
            .gesture = gesture,
            .config = config,
            .intent_handler = intent_handler,
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

    pub fn reinstall(self: *InputEngine) void {
        self.uninstall();
        self.install(self.hinst, self.notify_hwnd) catch {
            logger.err("Hook", "watchdog hook reinstallation failed", .{});
        };
    }

    pub fn sampleModifiers() ModifierMask {
        var mask = ModifierMask{};
        if ((@as(u16, @bitCast(t.GetAsyncKeyState(t.VK_MENU_I32))) & 0x8000) != 0) mask.alt = true;
        if ((@as(u16, @bitCast(t.GetAsyncKeyState(t.VK_CONTROL_I32))) & 0x8000) != 0) mask.ctrl = true;
        if ((@as(u16, @bitCast(t.GetAsyncKeyState(t.VK_SHIFT_I32))) & 0x8000) != 0) mask.shift = true;
        if ((@as(u16, @bitCast(t.GetAsyncKeyState(t.VK_LWIN))) & 0x8000) != 0 or
            (@as(u16, @bitCast(t.GetAsyncKeyState(t.VK_RWIN))) & 0x8000) != 0)
        {
            mask.win = true;
        }
        return mask;
    }

    pub fn neutralizeSystemMenu() void {
        const KEYEVENTF_KEYUP: u16 = 0x0002;
        const INPUT_KEYBOARD: u32 = 1;
        const inputs = [_]t.INPUT{
            .{ .type = INPUT_KEYBOARD, .unnamed = .{ .ki = .{ .wVk = t.VK_CONTROL, .wScan = 0, .dwFlags = 0, .time = 0, .dwExtraInfo = t.ZWIN_INJECTED_TAG } } },
            .{ .type = INPUT_KEYBOARD, .unnamed = .{ .ki = .{ .wVk = t.VK_CONTROL, .wScan = 0, .dwFlags = KEYEVENTF_KEYUP, .time = 0, .dwExtraInfo = t.ZWIN_INJECTED_TAG } } },
        };
        _ = t.SendInput(2, &inputs, @sizeOf(t.INPUT));
    }

    pub fn enqueueIntent(self: *InputEngine, intent: UserIntent) void {
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
        if (current_head == current_tail) return null;
        const intent = self.intents[current_head];
        const next_head = (current_head + 1) & intent_mask;
        self.head.store(next_head, .release);
        return intent;
    }

    pub fn reportDroppedIntents(self: *InputEngine) void {
        const count = self.dropped_count.swap(0, .monotonic);
        if (count > 0) logger.warn("Hook", "dropped {d} intents due to queue overflow", .{count});
    }
};

fn keyboardCallback(nCode: i32, wParam: t.WPARAM, lParam: t.LPARAM) callconv(.winapi) t.LRESULT {
    if (nCode != 0) return t.CallNextHookEx(null, nCode, wParam, lParam);
    const self = InputEngine.global orelse return t.CallNextHookEx(null, nCode, wParam, lParam);
    if (self.paused.load(.acquire)) return t.CallNextHookEx(null, nCode, wParam, lParam);

    const kbd: *const t.KBDLLHOOKSTRUCT = @ptrFromInt(@as(usize, @bitCast(lParam)));
    if (kbd.dwExtraInfo == t.ZWIN_INJECTED_TAG) return t.CallNextHookEx(null, nCode, wParam, lParam);

    const is_down = (wParam == t.WM_KEYDOWN or wParam == t.WM_SYSKEYDOWN);
    const is_up = (wParam == t.WM_KEYUP or wParam == t.WM_SYSKEYUP);

    if (is_up) {
        if (kbd.vkCode == t.VK_MENU or kbd.vkCode == t.VK_LMENU or kbd.vkCode == t.VK_RMENU) {
            if (self.consumed_alt) {
                self.consumed_alt = false;
                InputEngine.neutralizeSystemMenu();
            }
        }
        if (kbd.vkCode == 0x5B or kbd.vkCode == 0x5C) {
            if (self.consumed_win) {
                self.consumed_win = false;
                InputEngine.neutralizeSystemMenu();
            }
        }
    }

    if (is_down and kbd.vkCode == t.VK_ESCAPE and (self.gesture.isBusy() or self.pending_mouse_action != null)) {
        self.pending_mouse_action = null;
        self.enqueueIntent(.abort_gesture);
        return 1;
    }

    const current_mods = InputEngine.sampleModifiers();
    if (current_mods.isEmpty() or !self.intent_handler.hasMatchingModifierSubset(current_mods)) {
        return t.CallNextHookEx(null, nCode, wParam, lParam);
    }

    if (is_down) {
        if (self.intent_handler.matchKeyBinding(current_mods, kbd.vkCode)) |act| {
            if (current_mods.alt) self.consumed_alt = true;
            if (current_mods.win) self.consumed_win = true;

            if (act.toUserIntent()) |intent| {
                self.enqueueIntent(intent);
                return 1;
            }
        }
    }

    return t.CallNextHookEx(null, nCode, wParam, lParam);
}

fn mouseCallback(nCode: i32, wParam: t.WPARAM, lParam: t.LPARAM) callconv(.winapi) t.LRESULT {
    if (nCode != 0) return t.CallNextHookEx(null, nCode, wParam, lParam);
    const self = InputEngine.global orelse return t.CallNextHookEx(null, nCode, wParam, lParam);
    const mouse: *const t.MSLLHOOKSTRUCT = @ptrFromInt(@as(usize, @bitCast(lParam)));
    const pt: geom.Point = .{ .x = mouse.pt.x, .y = mouse.pt.y };

    if (mouse.dwExtraInfo == t.ZWIN_INJECTED_TAG) return t.CallNextHookEx(null, nCode, wParam, lParam);
    if (wParam == t.WM_MOUSEMOVE) self.last_hook_mouse_ms.store(t.GetTickCount64(), .release);

    if (!self.paused.load(.acquire)) {
        const current_mods = InputEngine.sampleModifiers();

        if (!current_mods.isEmpty() and self.intent_handler.hasMatchingModifierSubset(current_mods)) {
            const m_trig: ?MouseTrigger = switch (wParam) {
                t.WM_LBUTTONDOWN => .left,
                t.WM_RBUTTONDOWN => .right,
                t.WM_MBUTTONDOWN => .middle,
                t.WM_MOUSEWHEEL => .wheel,
                else => null,
            };

            if (m_trig) |trig| {
                if (self.intent_handler.matchMouseBinding(current_mods, trig)) |act| {
                    if (actionableWindowAt(mouse.pt, self.intent_handler.config)) |win| {
                        if (current_mods.alt) self.consumed_alt = true;
                        if (current_mods.win) self.consumed_win = true;

                        switch (act) {
                            .drag_move, .drag_resize => {
                                self.pending_mouse_action = .{
                                    .action = act,
                                    .pt = pt,
                                    .win = win,
                                };
                                return 1;
                            },
                            .minimize => {
                                self.consumed_mbutton = true;
                                self.enqueueIntent(.{ .minimize_at = .{ .pt = pt } });
                                return 1;
                            },
                            .adjust_opacity => {
                                const delta_raw: i16 = @bitCast(@as(u16, @intCast((mouse.mouseData >> 16) & 0xFFFF)));
                                const step: i32 = @intCast(self.config.opacity_step);
                                const change: i32 = if (delta_raw > 0) step else -step;
                                self.enqueueIntent(.{ .adjust_opacity_at = .{ .pt = pt, .delta = change } });
                                return 1;
                            },
                            else => {},
                        }
                    }
                }
            }
        }
    }

    if (wParam == t.WM_MOUSEMOVE) {
        if (self.pending_mouse_action) |pa| {
            const dx = @abs(pt.x - pa.pt.x);
            const dy = @abs(pt.y - pa.pt.y);
            if (dx >= self.drag_threshold or dy >= self.drag_threshold) {
                pa.win.ensureRestored();
                _ = t.SetForegroundWindow(pa.win.hwnd);
                const target = WindowTarget{
                    .hwnd = pa.win.hwnd,
                    .session_id = self.gesture.worker.invalidateSession(),
                };

                if (pa.action == .drag_move) {
                    self.gesture.startDrag(target, pa.pt, pa.win.getPhysicalBounds(), pa.win.getShadowPadding());
                } else if (pa.action == .drag_resize) {
                    const bounds = pa.win.getPhysicalBounds();
                    const pad = pa.win.getShadowPadding();
                    const sector = geom.calculateSector(bounds.width(), bounds.height(), pa.pt.x - bounds.left, pa.pt.y - bounds.top);
                    self.gesture.startResize(target, pa.pt, bounds, sector, pad);
                }
                self.pending_mouse_action = null;
            }
        }

        if (self.gesture.isBusy()) {
            self.gesture.updateMouseMove(pt);
        }
    }

    if (wParam == t.WM_LBUTTONUP or wParam == t.WM_RBUTTONUP or wParam == t.WM_MBUTTONUP) {
        if (wParam == t.WM_MBUTTONUP and self.consumed_mbutton) {
            self.consumed_mbutton = false;
            return 1;
        }
        if (self.pending_mouse_action != null) {
            self.pending_mouse_action = null;
            forwardOriginalClick(if (wParam == t.WM_LBUTTONUP) .left else if (wParam == t.WM_RBUTTONUP) .right else .middle);
            return 1;
        }

        if (self.gesture.isBusy()) {
            self.gesture.finish();
            return 1;
        }
    }

    return t.CallNextHookEx(null, nCode, wParam, lParam);
}

fn forwardOriginalClick(button: enum { left, right, middle }) void {
    const INPUT_MOUSE: u32 = 0;
    const down_flag: u32 = switch (button) {
        .left => 0x0002,
        .right => 0x0008,
        .middle => 0x0020,
    };
    const up_flag: u32 = switch (button) {
        .left => 0x0004,
        .right => 0x0010,
        .middle => 0x0040,
    };

    const inputs = [_]t.INPUT{
        .{ .type = INPUT_MOUSE, .unnamed = .{ .mi = .{ .dx = 0, .dy = 0, .mouseData = 0, .dwFlags = down_flag, .time = 0, .dwExtraInfo = t.ZWIN_INJECTED_TAG } } },
        .{ .type = INPUT_MOUSE, .unnamed = .{ .mi = .{ .dx = 0, .dy = 0, .mouseData = 0, .dwFlags = up_flag, .time = 0, .dwExtraInfo = t.ZWIN_INJECTED_TAG } } },
    };
    _ = t.SendInput(2, &inputs, @sizeOf(t.INPUT));
}

fn actionableWindowAt(pt: t.POINT, config: *const Config) ?Window {
    const raw_hwnd = t.WindowFromPoint(pt) orelse return null;
    const top = Window.getTrueTopLevel(raw_hwnd) orelse return null;
    const win = Window.init(top);
    if (win.isExclusiveFullScreen() or win.isIgnored(config)) return null;
    return win;
}
