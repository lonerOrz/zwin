const std = @import("std");
const t = @import("../platform/win32.zig");
const geom = @import("../calc/geometry.zig");
const types = @import("../domain/types.zig");
const UserIntent = types.UserIntent;
const WindowTarget = types.WindowTarget;
const Window = @import("../platform/window.zig").Window;
const Config = @import("../domain/config.zig").Config;
const WindowWorker = @import("../infra/worker.zig").WindowWorker;
const BorderManager = @import("border.zig").BorderManager;
const OsdManager = @import("osd.zig").OsdManager;
const GestureStateMachine = @import("../input/gesture.zig").GestureStateMachine;

pub const IntentHandler = struct {
    worker: *WindowWorker,
    border_mgr: *BorderManager,
    osd: *OsdManager,
    gesture: *GestureStateMachine,
    config: *const Config,

    minimized_stack: [16]t.HWND = undefined,
    minimized_count: usize = 0,

    pub fn init(
        worker: *WindowWorker,
        border_mgr: *BorderManager,
        osd: *OsdManager,
        gesture: *GestureStateMachine,
        config: *const Config,
    ) IntentHandler {
        return .{
            .worker = worker,
            .border_mgr = border_mgr,
            .osd = osd,
            .gesture = gesture,
            .config = config,
        };
    }

    pub fn recordMinimized(self: *IntentHandler, hwnd: t.HWND) void {
        if (@intFromPtr(hwnd) == 0) return;
        var i: usize = 0;
        while (i < self.minimized_count) {
            if (self.minimized_stack[i] == hwnd) {
                std.mem.copyForwards(t.HWND, self.minimized_stack[i..], self.minimized_stack[i + 1 ..]);
                self.minimized_count -= 1;
                break;
            }
            i += 1;
        }
        if (self.minimized_count >= self.minimized_stack.len) {
            std.mem.copyForwards(t.HWND, self.minimized_stack[0..], self.minimized_stack[1..]);
            self.minimized_count -= 1;
        }
        self.minimized_stack[self.minimized_count] = hwnd;
        self.minimized_count += 1;
    }

    pub fn removeMinimized(self: *IntentHandler, hwnd: t.HWND) void {
        var i: usize = 0;
        while (i < self.minimized_count) {
            if (self.minimized_stack[i] == hwnd) {
                if (i + 1 < self.minimized_count) {
                    std.mem.copyForwards(t.HWND, self.minimized_stack[i..], self.minimized_stack[i + 1 ..]);
                }
                self.minimized_count -= 1;
                return;
            }
            i += 1;
        }
    }

    pub fn popLastMinimized(self: *IntentHandler) ?t.HWND {
        while (self.minimized_count > 0) {
            self.minimized_count -= 1;
            const candidate = self.minimized_stack[self.minimized_count];
            if (t.IsWindow(candidate) != 0 and Window.init(candidate).isMinimized()) {
                return candidate;
            }
        }
        return null;
    }

    pub fn dispatch(self: *IntentHandler, intent: UserIntent) void {
        switch (intent) {
            .move_window_direction => |dir| self.handleMoveDirection(dir),
            .center_active_window => self.handleCenterActive(),
            .toggle_active_topmost => self.handleToggleTopmost(),
            .toggle_active_maximize => self.handleToggleMaximize(),
            .toggle_active_passthrough => self.handleTogglePassthrough(),
            .restore_last_minimized => self.handleRestoreMinimized(),
            .focus_direction => |dir| self.handleFocusDirection(dir),
            .close_active_window => self.handleCloseActive(),
            .abort_gesture => self.gesture.abort(),
            .minimize_at => |m| self.handleMinimizeAt(m.pt),
            .adjust_opacity_at => |op| self.handleAdjustOpacityAt(op.pt, op.delta),
            .foreground_changed => |hwnd| self.handleForegroundChanged(hwnd),
            .window_closed_or_hidden => |hwnd| self.handleWindowClosedOrHidden(hwnd),
        }
    }

    // ─── Individual handlers ─────────────────────────────────────────────────────

    fn handleMoveDirection(self: *IntentHandler, dir: geom.Direction) void {
        const target = self.resolveActiveTarget() orelse return;
        const win = Window.init(target.hwnd);
        win.ensureRestored();

        const bounds = win.getPhysicalBounds();
        const pad = win.getShadowPadding();
        const step = win.scaleDpi(self.config.move_step);
        const vec = dir.toVector(step);
        var moved = geom.offsetRect(bounds, vec);

        if (win.getMonitorWorkArea()) |wa| {
            moved = geom.clampRectToWorkArea(moved, wa);
        }

        self.worker.postDiscrete(target, .{ .set_bounds = .{
            .x = moved.left - pad.l,
            .y = moved.top - pad.t,
            .w = moved.width() + pad.l + pad.r,
            .h = moved.height() + pad.t + pad.b,
        } });
    }

    fn handleCenterActive(self: *IntentHandler) void {
        const target = self.resolveActiveTarget() orelse return;
        const win = Window.init(target.hwnd);
        win.ensureRestored();
        if (win.getMonitorWorkArea()) |wa| {
            const bounds = win.getPhysicalBounds();
            const pad = win.getShadowPadding();
            const centered = geom.calculateCenterRect(wa, bounds, pad);
            self.worker.postDiscrete(target, .{ .set_bounds = .{
                .x = centered.left,
                .y = centered.top,
                .w = centered.width(),
                .h = centered.height(),
            } });
        }
    }

    fn handleToggleTopmost(self: *IntentHandler) void {
        const target = self.resolveActiveTarget() orelse return;
        const ex_style = t.GetWindowLongPtrW(target.hwnd, t.GWL_EXSTYLE);
        const will_topmost = (ex_style & t.WS_EX_TOPMOST) == 0;
        _ = t.SetWindowPos(
            target.hwnd,
            if (will_topmost) t.HWND_TOPMOST else t.HWND_NOTOPMOST,
            0,
            0,
            0,
            0,
            t.SWP_NOMOVE | t.SWP_NOSIZE | t.SWP_NOACTIVATE,
        );
        self.osd.showTopmost(will_topmost, self.config.language);
    }

    fn handleToggleMaximize(self: *IntentHandler) void {
        const target = self.resolveActiveTarget() orelse return;
        Window.init(target.hwnd).toggleMaximize();
    }

    fn handleTogglePassthrough(self: *IntentHandler) void {
        const target = self.resolveActiveTarget() orelse return;
        const is_pt = Window.init(target.hwnd).togglePassthrough();
        self.osd.showPassthrough(is_pt, self.config.language);
    }

    fn handleRestoreMinimized(self: *IntentHandler) void {
        if (self.popLastMinimized()) |hwnd| {
            Window.focusWindow(hwnd);
        }
    }

    fn handleFocusDirection(self: *IntentHandler, dir: geom.Direction) void {
        const current = t.GetForegroundWindow() orelse return;
        if (Window.findDirectionalTarget(current, dir, self.config)) |target| {
            Window.focusWindow(target);
        }
    }

    fn handleCloseActive(self: *IntentHandler) void {
        const target = self.resolveActiveTarget() orelse return;
        Window.init(target.hwnd).close();
    }

    fn handleMinimizeAt(self: *IntentHandler, pt: geom.Point) void {
        const target = self.resolveTargetAtPoint(pt) orelse return;
        Window.init(target.hwnd).minimize();
    }

    fn handleAdjustOpacityAt(self: *IntentHandler, pt: geom.Point, delta: i32) void {
        const target = self.resolveTargetAtPoint(pt) orelse self.resolveActiveTarget() orelse return;
        const win = Window.init(target.hwnd);
        win.adjustOpacity(delta);

        var alpha: u8 = 255;
        var flags: u32 = 0;
        const ex = t.GetWindowLongPtrW(target.hwnd, t.GWL_EXSTYLE);
        if ((ex & t.WS_EX_LAYERED) != 0) {
            if (t.GetLayeredWindowAttributes(target.hwnd, null, &alpha, &flags) == 0 or
                (flags & t.LWA_ALPHA) == 0)
            {
                alpha = 255;
            }
        }
        self.osd.showOpacity(pt, alpha, self.config.language);
    }

    fn handleForegroundChanged(self: *IntentHandler, hwnd: t.HWND) void {
        self.border_mgr.onFocusChange(hwnd);
    }

    fn handleWindowClosedOrHidden(self: *IntentHandler, hwnd: t.HWND) void {
        self.removeMinimized(hwnd);
        self.border_mgr.onWindowClosedOrHidden(hwnd);
    }

    fn resolveActiveTarget(self: *IntentHandler) ?WindowTarget {
        const raw_fg = t.GetForegroundWindow() orelse return null;
        const top = Window.getTrueTopLevel(raw_fg) orelse return null;
        const win = Window.init(top);
        if (win.isExclusiveFullScreen() or win.isIgnored(self.config)) return null;
        return .{ .hwnd = top, .session_id = self.worker.fetchSessionId() };
    }

    fn resolveTargetAtPoint(self: *IntentHandler, pt: geom.Point) ?WindowTarget {
        const raw_hwnd = t.WindowFromPoint(.{ .x = pt.x, .y = pt.y }) orelse return null;
        const top = Window.getTrueTopLevel(raw_hwnd) orelse return null;
        const win = Window.init(top);
        if (win.isExclusiveFullScreen() or win.isIgnored(self.config)) return null;
        return .{ .hwnd = top, .session_id = self.worker.fetchSessionId() };
    }
};
