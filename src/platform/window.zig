const std = @import("std");
const t = @import("win32.zig");
const geom = @import("../calc/geometry.zig");

pub const Window = struct {
    hwnd: t.HWND,

    pub fn init(hwnd: t.HWND) Window {
        return .{ .hwnd = hwnd };
    }

    pub fn getTrueTopLevel(hwnd: t.HWND) ?t.HWND {
        var curr = hwnd;
        if (@intFromPtr(curr) == 0) return null;

        if (t.GetAncestor(curr, t.GA_ROOTOWNER)) |root_owner| {
            curr = root_owner;
        } else if (t.GetAncestor(curr, t.GA_ROOT)) |root| {
            curr = root;
        }

        if (isManageableTopLevel(curr)) return curr;
        return null;
    }

    fn isManageableTopLevel(hwnd: t.HWND) bool {
        if (@intFromPtr(hwnd) == 0) return false;

        const style = t.GetWindowLongPtrW(hwnd, t.GWL_STYLE);
        if ((style & t.WS_CHILD) != 0) return false;

        const ex_style = t.GetWindowLongPtrW(hwnd, t.GWL_EXSTYLE);
        if ((ex_style & t.WS_EX_TOOLWINDOW) != 0 and (ex_style & t.WS_EX_APPWINDOW) == 0) {
            return false;
        }

        var class_name_buf: [64]u16 = undefined;
        const len = t.GetClassNameW(hwnd, &class_name_buf, class_name_buf.len);
        if (len > 0) {
            const cls = class_name_buf[0..@intCast(len)];
            const blocked = [_][]const u16{
                std.unicode.utf8ToUtf16LeStringLiteral("Progman"),
                std.unicode.utf8ToUtf16LeStringLiteral("WorkerW"),
                std.unicode.utf8ToUtf16LeStringLiteral("Shell_TrayWnd"),
                std.unicode.utf8ToUtf16LeStringLiteral("Shell_SecondaryTrayWnd"),
                std.unicode.utf8ToUtf16LeStringLiteral("XamlExplorerHostIslandWindow"),
                std.unicode.utf8ToUtf16LeStringLiteral("TaskSwitcherWnd"),
                std.unicode.utf8ToUtf16LeStringLiteral("ForegroundStaging"),
                std.unicode.utf8ToUtf16LeStringLiteral("MultitaskingViewFrame"),
            };
            for (blocked) |b| {
                if (std.mem.eql(u16, cls, b)) return false;
            }
        }
        return true;
    }

    pub fn isExclusiveFullScreen(self: Window) bool {
        if (t.IsZoomed(self.hwnd) != 0) return false;
        const style = t.GetWindowLongPtrW(self.hwnd, t.GWL_STYLE);
        if ((style & t.WS_CAPTION) == t.WS_CAPTION) return false;

        const bounds = self.getPhysicalBounds();
        var mi: t.MONITORINFO = .{ .rcMonitor = undefined, .rcWork = undefined, .dwFlags = 0 };
        const mon = t.MonitorFromWindow(self.hwnd, t.MONITOR_DEFAULTTONEAREST);
        if (t.GetMonitorInfoW(mon, &mi) == 0) return false;

        return bounds.left <= mi.rcMonitor.left and
            bounds.top <= mi.rcMonitor.top and
            bounds.right >= mi.rcMonitor.right and
            bounds.bottom >= mi.rcMonitor.bottom;
    }

    pub fn getPhysicalBounds(self: Window) geom.Rect {
        var raw_bounds: t.RECT = undefined;
        if (t.DwmGetWindowAttribute(self.hwnd, t.DWMWA_EXTENDED_FRAME_BOUNDS, &raw_bounds, @sizeOf(t.RECT)) == 0) {
            return .{ .left = raw_bounds.left, .top = raw_bounds.top, .right = raw_bounds.right, .bottom = raw_bounds.bottom };
        }
        _ = t.GetWindowRect(self.hwnd, &raw_bounds);
        return .{ .left = raw_bounds.left, .top = raw_bounds.top, .right = raw_bounds.right, .bottom = raw_bounds.bottom };
    }

    pub fn getShadowPadding(self: Window) geom.Padding {
        var frame: t.RECT = undefined;
        var whole: t.RECT = undefined;
        if (t.DwmGetWindowAttribute(self.hwnd, t.DWMWA_EXTENDED_FRAME_BOUNDS, &frame, @sizeOf(t.RECT)) == 0 and
            t.GetWindowRect(self.hwnd, &whole) != 0)
        {
            return .{
                .l = frame.left - whole.left,
                .t = frame.top - whole.top,
                .r = whole.right - frame.right,
                .b = whole.bottom - frame.bottom,
            };
        }
        return .{};
    }

    pub fn getMonitorWorkArea(self: Window) ?geom.Rect {
        const mon = t.MonitorFromWindow(self.hwnd, t.MONITOR_DEFAULTTONEAREST);
        var mi: t.MONITORINFO = .{ .rcMonitor = undefined, .rcWork = undefined, .dwFlags = 0 };
        if (t.GetMonitorInfoW(mon, &mi) == 0) return null;
        return .{
            .left = mi.rcWork.left,
            .top = mi.rcWork.top,
            .right = mi.rcWork.right,
            .bottom = mi.rcWork.bottom,
        };
    }

    pub fn adjustOpacity(self: Window, delta: i32) void {
        var ex_style = t.GetWindowLongPtrW(self.hwnd, t.GWL_EXSTYLE);
        var current_alpha: u8 = 255;

        if ((ex_style & t.WS_EX_LAYERED) != 0) {
            if (t.GetLayeredWindowAttributes(self.hwnd, null, &current_alpha, null) == 0) current_alpha = 255;
        } else {
            ex_style |= t.WS_EX_LAYERED;
            _ = t.SetWindowLongPtrW(self.hwnd, t.GWL_EXSTYLE, ex_style);
        }

        const new_alpha: u8 = @intCast(std.math.clamp(@as(i32, current_alpha) + delta, 30, 255));

        if (new_alpha >= 255) {
            _ = t.SetLayeredWindowAttributes(self.hwnd, 0, 255, t.LWA_ALPHA);
            _ = t.SetWindowLongPtrW(self.hwnd, t.GWL_EXSTYLE, ex_style & ~t.WS_EX_LAYERED);
        } else {
            _ = t.SetLayeredWindowAttributes(self.hwnd, 0, new_alpha, t.LWA_ALPHA);
        }
    }

    pub fn close(self: Window) void {
        const SC_CLOSE: usize = 0xF060;
        _ = t.PostMessageW(self.hwnd, t.WM_SYSCOMMAND, SC_CLOSE, 0);
    }

    pub fn minimize(self: Window) void {
        _ = t.ShowWindow(self.hwnd, t.SW_MINIMIZE);
    }

    pub fn ensureRestored(self: Window) void {
        if (t.IsZoomed(self.hwnd) != 0) {
            _ = t.ShowWindow(self.hwnd, t.SW_RESTORE);
        }
    }
};
