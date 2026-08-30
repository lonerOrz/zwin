const t = @import("../platform/win32.zig");
const geom = @import("../calc/geometry.zig");
const types = @import("../domain/types.zig");
const WindowTarget = types.WindowTarget;
const WindowWorker = @import("../infra/worker.zig").WindowWorker;
const Config = @import("../domain/config.zig").Config;
const Window = @import("../platform/window.zig").Window;
const OsdManager = @import("../wm/osd.zig").OsdManager;

pub const GestureState = union(enum) {
    idle,
    dragging: struct {
        target: WindowTarget,
        start_pt: geom.Point,
        start_bounds: geom.Rect,
        shadow_pad: geom.Padding,
        work_area: ?geom.Rect,
        snap_targets: geom.SnapTargetList,
        dpi: u32,
    },
    resizing: struct {
        target: WindowTarget,
        start_pt: geom.Point,
        start_bounds: geom.Rect,
        sector: geom.Sector,
        shadow_pad: geom.Padding,
        work_area: ?geom.Rect,
        snap_targets: geom.SnapTargetList,
    },
};

fn setCursorById(id: usize) void {
    const cur = t.LoadCursorW(null, @ptrFromInt(id));
    _ = t.SetCursor(cur);
}

pub const GestureStateMachine = struct {
    state: GestureState = .idle,
    worker: *WindowWorker,
    config: *const Config,
    osd: *OsdManager,
    last_osd_w: i32 = 0,
    last_osd_h: i32 = 0,
    last_sent_w: i32 = 0,
    last_sent_h: i32 = 0,

    pub fn init(worker: *WindowWorker, config: *const Config, osd: *OsdManager) GestureStateMachine {
        return .{ .worker = worker, .config = config, .osd = osd };
    }

    pub fn startDrag(self: *GestureStateMachine, target: WindowTarget, cursor: geom.Point, bounds: geom.Rect, pad: geom.Padding) void {
        const win = Window.init(target.hwnd);
        var snap_targets = geom.SnapTargetList{};
        if (self.config.window_snap) Window.collectSnapTargets(target.hwnd, self.config, &snap_targets);

        self.state = .{ .dragging = .{
            .target = target,
            .start_pt = cursor,
            .start_bounds = bounds,
            .shadow_pad = pad,
            .work_area = win.getMonitorWorkArea(),
            .snap_targets = snap_targets,
            .dpi = t.GetDpiForWindow(target.hwnd),
        } };
        setCursorById(32646); // IDC_SIZEALL
    }

    pub fn startResize(self: *GestureStateMachine, target: WindowTarget, cursor: geom.Point, bounds: geom.Rect, sector: geom.Sector, pad: geom.Padding) void {
        const win = Window.init(target.hwnd);
        var snap_targets = geom.SnapTargetList{};
        if (self.config.window_snap) Window.collectSnapTargets(target.hwnd, self.config, &snap_targets);

        self.last_sent_w = bounds.width();
        self.last_sent_h = bounds.height();

        self.state = .{ .resizing = .{
            .target = target,
            .start_pt = cursor,
            .start_bounds = bounds,
            .sector = sector,
            .shadow_pad = pad,
            .work_area = win.getMonitorWorkArea(),
            .snap_targets = snap_targets,
        } };
        setCursorById(sector.cursorResourceId());
    }

    pub fn updateMouseMove(self: *GestureStateMachine, current_pt: geom.Point) void {
        switch (self.state) {
            .idle => {},
            .dragging => |d| {
                setCursorById(32646);
                var a = d;
                const dpi = t.GetDpiForWindow(a.target.hwnd);
                if (dpi != 0 and dpi != a.dpi) {
                    var rc: t.RECT = undefined;
                    if (t.GetWindowRect(a.target.hwnd, &rc) == 0) return;
                    a.start_pt = current_pt;
                    a.start_bounds = .{ .left = rc.left, .top = rc.top, .right = rc.right, .bottom = rc.bottom };
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
                    physical_bounds = geom.snapMoveBoundsEx(physical_bounds, wa, a.snap_targets.slice(), self.config.snap_threshold, self.config.window_snap);
                }

                const pad = a.shadow_pad;
                self.worker.postStreaming(a.target, .{ .move = .{
                    .x = physical_bounds.left - pad.l,
                    .y = physical_bounds.top - pad.t,
                } });
            },
            .resizing => |r| {
                setCursorById(r.sector.cursorResourceId());
                const delta: geom.Point = .{
                    .x = current_pt.x - r.start_pt.x,
                    .y = current_pt.y - r.start_pt.y,
                };
                var rc = geom.calculateResizedRect(r.start_bounds, delta, r.sector, self.config.min_width, self.config.min_height);

                if (r.work_area) |wa| {
                    rc = geom.snapResizeBoundsEx(rc, wa, r.snap_targets.slice(), r.sector, self.config.snap_threshold, self.config.window_snap);
                }

                const pad = r.shadow_pad;
                const width = rc.width();
                const height = rc.height();

                // OSD 显示更新
                if ((@abs(width - self.last_osd_w) >= 2) or (@abs(height - self.last_osd_h) >= 2)) {
                    self.last_osd_w = width;
                    self.last_osd_h = height;
                    self.osd.showResize(current_pt, width, height);
                }

                // 物理尺寸去重：尺寸未变化则不下发给目标窗口，减轻目标应用排版引擎压力
                if (width != self.last_sent_w or height != self.last_sent_h) {
                    self.last_sent_w = width;
                    self.last_sent_h = height;

                    self.worker.postStreaming(r.target, .{ .resize = .{
                        .x = rc.left - pad.l,
                        .y = rc.top - pad.t,
                        .w = width + pad.l + pad.r,
                        .h = height + pad.t + pad.b,
                        .wmsz = r.sector.toWmsz(),
                    } });
                }
            },
        }
    }

    pub fn finish(self: *GestureStateMachine) void {
        self.osd.hide();

        switch (self.state) {
            .dragging => |d| endMoveSize(d.target.hwnd),
            .resizing => |r| endMoveSize(r.target.hwnd),
            .idle => {},
        }
        self.state = .idle;
        setCursorById(32512); // IDC_ARROW
    }

    pub fn abort(self: *GestureStateMachine) void {
        self.osd.hide();

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
                    .wmsz = r.sector.toWmsz(),
                } });
            },
        }
        self.finish();
    }

    pub inline fn isBusy(self: *const GestureStateMachine) bool {
        return self.state != .idle;
    }
};

fn endMoveSize(hwnd: t.HWND) void {
    _ = t.PostMessageW(hwnd, t.WM_EXITSIZEMOVE, 0, 0);
    t.NotifyWinEvent(t.EVENT_SYSTEM_MOVESIZEEND, hwnd, t.OBJID_WINDOW, 0);
}
