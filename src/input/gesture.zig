const t = @import("../platform/win32.zig");
const geom = @import("../calc/geometry.zig");
const WindowWorker = @import("../infra/worker.zig").WindowWorker;
const Config = @import("../domain/config.zig").Config;

pub const GestureState = union(enum) {
    idle,
    dragging: struct {
        hwnd: t.HWND,
        start_pt: geom.Point,
        start_bounds: geom.Rect,
        dpi: u32,
    },
    resizing: struct {
        hwnd: t.HWND,
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

    pub fn startDrag(self: *GestureStateMachine, hwnd: t.HWND, cursor: geom.Point, bounds: geom.Rect) void {
        self.state = .{ .dragging = .{
            .hwnd = hwnd,
            .start_pt = cursor,
            .start_bounds = bounds,
            .dpi = t.GetDpiForWindow(hwnd),
        } };
    }

    pub fn startResize(
        self: *GestureStateMachine,
        hwnd: t.HWND,
        cursor: geom.Point,
        bounds: geom.Rect,
        sector: geom.Sector,
        pad: geom.Padding,
    ) void {
        self.state = .{ .resizing = .{
            .hwnd = hwnd,
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
                const dpi = t.GetDpiForWindow(d.hwnd);
                if (dpi != 0 and dpi != d.dpi) {
                    var rc: t.RECT = undefined;
                    if (t.GetWindowRect(d.hwnd, &rc) == 0) return;
                    a = .{
                        .hwnd = d.hwnd,
                        .start_pt = current_pt,
                        .start_bounds = rectFromWin32(rc),
                        .dpi = dpi,
                    };
                    self.state = .{ .dragging = a };
                }
                self.worker.postCoalesced(.{
                    .hwnd = a.hwnd,
                    .x = a.start_bounds.left + (current_pt.x - a.start_pt.x),
                    .y = a.start_bounds.top + (current_pt.y - a.start_pt.y),
                    .w = 0,
                    .h = 0,
                    .flags = t.SWP_NOSIZE | t.SWP_NOZORDER | t.SWP_NOACTIVATE | t.SWP_NOCOPYBITS | t.SWP_NOOWNERZORDER,
                });
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
                self.worker.postCoalesced(.{
                    .hwnd = r.hwnd,
                    .x = rc.left - pad.l,
                    .y = rc.top - pad.t,
                    .w = rc.width() + pad.l + pad.r,
                    .h = rc.height() + pad.t + pad.b,
                    .flags = t.SWP_NOZORDER | t.SWP_NOACTIVATE | t.SWP_NOCOPYBITS | t.SWP_NOOWNERZORDER,
                });
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
