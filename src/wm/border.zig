const t = @import("../platform/win32.zig");
const Config = @import("../domain/config.zig").Config;
const Window = @import("../platform/window.zig").Window;
const logger = @import("../infra/logger.zig");

pub const BorderManager = struct {
    last_active: ?t.HWND = null,
    config: *const Config,

    pub fn init(config: *const Config) BorderManager {
        return .{ .config = config };
    }

    pub fn onFocusChange(self: *BorderManager, raw_hwnd: t.HWND) void {
        if (!self.config.enable_border) {
            self.reset();
            return;
        }

        const true_hwnd = Window.getTrueTopLevel(raw_hwnd) orelse {
            self.reset();
            return;
        };

        if (self.last_active != true_hwnd) {
            self.reset();
        }
        self.applyBorder(true_hwnd);
    }

    pub fn refreshCurrent(self: *BorderManager, raw_hwnd: t.HWND) void {
        if (!self.config.enable_border) return;
        const true_hwnd = Window.getTrueTopLevel(raw_hwnd) orelse return;
        self.applyBorder(true_hwnd);
    }

    pub fn onWindowClosedOrHidden(self: *BorderManager, closed_hwnd: t.HWND) void {
        if (self.last_active) |active| {
            if (active == closed_hwnd or t.IsWindow(active) == 0) {
                self.last_active = null;
            }
        }
    }

    fn applyBorder(self: *BorderManager, hwnd: t.HWND) void {
        if (t.IsWindowVisible(hwnd) != 0) {
            const hr = t.DwmSetWindowAttribute(hwnd, t.DWMWA_BORDER_COLOR, &self.config.active_border_color, @sizeOf(u32));
            if (hr == 0) {
                self.last_active = hwnd;
            } else {
                logger.debug("Border", "DwmSetWindowAttribute failed hwnd={x} hr={x}", .{ @intFromPtr(hwnd), hr });
            }
        }
    }

    pub fn reset(self: *BorderManager) void {
        if (self.last_active) |prev| {
            if (t.IsWindow(prev) != 0) {
                _ = t.DwmSetWindowAttribute(prev, t.DWMWA_BORDER_COLOR, &self.config.border_reset_color, @sizeOf(u32));
            }
            self.last_active = null;
        }
    }
};
