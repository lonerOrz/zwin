const std = @import("std");
const t = @import("../platform/win32.zig");
const geom = @import("../calc/geometry.zig");
const Language = @import("../infra/i18n.zig").Language;
const I18n = @import("../infra/i18n.zig").I18n;

const OSD_WIDTH: i32 = 260;
const OSD_HEIGHT: i32 = 48;
const TIMER_OSD_AUTOHIDE: usize = 3001;

// Transparent color key for pure text HUD (RGB 1, 1, 1)
const TRANSPARENT_KEY: u32 = 0x00010101;

pub const OsdKind = enum {
    none,
    resize,
    opacity,
    topmost,
    passthrough,
};

pub const OsdManager = struct {
    hwnd: ?t.HWND = null,
    visible: bool = false,
    text_buf: [64:0]u16 = undefined,
    text_len: usize = 0,
    font: ?t.HFONT = null,
    kind: OsdKind = .none,
    bg_brush: ?t.HBRUSH = null,

    // In-place init: `self` is a stable pointer owned by App, stored in GWLP_USERDATA
    pub fn init(self: *OsdManager, hinst: ?t.HINSTANCE) void {
        self.* = .{};
        self.createWindow(hinst);

        // High-contrast clean font
        self.font = t.CreateFontW(
            -18,
            0,
            0,
            0,
            700,
            0,
            0,
            0,
            t.DEFAULT_CHARSET,
            t.OUT_DEFAULT_PRECIS,
            t.CLIP_DEFAULT_PRECIS,
            t.CLEARTYPE_QUALITY,
            t.DEFAULT_PITCH | t.FF_DONTCARE,
            std.unicode.utf8ToUtf16LeStringLiteral("Segoe UI"),
        );

        self.bg_brush = t.CreateSolidBrush(TRANSPARENT_KEY);
    }

    pub fn deinit(self: *OsdManager) void {
        if (self.hwnd) |hwnd| {
            _ = t.KillTimer(hwnd, TIMER_OSD_AUTOHIDE);
            _ = t.DestroyWindow(hwnd);
            self.hwnd = null;
        }
        if (self.font) |f| {
            _ = t.DeleteObject(f);
            self.font = null;
        }
        if (self.bg_brush) |b| {
            _ = t.DeleteObject(b);
            self.bg_brush = null;
        }
    }

    fn createWindow(self: *OsdManager, hinst: ?t.HINSTANCE) void {
        const class_name = std.unicode.utf8ToUtf16LeStringLiteral("zwin_OsdWindow");
        const wnd_class = t.WNDCLASSEXW{
            .lpfnWndProc = osdWndProc,
            .hInstance = hinst,
            .lpszClassName = class_name,
        };
        _ = t.RegisterClassExW(&wnd_class);

        self.hwnd = t.CreateWindowExW(
            t.WS_EX_TOPMOST | t.WS_EX_TOOLWINDOW | t.WS_EX_LAYERED | t.WS_EX_NOACTIVATE,
            class_name,
            class_name,
            t.WS_POPUP,
            0,
            0,
            OSD_WIDTH,
            OSD_HEIGHT,
            null,
            null,
            hinst,
            @ptrCast(self),
        );

        if (self.hwnd) |hwnd| {
            // Cut out background color completely
            _ = t.SetLayeredWindowAttributes(hwnd, TRANSPARENT_KEY, 0, t.LWA_COLORKEY);
        }
    }

    pub fn showResize(self: *OsdManager, cursor: geom.Point, w: i32, h: i32) void {
        var buf: [32]u8 = undefined;
        const u8_str = std.fmt.bufPrint(&buf, "{d} × {d}", .{ w, h }) catch return;
        self.setText(u8_str);
        self.kind = .resize;
        self.repositionAndShow(cursor.x + 20, cursor.y + 20, 0);
    }

    pub fn showOpacity(self: *OsdManager, cursor: geom.Point, alpha: u8, lang: Language) void {
        const percent = @divTrunc(@as(u32, alpha) * 100, 255);
        var buf: [64]u8 = undefined;
        const formatted = I18n.formatOpacity(lang, &buf, percent) orelse return;
        self.setText(formatted);
        self.kind = .opacity;
        self.repositionAndShow(cursor.x + 20, cursor.y + 20, 1500);
    }

    pub fn showTopmost(self: *OsdManager, is_topmost: bool, lang: Language) void {
        const strings = I18n.getStrings(lang);
        self.setWideText(if (is_topmost) strings.osd_topmost_on else strings.osd_topmost_off);
        self.kind = .topmost;
        var cursor: t.POINT = undefined;
        _ = t.GetCursorPos(&cursor);
        self.repositionAndShow(cursor.x + 20, cursor.y + 20, 1500);
    }

    pub fn showPassthrough(self: *OsdManager, is_passthrough: bool, lang: Language) void {
        const strings = I18n.getStrings(lang);
        self.setWideText(if (is_passthrough) strings.osd_passthrough_on else strings.osd_passthrough_off);
        self.kind = .passthrough;
        var cursor: t.POINT = undefined;
        _ = t.GetCursorPos(&cursor);
        self.repositionAndShow(cursor.x + 20, cursor.y + 20, 1500);
    }

    pub fn hide(self: *OsdManager) void {
        const hwnd = self.hwnd orelse return;
        if (self.visible) {
            _ = t.ShowWindow(hwnd, 0);
            self.visible = false;
            self.kind = .none;
        }
    }

    fn setText(self: *OsdManager, text_u8: []const u8) void {
        const len = std.unicode.utf8ToUtf16Le(&self.text_buf, text_u8) catch return;
        self.text_buf[len] = 0;
        self.text_len = len;
    }

    fn setWideText(self: *OsdManager, text_w: [*:0]const u16) void {
        var len: usize = 0;
        while (len < self.text_buf.len - 1 and text_w[len] != 0) : (len += 1) {
            self.text_buf[len] = text_w[len];
        }
        self.text_buf[len] = 0;
        self.text_len = len;
    }

    fn repositionAndShow(self: *OsdManager, x: i32, y: i32, auto_hide_ms: u32) void {
        const hwnd = self.hwnd orelse return;

        // Force to top of Z-order with SWP_FRAMECHANGED
        _ = t.SetWindowPos(
            hwnd,
            t.HWND_TOPMOST,
            x,
            y,
            OSD_WIDTH,
            OSD_HEIGHT,
            t.SWP_NOACTIVATE | t.SWP_SHOWWINDOW | t.SWP_NOSIZE | t.SWP_NOZORDER,
        );
        _ = t.InvalidateRect(hwnd, null, 0);
        self.visible = true;

        _ = t.KillTimer(hwnd, TIMER_OSD_AUTOHIDE);
        if (auto_hide_ms > 0) {
            _ = t.SetTimer(hwnd, TIMER_OSD_AUTOHIDE, auto_hide_ms, null);
        }
    }
};

fn osdWndProc(hwnd: t.HWND, msg: u32, wParam: t.WPARAM, lParam: t.LPARAM) callconv(.winapi) t.LRESULT {
    if (msg == t.WM_NCCREATE) {
        const cs: *const t.CREATESTRUCTW = @ptrFromInt(@as(usize, @bitCast(lParam)));
        if (cs.lpCreateParams) |ptr| {
            _ = t.SetWindowLongPtrW(hwnd, t.GWLP_USERDATA, @as(isize, @bitCast(@intFromPtr(ptr))));
        }
    }

    const osd_ptr = t.GetWindowLongPtrW(hwnd, t.GWLP_USERDATA);
    if (osd_ptr == 0) return t.DefWindowProcW(hwnd, msg, wParam, lParam);
    const osd: *OsdManager = @ptrFromInt(@as(usize, @bitCast(osd_ptr)));

    switch (msg) {
        t.WM_TIMER => {
            if (wParam == TIMER_OSD_AUTOHIDE) {
                _ = t.KillTimer(hwnd, TIMER_OSD_AUTOHIDE);
                _ = t.ShowWindow(hwnd, 0);
                osd.visible = false;
            }
        },
        t.WM_PAINT => {
            var ps: t.PAINTSTRUCT = undefined;
            const hdc = t.BeginPaint(hwnd, &ps) orelse return 0;
            defer _ = t.EndPaint(hwnd, &ps);

            // Fill entire rect with color key brush (borderless transparent cutout)
            if (osd.bg_brush) |brush| {
                const rc_full = t.RECT{ .left = 0, .top = 0, .right = OSD_WIDTH, .bottom = OSD_HEIGHT };
                _ = t.FillRect(hdc, &rc_full, brush);
            }

            _ = t.SetBkMode(hdc, t.TRANSPARENT);

            // Draw text with drop shadow
            if (osd.font) |f| {
                const old_font = t.SelectObject(hdc, f);
                defer if (old_font) |of| {
                    _ = t.SelectObject(hdc, of);
                };

                // Drop shadow for legibility on white backgrounds
                _ = t.SetTextColor(hdc, 0x00000000);
                var rc_shadow = t.RECT{ .left = 2, .top = 2, .right = OSD_WIDTH + 2, .bottom = OSD_HEIGHT + 2 };
                _ = t.DrawTextW(hdc, &osd.text_buf, @intCast(osd.text_len), &rc_shadow, t.DT_CENTER | t.DT_VCENTER | t.DT_SINGLELINE);

                // High-contrast foreground text
                _ = t.SetTextColor(hdc, 0x00FFFFFF);
                var rc_text = t.RECT{ .left = 0, .top = 0, .right = OSD_WIDTH, .bottom = OSD_HEIGHT };
                _ = t.DrawTextW(hdc, &osd.text_buf, @intCast(osd.text_len), &rc_text, t.DT_CENTER | t.DT_VCENTER | t.DT_SINGLELINE);
            }
            return 0;
        },
        else => return t.DefWindowProcW(hwnd, msg, wParam, lParam),
    }
    return 0;
}
