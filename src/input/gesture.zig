const t = @import("../platform/win32.zig");
const geom = @import("../calc/geometry.zig");
const WindowTarget = @import("../domain/window_target.zig").WindowTarget;
const WindowWorker = @import("../infra/worker.zig").WindowWorker;
const Config = @import("../domain/config.zig").Config;

pub const GestureState = union(enum) {
    idle,
    dragging: struct {
        target: WindowTarget,
        start_pt: geom.Point,
        start_bounds: geom.Rect,
        dpi: u32,
    },
    resizing: struct {
        target: WindowTarget,
        start_pt: geom.Point,
        start_bounds: geom.Rect,
        sector: geom.Sector,
        shadow_pad: geom.Padding,
    },
};

fn rectFromWin32(rc: t.RECT) geom.Rect {
    return .{ .left = rc.left, .top = rc.top, .right = rc.right, .bottom = rc.bottom };
}

pub const GestureStateMachine = struct {
    state: GestureState = .idle,
    worker: *WindowWorker,
    config: *const Config,

    pub fn init(worker: *WindowWorker, config: *const Config) GestureStateMachine {
        return .{ .worker = worker, .config = config };
    }

    pub fn startDrag(self: *GestureStateMachine, target: WindowTarget, cursor: geom.Point, bounds: geom.Rect) void {
        self.state = .{ .dragging = .{
            .target = target,
            .start_pt = cursor,
            .start_bounds = bounds,
            .dpi = t.GetDpiForWindow(target.hwnd),
        } };
    }

    pub fn startResize(
        self: *GestureStateMachine,
        target: WindowTarget,
        cursor: geom.Point,
        bounds: geom.Rect,
        sector: geom.Sector,
        pad: geom.Padding,
    ) void {
        self.state = .{ .resizing = .{
            .target = target,
            .start_pt = cursor,
            .start_bounds = bounds,
            .sector = sector,
            .shadow_pad = pad,
        } };
    }

    pub fn updateMouseMove(self: *GestureStateMachine, current_pt: geom.Point) void {
        switch (self.state) {
            .idle => {},
            .dragging => |d| {
                var a = d;
                const dpi = t.GetDpiForWindow(a.target.hwnd);
                if (dpi != 0 and dpi != a.dpi) {
                    var rc: t.RECT = undefined;
                    if (t.GetWindowRect(a.target.hwnd, &rc) == 0) return;
                    a = .{
                        .target = a.target,
                        .start_pt = current_pt,
                        .start_bounds = rectFromWin32(rc),
                        .dpi = dpi,
                    };
                    self.state = .{ .dragging = a };
                }
                self.worker.postStreaming(a.target, .{ .move = .{
                    .x = a.start_bounds.left + (current_pt.x - a.start_pt.x),
                    .y = a.start_bounds.top + (current_pt.y - a.start_pt.y),
                } });
            },
            .resizing => |r| {
                const delta: geom.Point = .{
                    .x = current_pt.x - r.start_pt.x,
                    .y = current_pt.y - r.start_pt.y,
                };
                const rc = geom.calculateResizedRect(
                    r.start_bounds,
                    delta,
                    r.sector,
                    self.config.min_window_width,
                    self.config.min_window_height,
                );
                const pad = r.shadow_pad;
                self.worker.postStreaming(r.target, .{ .resize = .{
                    .x = rc.left - pad.l,
                    .y = rc.top - pad.t,
                    .w = rc.width() + pad.l + pad.r,
                    .h = rc.height() + pad.t + pad.b,
                } });
            },
        }
    }

    pub fn finish(self: *GestureStateMachine) void {
        self.state = .idle;
    }

    pub fn isBusy(self: *const GestureStateMachine) bool {
        return self.state != .idle;
    }
};
