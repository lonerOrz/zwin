const std = @import("std");
const t = @import("../platform/win32.zig");
const geom = @import("../calc/geometry.zig");
const I18n = @import("../infra/i18n.zig").I18n;
const Language = @import("../infra/i18n.zig").Language;

const OSD_WIDTH: i32 = 180;
const OSD_HEIGHT: i32 = 44;
const TIMER_OSD_AUTOHIDE: usize = 3001;

pub const OsdKind = enum {
    none,
    resize,
    opacity,
    topmost,
};

pub const OsdManager = struct {
    hwnd: ?t.HWND = null,
    visible: bool = false,
    text_buf: [64:0]u16 = undefined,
    text_len: usize = 0,
    font: ?t.HFONT = null,
    kind: OsdKind = .none,
    bg_brush: ?t.HBRUSH = null,

    pub fn init(hinst: ?t.HINSTANCE) OsdManager {
        var self = OsdManager{};
        self.createWindow(hinst);
        self.font = t.CreateFontW(
            -16,
            0,
            0,
            0,
            600,
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
        self.bg_brush = t.CreateSolidBrush(0x001A1A1A);
        return self;
    }

    pub fn deinit(self: *OsdManager) void {
        if (self.hwnd) |hwnd| {
            _ = t.KillTimer(hwnd, TIMER_OSD_AUTOHIDE);
            _ = t.DestroyWindow(hwnd);
        }
        if (self.font) |f| _ = t.DeleteObject(f);
        if (self.bg_brush) |b| _ = t.DeleteObject(b);
        self.* = undefined;
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
            t.WS_EX_TOPMOST | t.WS_EX_TOOLWINDOW | t.WS_EX_LAYERED | t.WS_EX_TRANSPARENT | t.WS_EX_NOACTIVATE,
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
            null,
        );

        if (self.hwnd) |hwnd| {
            _ = t.SetLayeredWindowAttributes(hwnd, 0, 225, t.LWA_ALPHA);
        }
    }

    pub fn showResize(self: *OsdManager, cursor: geom.Point, w: i32, h: i32) void {
        var buf: [32]u8 = undefined;
        const u8_str = std.fmt.bufPrint(&buf, "{d} × {d}", .{ w, h }) catch return;
        self.setText(u8_str);
        self.kind = .resize;
        self.repositionAndShow(cursor.x + 20, cursor.y + 20, false);
    }

    pub fn showOpacity(self: *OsdManager, cursor: geom.Point, alpha: u8, lang: Language) void {
        const percent = @divTrunc(@as(u32, alpha) * 100, 255);
        const strings = I18n.getStrings(lang);
        _ = strings; // unused directly, used for language detection

        var buf_u8: [64]u8 = undefined;
        const label = if (lang == .zh_CN or I18n.resolveLanguage(lang) == .zh_CN)
            std.fmt.bufPrint(&buf_u8, "透明度: {d}%", .{percent}) catch return
        else
            std.fmt.bufPrint(&buf_u8, "Opacity: {d}%", .{percent}) catch return;

        self.setText(label);
        self.kind = .opacity;
        self.repositionAndShow(cursor.x + 20, cursor.y + 20, true);
    }

    pub fn showTopmost(self: *OsdManager, is_topmost: bool, lang: Language) void {
        var cursor: t.POINT = undefined;
        _ = t.GetCursorPos(&cursor);

        const is_zh = (lang == .zh_CN or I18n.resolveLanguage(lang) == .zh_CN);
        const text = if (is_zh)
            (if (is_topmost) "📌 窗口置顶: 开启" else "窗口置顶: 关闭")
        else
            (if (is_topmost) "📌 Topmost: ON" else "Topmost: OFF");

        self.setText(text);
        self.kind = .topmost;
        self.repositionAndShow(cursor.x + 20, cursor.y + 20, true);
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

    fn repositionAndShow(self: *OsdManager, x: i32, y: i32, auto_hide: bool) void {
        const hwnd = self.hwnd orelse return;

        _ = t.SetWindowPos(
            hwnd,
            t.HWND_TOPMOST,
            x,
            y,
            OSD_WIDTH,
            OSD_HEIGHT,
            t.SWP_NOACTIVATE | t.SWP_SHOWWINDOW,
        );
        _ = t.InvalidateRect(hwnd, null, 1);
        self.visible = true;

        _ = t.KillTimer(hwnd, TIMER_OSD_AUTOHIDE);
        if (auto_hide) {
            _ = t.SetTimer(hwnd, TIMER_OSD_AUTOHIDE, 1200, null);
        }
    }
};

fn osdWndProc(hwnd: t.HWND, msg: u32, wParam: t.WPARAM, lParam: t.LPARAM) callconv(.winapi) t.LRESULT {
    switch (msg) {
        t.WM_TIMER => {
            if (wParam == TIMER_OSD_AUTOHIDE) {
                _ = t.KillTimer(hwnd, TIMER_OSD_AUTOHIDE);
                _ = t.ShowWindow(hwnd, 0);
            }
        },
        t.WM_PAINT => {
            var ps: t.PAINTSTRUCT = undefined;
            const hdc = t.BeginPaint(hwnd, &ps) orelse return 0;
            defer _ = t.EndPaint(hwnd, &ps);

            const app_ptr = @import("../app.zig").App.global;
            const osd = if (app_ptr) |a| &a.osd else return 0;

            const rect = t.RECT{ .left = 0, .top = 0, .right = OSD_WIDTH, .bottom = OSD_HEIGHT };
            if (osd.bg_brush) |brush| {
                const old_brush = t.SelectObject(hdc, brush);
                defer if (old_brush) |ob| {
                    _ = t.SelectObject(hdc, ob);
                };

                if (t.CreatePen(0, 1, 0x003A3A3A)) |pen| {
                    defer _ = t.DeleteObject(pen);
                    const old_pen = t.SelectObject(hdc, pen);
                    defer if (old_pen) |op| {
                        _ = t.SelectObject(hdc, op);
                    };

                    _ = t.RoundRect(hdc, 0, 0, OSD_WIDTH, OSD_HEIGHT, 14, 14);
                }
            }

            _ = t.SetBkMode(hdc, t.TRANSPARENT);
            _ = t.SetTextColor(hdc, 0x00F0F0F0);

            if (osd.font) |f| {
                const old_font = t.SelectObject(hdc, f);
                defer if (old_font) |of| {
                    _ = t.SelectObject(hdc, of);
                };
                var rc_text = rect;
                _ = t.DrawTextW(hdc, &osd.text_buf, @intCast(osd.text_len), &rc_text, t.DT_CENTER | t.DT_VCENTER | t.DT_SINGLELINE);
            }
            return 0;
        },
        else => return t.DefWindowProcW(hwnd, msg, wParam, lParam),
    }
    return 0;
}
