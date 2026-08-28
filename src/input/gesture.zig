const t = @import("../platform/win32.zig");
const geom = @import("../calc/geometry.zig");
const WindowTarget = @import("../domain/window_target.zig").WindowTarget;
const WindowWorker = @import("../infra/worker.zig").WindowWorker;
const Config = @import("../domain/config.zig").Config;
const Window = @import("../platform/window.zig").Window;

const snap_threshold: i32 = 20;

pub const GestureState = union(enum) {
    idle,
    dragging: struct {
        target: WindowTarget,
        start_pt: geom.Point,
        start_bounds: geom.Rect,
        shadow_pad: geom.Padding,
        work_area: ?geom.Rect,
        dpi: u32,
    },
    resizing: struct {
        target: WindowTarget,
        start_pt: geom.Point,
        start_bounds: geom.Rect,
        sector: geom.Sector,
        shadow_pad: geom.Padding,
        work_area: ?geom.Rect,
    },
};

fn rectFromWin32(rc: t.RECT) geom.Rect {
    return .{ .left = rc.left, .top = rc.top, .right = rc.right, .bottom = rc.bottom };
}

// Map sector to WM_SIZING edge flag for grid alignment
fn sectorToWmsz(sector: geom.Sector) usize {
    return switch (sector) {
        .top_left => t.WMSZ_TOPLEFT,
        .top => t.WMSZ_TOP,
        .top_right => t.WMSZ_TOPRIGHT,
        .left => t.WMSZ_LEFT,
        .center => t.WMSZ_BOTTOMRIGHT,
        .right => t.WMSZ_RIGHT,
        .bottom_left => t.WMSZ_BOTTOMLEFT,
        .bottom => t.WMSZ_BOTTOM,
        .bottom_right => t.WMSZ_BOTTOMRIGHT,
    };
}

// Map 3×3 grid sector to the corresponding Win32 cursor resource ID
fn cursorIdForSector(sector: geom.Sector) usize {
    return switch (sector) {
        .top_left, .bottom_right => t.IDC_SIZENWSE,
        .top_right, .bottom_left => t.IDC_SIZENESW,
        .left, .right => t.IDC_SIZEWE,
        .top, .bottom => t.IDC_SIZENS,
        .center => t.IDC_SIZEALL,
    };
}

fn setCursorForSector(sector: geom.Sector) void {
    const id = cursorIdForSector(sector);
    const cur = t.LoadCursorW(null, @ptrFromInt(id));
    _ = t.SetCursor(cur);
}

fn setCursorForDrag() void {
    const cur = t.LoadCursorW(null, @ptrFromInt(t.IDC_SIZEALL));
    _ = t.SetCursor(cur);
}

fn restoreCursor() void {
    const cur = t.LoadCursorW(null, @ptrFromInt(t.IDC_ARROW));
    _ = t.SetCursor(cur);
}

// Continuous gesture state machine for window drag and resize
pub const GestureStateMachine = struct {
    state: GestureState = .idle,
    worker: *WindowWorker,
    config: *const Config,

    pub fn init(worker: *WindowWorker, config: *const Config) GestureStateMachine {
        return .{ .worker = worker, .config = config };
    }

    pub fn startDrag(
        self: *GestureStateMachine,
        target: WindowTarget,
        cursor: geom.Point,
        bounds: geom.Rect,
        pad: geom.Padding,
    ) void {
        const win = Window.init(target.hwnd);
        self.state = .{ .dragging = .{
            .target = target,
            .start_pt = cursor,
            .start_bounds = bounds,
            .shadow_pad = pad,
            .work_area = win.getMonitorWorkArea(),
            .dpi = t.GetDpiForWindow(target.hwnd),
        } };
        const cur = t.LoadCursorW(null, @ptrFromInt(t.IDC_SIZEALL));
        _ = t.SetCursor(cur);
        announceMoveSize(self.state.dragging.target.hwnd);
    }

    pub fn startResize(
        self: *GestureStateMachine,
        target: WindowTarget,
        cursor: geom.Point,
        bounds: geom.Rect,
        sector: geom.Sector,
        pad: geom.Padding,
    ) void {
        const win = Window.init(target.hwnd);
        self.state = .{ .resizing = .{
            .target = target,
            .start_pt = cursor,
            .start_bounds = bounds,
            .sector = sector,
            .shadow_pad = pad,
            .work_area = win.getMonitorWorkArea(),
        } };
        setCursorForSector(sector);
        announceMoveSize(self.state.resizing.target.hwnd);
    }

    pub fn updateMouseMove(self: *GestureStateMachine, current_pt: geom.Point) void {
        const app_ptr = @import("../app.zig").App.global;
        switch (self.state) {
            .idle => {},
            .dragging => |d| {
                setCursorForDrag();
                var a = d;
                const dpi = t.GetDpiForWindow(a.target.hwnd);
                if (dpi != 0 and dpi != a.dpi) {
                    var rc: t.RECT = undefined;
                    if (t.GetWindowRect(a.target.hwnd, &rc) == 0) return;
                    a.start_pt = current_pt;
                    a.start_bounds = rectFromWin32(rc);
                    a.dpi = dpi;
                    a.work_area = Window.init(a.target.hwnd).getMonitorWorkArea();
                    self.state = .{ .dragging = a };
                }

                var physical_bounds = geom.Rect{
                    .left = a.start_bounds.left + (current_pt.x - a.start_pt.x),
                    .top = a.start_bounds.top + (current_pt.y - a.start_pt.y),
                    .right = a.start_bounds.right + (current_pt.x - a.start_pt.x),
                    .bottom = a.start_bounds.bottom + (current_pt.y - a.start_pt.y),
                };

                if (a.work_area) |wa| {
                    physical_bounds = geom.snapMoveBounds(physical_bounds, wa, snap_threshold);
                }

                const pad = a.shadow_pad;
                self.worker.postStreaming(a.target, .{ .move = .{
                    .x = physical_bounds.left - pad.l,
                    .y = physical_bounds.top - pad.t,
                } });
            },
            .resizing => |r| {
                setCursorForSector(r.sector);
                const delta: geom.Point = .{
                    .x = current_pt.x - r.start_pt.x,
                    .y = current_pt.y - r.start_pt.y,
                };
                var rc = geom.calculateResizedRect(
                    r.start_bounds,
                    delta,
                    r.sector,
                    self.config.min_window_width,
                    self.config.min_window_height,
                );

                if (r.work_area) |wa| {
                    rc = geom.snapResizeBounds(rc, wa, r.sector, snap_threshold);
                }

                const pad = r.shadow_pad;
                const width = rc.width();
                const height = rc.height();

                if (app_ptr) |app| {
                    app.osd.showResize(current_pt, width, height);
                }

                self.worker.postStreaming(r.target, .{ .resize = .{
                    .x = rc.left - pad.l,
                    .y = rc.top - pad.t,
                    .w = width + pad.l + pad.r,
                    .h = height + pad.t + pad.b,
                    .wmsz = sectorToWmsz(r.sector),
                } });
            },
        }
    }

    pub fn finish(self: *GestureStateMachine) void {
        const app_ptr = @import("../app.zig").App.global;
        if (app_ptr) |app| app.osd.hide();

        switch (self.state) {
            .dragging => |d| endMoveSize(d.target.hwnd),
            .resizing => |r| endMoveSize(r.target.hwnd),
            .idle => {},
        }
        self.state = .idle;
        restoreCursor();
    }

    // Abort gesture on ESC and restore initial window bounds
    pub fn abort(self: *GestureStateMachine) void {
        const app_ptr = @import("../app.zig").App.global;
        if (app_ptr) |app| app.osd.hide();

        switch (self.state) {
            .idle => return,
            .dragging => |d| {
                self.worker.postStreaming(d.target, .{ .move = .{
                    .x = d.start_bounds.left - d.shadow_pad.l,
                    .y = d.start_bounds.top - d.shadow_pad.t,
                } });
            },
            .resizing => |r| {
                const b = r.start_bounds;
                const pad = r.shadow_pad;
                self.worker.postStreaming(r.target, .{ .resize = .{
                    .x = b.left - pad.l,
                    .y = b.top - pad.t,
                    .w = b.width() + pad.l + pad.r,
                    .h = b.height() + pad.t + pad.b,
                    .wmsz = sectorToWmsz(r.sector),
                } });
            },
        }
        self.finish();
    }

    pub fn isBusy(self: *const GestureStateMachine) bool {
        return self.state != .idle;
    }
};

// Send standard Win32 move/size lifecycle notifications
fn announceMoveSize(hwnd: t.HWND) void {
    _ = t.PostMessageW(hwnd, t.WM_ENTERSIZEMOVE, 0, 0);
    t.NotifyWinEvent(t.EVENT_SYSTEM_MOVESIZESTART, hwnd, t.OBJID_WINDOW, 0);
}

fn endMoveSize(hwnd: t.HWND) void {
    _ = t.PostMessageW(hwnd, t.WM_EXITSIZEMOVE, 0, 0);
    t.NotifyWinEvent(t.EVENT_SYSTEM_MOVESIZEEND, hwnd, t.OBJID_WINDOW, 0);
}
