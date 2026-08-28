const std = @import("std");
const t = @import("win32.zig");
const geom = @import("../calc/geometry.zig");
const Config = @import("../domain/config.zig").Config;

pub const Window = struct {
    hwnd: t.HWND,

    pub fn init(hwnd: t.HWND) Window {
        return .{ .hwnd = hwnd };
    }

    /// Queries the window class name into a fixed stack buffer.
    pub fn getClassName(self: Window, out_buf: *[256]u8) ?[]const u8 {
        var wbuf: [128]u16 = undefined;
        const len = t.GetClassNameW(self.hwnd, &wbuf, @intCast(wbuf.len));
        if (len <= 0) return null;
        const u8_len = std.unicode.utf16LeToUtf8(out_buf, wbuf[0..@intCast(len)]) catch return null;
        return out_buf[0..u8_len];
    }

    /// Queries the executable file name of the window's owning process.
    pub fn getProcessName(self: Window, out_buf: *[t.MAX_PATH]u8) ?[]const u8 {
        var pid: u32 = 0;
        _ = t.GetWindowThreadProcessId(self.hwnd, &pid);
        if (pid == 0) return null;

        const h_proc = t.OpenProcess(t.PROCESS_QUERY_LIMITED_INFORMATION, 0, pid) orelse return null;
        defer _ = t.CloseHandle(h_proc);

        var path_w: [t.MAX_PATH]u16 = undefined;
        var size: u32 = path_w.len;
        if (t.QueryFullProcessImageNameW(h_proc, 0, &path_w, &size) == 0 or size == 0) return null;

        var full_path_u8: [t.MAX_PATH * 3]u8 = undefined;
        const u8_len = std.unicode.utf16LeToUtf8(&full_path_u8, path_w[0..size]) catch return null;
        const full_path = full_path_u8[0..u8_len];

        const base = if (std.mem.lastIndexOfAny(u8, full_path, "\\/")) |pos| full_path[pos + 1 ..] else full_path;
        if (base.len == 0 or base.len > out_buf.len) return null;
        @memcpy(out_buf[0..base.len], base);
        return out_buf[0..base.len];
    }

    /// Checks whether the window matches any configured process or class blacklist pattern.
    pub fn isIgnored(self: Window, config: *const Config) bool {
        if (config.ignore_classes.len > 0) {
            var cls_buf: [256]u8 = undefined;
            if (self.getClassName(&cls_buf)) |cls| {
                for (config.ignore_classes) |pat| {
                    if (geom.matchGlob(pat, cls)) return true;
                }
            }
        }

        if (config.ignore_processes.len > 0) {
            var proc_buf: [t.MAX_PATH]u8 = undefined;
            if (self.getProcessName(&proc_buf)) |proc| {
                for (config.ignore_processes) |pat| {
                    if (geom.matchGlob(pat, proc)) return true;
                }
            }
        }

        return false;
    }

    // Context struct for zero-alloc window enumerations
    pub const SnapCollectorContext = struct {
        exclude_hwnd: t.HWND,
        config: *const Config,
        list: *geom.SnapTargetList,
    };

    pub fn collectSnapTargets(exclude_hwnd: t.HWND, config: *const Config, out_list: *geom.SnapTargetList) void {
        out_list.len = 0;
        var ctx = SnapCollectorContext{
            .exclude_hwnd = exclude_hwnd,
            .config = config,
            .list = out_list,
        };
        _ = t.EnumWindows(enumSnapProc, @as(t.LPARAM, @bitCast(@intFromPtr(&ctx))));
    }

    fn enumSnapProc(hwnd: t.HWND, lparam: t.LPARAM) callconv(.winapi) t.BOOL {
        const ctx: *SnapCollectorContext = @ptrFromInt(@as(usize, @bitCast(lparam)));
        if (hwnd == ctx.exclude_hwnd) return t.TRUE;
        if (t.IsWindowVisible(hwnd) == 0 or t.IsIconic(hwnd) != 0) return t.TRUE;

        const top = getTrueTopLevel(hwnd) orelse return t.TRUE;
        if (top != hwnd) return t.TRUE;

        const win = Window.init(top);
        if (win.isIgnored(ctx.config)) return t.TRUE;

        const bounds = win.getPhysicalBounds();
        if (bounds.width() > 50 and bounds.height() > 50) {
            ctx.list.append(bounds);
            if (ctx.list.len >= geom.max_snap_targets) return t.FALSE;
        }
        return t.TRUE;
    }

    // Directional focus navigation context
    pub const FocusContext = struct {
        cur_hwnd: t.HWND,
        cur_bounds: geom.Rect,
        dir: geom.Direction,
        config: *const Config,
        best_hwnd: ?t.HWND = null,
        best_score: i64 = std.math.maxInt(i64),
    };

    pub fn findDirectionalTarget(current_hwnd: t.HWND, dir: geom.Direction, config: *const Config) ?t.HWND {
        const cur_win = Window.init(current_hwnd);
        var ctx = FocusContext{
            .cur_hwnd = current_hwnd,
            .cur_bounds = cur_win.getPhysicalBounds(),
            .dir = dir,
            .config = config,
        };

        _ = t.EnumWindows(enumFocusProc, @as(t.LPARAM, @bitCast(@intFromPtr(&ctx))));
        return ctx.best_hwnd;
    }

    fn enumFocusProc(hwnd: t.HWND, lparam: t.LPARAM) callconv(.winapi) t.BOOL {
        const ctx: *FocusContext = @ptrFromInt(@as(usize, @bitCast(lparam)));
        if (hwnd == ctx.cur_hwnd) return t.TRUE;
        if (t.IsWindowVisible(hwnd) == 0 or t.IsIconic(hwnd) != 0) return t.TRUE;

        const top = getTrueTopLevel(hwnd) orelse return t.TRUE;
        if (top != hwnd) return t.TRUE;

        const win = Window.init(top);
        if (win.isIgnored(ctx.config)) return t.TRUE;

        const target_bounds = win.getPhysicalBounds();
        if (geom.scoreDirectionalCandidate(ctx.cur_bounds, target_bounds, ctx.dir)) |score| {
            if (score < ctx.best_score) {
                ctx.best_score = score;
                ctx.best_hwnd = top;
            }
        }
        return t.TRUE;
    }

    pub fn focusWindow(hwnd: t.HWND) void {
        _ = t.ShowWindow(hwnd, t.SW_RESTORE);
        _ = t.SetForegroundWindow(hwnd);
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

    pub fn toggleMaximize(self: Window) void {
        if (t.IsZoomed(self.hwnd) != 0) {
            _ = t.ShowWindow(self.hwnd, t.SW_RESTORE);
        } else {
            _ = t.ShowWindow(self.hwnd, t.SW_MAXIMIZE);
        }
    }

    pub fn isMinimized(self: Window) bool {
        return t.IsIconic(self.hwnd) != 0;
    }

    pub fn ensureRestored(self: Window) void {
        if (t.IsZoomed(self.hwnd) != 0) {
            _ = t.ShowWindow(self.hwnd, t.SW_RESTORE);
        }
    }
};
