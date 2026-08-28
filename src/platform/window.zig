const std = @import("std");
const t = @import("win32.zig");
const geom = @import("../calc/geometry.zig");

pub const Window = struct {
    hwnd: t.HWND,

    pub fn init(hwnd: t.HWND) Window {
        return .{ .hwnd = hwnd };
    }

    // Resolve actionable top-level window, filtering tool windows, shell classes, and cloaked windows
    pub fn getTrueTopLevel(hwnd: t.HWND) ?t.HWND {
        if (@intFromPtr(hwnd) == 0) return null;

        const curr = if (t.GetAncestor(hwnd, t.GA_ROOTOWNER)) |ro| ro else (t.GetAncestor(hwnd, t.GA_ROOT) orelse hwnd);
        if (isManageableTopLevel(curr) and !isCloaked(curr)) return curr;
        return null;
    }

    // Check if window is cloaked (e.g. on another virtual desktop or suspended UWP)
    fn isCloaked(hwnd: t.HWND) bool {
        var cloaked: u32 = 0;
        return t.DwmGetWindowAttribute(hwnd, t.DWMWA_CLOAKED, &cloaked, @sizeOf(u32)) == 0 and cloaked != 0;
    }

    // Filter out child windows, unlisted tool windows, 0-size ghost windows, and shell system classes
    fn isManageableTopLevel(hwnd: t.HWND) bool {
        if (@intFromPtr(hwnd) == 0) return false;

        var rc: t.RECT = undefined;
        if (t.GetWindowRect(hwnd, &rc) == 0 or (rc.right - rc.left) <= 0 or (rc.bottom - rc.top) <= 0) return false;

        const style = t.GetWindowLongPtrW(hwnd, t.GWL_STYLE);
        if ((style & t.WS_CHILD) != 0) return false;

        const ex_style = t.GetWindowLongPtrW(hwnd, t.GWL_EXSTYLE);
        if ((ex_style & t.WS_EX_TOOLWINDOW) != 0 and (ex_style & t.WS_EX_APPWINDOW) == 0) return false;

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

    // Check if window covers the entire monitor without a standard caption
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

    // Query physical frame bounds via DWM, falling back to GetWindowRect
    pub fn getPhysicalBounds(self: Window) geom.Rect {
        var raw_bounds: t.RECT = undefined;
        if (t.DwmGetWindowAttribute(self.hwnd, t.DWMWA_EXTENDED_FRAME_BOUNDS, &raw_bounds, @sizeOf(t.RECT)) == 0) {
            return .{ .left = raw_bounds.left, .top = raw_bounds.top, .right = raw_bounds.right, .bottom = raw_bounds.bottom };
        }
        _ = t.GetWindowRect(self.hwnd, &raw_bounds);
        return .{ .left = raw_bounds.left, .top = raw_bounds.top, .right = raw_bounds.right, .bottom = raw_bounds.bottom };
    }

    // Calculate drop-shadow padding offsets between whole window and visible frame
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

    // Query monitor work area excluding taskbar
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

    // Adjust window transparency, toggling WS_EX_LAYERED as needed
    pub fn adjustOpacity(self: Window, delta: i32) void {
        const ex_style = t.GetWindowLongPtrW(self.hwnd, t.GWL_EXSTYLE);
        var current_alpha: u8 = 255;
        var flags: u32 = 0;

        if ((ex_style & t.WS_EX_LAYERED) != 0) {
            if (t.GetLayeredWindowAttributes(self.hwnd, null, &current_alpha, &flags) == 0 or (flags & t.LWA_ALPHA) == 0) {
                current_alpha = 255;
            }
        }

        const new_alpha: u8 = @intCast(std.math.clamp(@as(i32, current_alpha) + delta, 30, 255));

        if (new_alpha >= 255) {
            if ((ex_style & t.WS_EX_LAYERED) != 0) {
                _ = t.SetLayeredWindowAttributes(self.hwnd, 0, 255, t.LWA_ALPHA);
                _ = t.SetWindowLongPtrW(self.hwnd, t.GWL_EXSTYLE, ex_style & ~t.WS_EX_LAYERED);
                _ = t.SetWindowPos(
                    self.hwnd,
                    null,
                    0,
                    0,
                    0,
                    0,
                    t.SWP_NOMOVE | t.SWP_NOSIZE | t.SWP_NOZORDER | t.SWP_NOACTIVATE | t.SWP_FRAMECHANGED,
                );
            }
        } else {
            if ((ex_style & t.WS_EX_LAYERED) == 0) {
                _ = t.SetWindowLongPtrW(self.hwnd, t.GWL_EXSTYLE, ex_style | t.WS_EX_LAYERED);
                _ = t.SetWindowPos(
                    self.hwnd,
                    null,
                    0,
                    0,
                    0,
                    0,
                    t.SWP_NOMOVE | t.SWP_NOSIZE | t.SWP_NOZORDER | t.SWP_NOACTIVATE | t.SWP_FRAMECHANGED,
                );
            }
            _ = t.SetLayeredWindowAttributes(self.hwnd, 0, new_alpha, t.LWA_ALPHA);
        }
    }

    pub fn close(self: Window) void {
        _ = t.PostMessageW(self.hwnd, t.WM_CLOSE, 0, 0);
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
