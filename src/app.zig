const std = @import("std");
const t = @import("platform/win32.zig");
const geom = @import("calc/geometry.zig");
const Paths = @import("platform/paths.zig").Paths;
const Window = @import("platform/window.zig").Window;
const Config = @import("domain/config.zig").Config;
const UserIntent = @import("domain/intent.zig").UserIntent;
const WindowTarget = @import("domain/window_target.zig").WindowTarget;
const Logger = @import("infra/logger.zig").Logger;
const logger = @import("infra/logger.zig");
const WindowWorker = @import("infra/worker.zig").WindowWorker;
const ConfigWatcher = @import("infra/watcher.zig").ConfigWatcher;
const ConfigStore = @import("infra/config_store.zig").ConfigStore;
const BorderManager = @import("wm/border.zig").BorderManager;
const GestureStateMachine = @import("input/gesture.zig").GestureStateMachine;
const InputEngine = @import("input/engine.zig").InputEngine;
const Autostart = @import("platform/autostart.zig").Autostart;
const I18n = @import("infra/i18n.zig").I18n;

const CMD_TOGGLE_PAUSE: usize = 1001;
const CMD_TOGGLE_BORDER: usize = 1002;
const CMD_TOGGLE_AUTOSTART: usize = 1003;
const CMD_RELOAD_CONFIG: usize = 1004;
const CMD_OPEN_CONFIG_DIR: usize = 1005;
const CMD_OPEN_LOG_DIR: usize = 1006;
const CMD_EXIT: usize = 1007;
const CMD_RESTART: usize = 1008;

const TIMER_BORDER_REINFORCE: usize = 2001;

pub const App = struct {
    allocator: std.mem.Allocator,
    config: Config,
    logger_inst: Logger,
    worker: WindowWorker,
    border_mgr: BorderManager,
    gesture: GestureStateMachine,
    hook_engine: InputEngine,
    watcher: ConfigWatcher = .{},
    main_hwnd: ?t.HWND = null,
    single_instance_mutex: ?t.HANDLE = null,
    nid: t.NOTIFYICONDATAW = undefined,
    last_config_write_ms: u64 = 0,
    current_session_id: u64 = 0,
    hicon_enabled: ?t.HICON = null,
    hicon_disabled: ?t.HICON = null,

    fg_hook: ?t.HWINEVENTHOOK = null,
    obj_hook: ?t.HWINEVENTHOOK = null,

    pub var global: ?*App = null;

    pub fn init(allocator: std.mem.Allocator) !*App {
        const self = try allocator.create(App);
        errdefer allocator.destroy(self);

        const config = ConfigStore.load(allocator);
        const logger_inst = Logger.init(allocator, config.log_max_days);

        self.* = .{
            .allocator = allocator,
            .config = config,
            .logger_inst = logger_inst,
            .worker = .{},
            .border_mgr = undefined,
            .gesture = undefined,
            .hook_engine = undefined,
        };
        Logger.global = &self.logger_inst;
        logger.info("App", "zwin starting...", .{});

        self.border_mgr = BorderManager.init(&self.config);
        self.gesture = GestureStateMachine.init(&self.worker, &self.config);
        self.hook_engine = InputEngine.init(&self.gesture, &self.config);

        App.global = self;
        return self;
    }

    pub fn start(self: *App, hinst: ?t.HINSTANCE) !void {
        self.current_session_id = self.worker.invalidateSession();
        try self.createMessageWindow(hinst);
        try self.worker.start();
        try self.hook_engine.install(hinst, self.main_hwnd.?);
        try self.watcher.start(self.allocator, self.main_hwnd.?);

        Autostart.setEnabled(self.config.enable_autostart);

        self.fg_hook = t.SetWinEventHook(t.EVENT_SYSTEM_FOREGROUND, t.EVENT_SYSTEM_MINIMIZEEND, null, winEventCallback, 0, 0, t.WINEVENT_OUTOFCONTEXT);
        self.obj_hook = t.SetWinEventHook(t.EVENT_OBJECT_DESTROY, t.EVENT_OBJECT_HIDE, null, winEventCallback, 0, 0, t.WINEVENT_OUTOFCONTEXT);
        self.initTrayIcon(hinst);

        self.refreshActiveBorder();
        logger.info("App", "zwin runtime ready", .{});
    }

    pub fn deinit(self: *App) void {
        logger.info("App", "zwin shutting down...", .{});
        _ = t.Shell_NotifyIconW(t.NIM_DELETE, &self.nid);

        if (self.fg_hook) |h| _ = t.UnhookWinEvent(h);
        if (self.obj_hook) |h| _ = t.UnhookWinEvent(h);

        self.watcher.stop();
        self.hook_engine.uninstall();
        self.worker.stop();
        self.border_mgr.reset();

        if (self.main_hwnd) |hwnd| {
            _ = t.KillTimer(hwnd, TIMER_BORDER_REINFORCE);
            _ = t.DestroyWindow(hwnd);
        }

        if (self.single_instance_mutex) |m| {
            _ = t.CloseHandle(m);
            self.single_instance_mutex = null;
        }

        Logger.global = null;
        self.logger_inst.deinit();
        self.allocator.destroy(self);
    }

    pub fn restart(self: *App) void {
        logger.info("App", "restarting zwin instance...", .{});
        var path_buf: [1024]u16 = undefined;
        const len = t.GetModuleFileNameW(null, &path_buf, path_buf.len);
        if (len == 0 or len >= path_buf.len) {
            logger.err("App", "failed to get module path for restart", .{});
            return;
        }

        // Release the mutex BEFORE spawning the successor, or the new
        // process sees ERROR_ALREADY_EXISTS and exits instantly.
        if (self.single_instance_mutex) |m| {
            _ = t.CloseHandle(m);
            self.single_instance_mutex = null;
        }

        const res = t.ShellExecuteW(null, std.unicode.utf8ToUtf16LeStringLiteral("open"), path_buf[0..len :0].ptr, null, null, 1);
        if (@intFromPtr(res) <= 32) {
            logger.err("App", "ShellExecuteW failed gle={d}", .{t.GetLastError()});
            return;
        }
        _ = t.PostQuitMessage(0);
    }

    pub fn reloadConfig(self: *App) void {
        logger.info("App", "reloading config from disk", .{});
        const prev_autostart = self.config.enable_autostart;
        self.config = ConfigStore.load(self.allocator);
        if (self.config.enable_autostart != prev_autostart) {
            Autostart.setEnabled(self.config.enable_autostart);
        }
        self.updateTrayState(self.hook_engine.paused.load(.acquire));
        self.refreshActiveBorder();
    }

    pub fn saveConfig(self: *App) void {
        ConfigStore.save(self.allocator, &self.config);
        self.last_config_write_ms = t.GetTickCount64();
    }

    pub fn setPaused(self: *App, paused: bool) void {
        self.hook_engine.paused.store(paused, .release);
        self.updateTrayState(paused);
    }

    pub fn scheduleBorderReinforce(self: *App) void {
        if (self.main_hwnd) |hwnd| {
            _ = t.SetTimer(hwnd, TIMER_BORDER_REINFORCE, 60, null);
        }
    }

    /// Single dispatch point for all user intents. Runs on the main thread
    /// only; hooks never resolve targets or compute geometry themselves.
    pub fn handleIntent(self: *App, intent: UserIntent) void {
        switch (intent) {
            .center_active_window => {
                const target = self.resolveActiveTarget() orelse return;
                const win = Window.init(target.hwnd);
                win.ensureRestored();
                if (win.getMonitorWorkArea()) |wa| {
                    const bounds = win.getPhysicalBounds();
                    const pad = win.getShadowPadding();
                    const centered = geom.calculateCenterRect(wa, bounds, pad);
                    self.worker.postDiscrete(target, .{ .set_bounds = .{
                        .x = centered.left,
                        .y = centered.top,
                        .w = centered.width(),
                        .h = centered.height(),
                    } });
                }
            },
            .toggle_active_topmost => {
                const target = self.resolveActiveTarget() orelse return;
                const ex_style = t.GetWindowLongPtrW(target.hwnd, t.GWL_EXSTYLE);
                const is_topmost = (ex_style & t.WS_EX_TOPMOST) != 0;
                self.worker.postDiscrete(target, .{
                    .set_topmost = .{ .is_topmost = !is_topmost },
                });
            },
            .close_active_window => {
                const target = self.resolveActiveTarget() orelse return;
                Window.init(target.hwnd).close();
            },
            // Drag/resize starts are NOT intents: they must begin
            // synchronously with the physical button press inside the mouse
            // hook (see engine.zig), or a fast click's button-up overtakes
            // the async dispatch and strands the gesture state machine.
            .minimize_at => |m| {
                const target = self.resolveTargetAtPoint(m.pt) orelse return;
                Window.init(target.hwnd).minimize();
            },
            .adjust_opacity_at => |op| {
                // Wheel over window edges/DComp surfaces can miss; fall back
                // to the active top-level so the gesture never dead-ends.
                const target = self.resolveTargetAtPoint(op.pt) orelse self.resolveActiveTarget() orelse return;
                Window.init(target.hwnd).adjustOpacity(op.delta);
            },
        }
    }

    fn resolveActiveTarget(self: *App) ?WindowTarget {
        const raw_fg = t.GetForegroundWindow() orelse return null;
        const top = Window.getTrueTopLevel(raw_fg) orelse return null;
        const win = Window.init(top);
        if (win.isExclusiveFullScreen()) return null;
        return .{ .hwnd = top, .session_id = self.current_session_id };
    }

    fn resolveTargetAtPoint(self: *App, pt: geom.Point) ?WindowTarget {
        const raw_hwnd = t.WindowFromPoint(.{ .x = pt.x, .y = pt.y }) orelse return null;
        const top = Window.getTrueTopLevel(raw_hwnd) orelse return null;
        const win = Window.init(top);
        if (win.isExclusiveFullScreen()) return null;
        return .{ .hwnd = top, .session_id = self.current_session_id };
    }

    fn refreshActiveBorder(self: *App) void {
        if (t.GetForegroundWindow()) |fg| {
            self.border_mgr.onFocusChange(fg);
            self.scheduleBorderReinforce();
        }
    }

    fn createMessageWindow(self: *App, hinst: ?t.HINSTANCE) !void {
        const class_name = std.unicode.utf8ToUtf16LeStringLiteral("zwin_MsgWindow");

        const wnd_class = t.WNDCLASSEXW{
            .lpfnWndProc = appWndProc,
            .hInstance = hinst,
            .lpszClassName = class_name,
        };
        _ = t.RegisterClassExW(&wnd_class);

        self.main_hwnd = t.CreateWindowExW(
            0,
            class_name,
            class_name,
            0,
            0,
            0,
            0,
            0,
            null,
            null,
            hinst,
            null,
        ) orelse return error.WindowCreationFailed;
    }

    fn intResource(id: usize) ?[*:0]const u16 {
        var v = id;
        _ = &v;
        return @ptrFromInt(v);
    }

    fn initTrayIcon(self: *App, hinst: ?t.HINSTANCE) void {
        const hwnd = self.main_hwnd orelse return;
        self.hicon_enabled = t.LoadIconW(hinst, intResource(3)) orelse t.LoadIconW(null, intResource(32512));
        self.hicon_disabled = t.LoadIconW(hinst, intResource(2)) orelse t.LoadIconW(null, intResource(32515));
        const is_paused = self.hook_engine.paused.load(.acquire);
        self.nid = .{
            .hWnd = hwnd,
            .uID = 1,
            .uFlags = t.NIF_MESSAGE | t.NIF_ICON | t.NIF_TIP,
            .uCallbackMessage = t.WM_TRAY,
            .hIcon = if (is_paused) self.hicon_disabled else self.hicon_enabled,
        };
        const ok = t.Shell_NotifyIconW(t.NIM_ADD, &self.nid);
        if (ok == 0) {
            logger.err("App", "Shell_NotifyIconW(NIM_ADD) failed gle={d}", .{t.GetLastError()});
        } else {
            logger.info("App", "tray icon added", .{});
        }
        self.updateTrayState(is_paused);
    }

    pub fn updateTrayState(self: *App, is_paused: bool) void {
        const strings = I18n.getStrings(self.config.language);
        const tip = if (is_paused) strings.tray_paused else strings.tray_running;

        var len: usize = 0;
        while (len < self.nid.szTip.len - 1 and tip[len] != 0) : (len += 1) {}
        @memcpy(self.nid.szTip[0..len], tip[0..len]);
        self.nid.szTip[len] = 0;

        self.nid.hIcon = if (is_paused) self.hicon_disabled else self.hicon_enabled;
        self.nid.uFlags = t.NIF_ICON | t.NIF_TIP;
        if (t.Shell_NotifyIconW(t.NIM_MODIFY, &self.nid) == 0) {
            logger.warn("App", "Shell_NotifyIconW(NIM_MODIFY) failed gle={d}", .{t.GetLastError()});
        }
    }
};

fn winEventCallback(_: t.HWINEVENTHOOK, event: u32, hwnd: t.HWND, idObject: i32, idChild: i32, _: u32, _: u32) callconv(.winapi) void {
    if (idObject != t.OBJID_WINDOW or idChild != 0) return;
    const app = App.global orelse return;

    switch (event) {
        t.EVENT_SYSTEM_FOREGROUND => {
            const target = if (@intFromPtr(hwnd) != 0) hwnd else (t.GetForegroundWindow() orelse return);
            app.border_mgr.onFocusChange(target);
            app.scheduleBorderReinforce();
        },
        t.EVENT_OBJECT_SHOW, t.EVENT_SYSTEM_MINIMIZEEND => app.refreshActiveBorder(),
        t.EVENT_OBJECT_DESTROY, t.EVENT_OBJECT_HIDE, t.EVENT_SYSTEM_MINIMIZESTART => {
            app.border_mgr.onWindowClosedOrHidden(hwnd);
            app.refreshActiveBorder();
        },
        else => {},
    }
}

fn appWndProc(hwnd: t.HWND, msg: u32, wParam: t.WPARAM, lParam: t.LPARAM) callconv(.winapi) t.LRESULT {
    const app = App.global orelse return t.DefWindowProcW(hwnd, msg, wParam, lParam);

    switch (msg) {
        t.WM_TRAY => {
            logger.debug("Tray", "event wParam={x} lParam={x}", .{ wParam, lParam });
            const event_msg: u32 = @truncate(@as(usize, @bitCast(lParam)));
            if (event_msg == t.WM_LBUTTONDBLCLK) {
                const current = app.hook_engine.paused.load(.acquire);
                app.setPaused(!current);
            } else if (event_msg == t.WM_RBUTTONUP or event_msg == t.WM_CONTEXTMENU) {
                var cursor_pt: t.POINT = undefined;
                _ = t.GetCursorPos(&cursor_pt);

                const menu = t.CreatePopupMenu() orelse return 0;
                defer _ = t.DestroyMenu(menu);

                const strings = I18n.getStrings(app.config.language);

                const pause_flags = t.MF_STRING | (if (app.hook_engine.paused.load(.acquire)) t.MF_CHECKED else t.MF_UNCHECKED);
                const border_flags = t.MF_STRING | (if (app.config.enable_border) t.MF_CHECKED else t.MF_UNCHECKED);
                const autostart_flags = t.MF_STRING | (if (app.config.enable_autostart) t.MF_CHECKED else t.MF_UNCHECKED);

                _ = t.AppendMenuW(menu, pause_flags, CMD_TOGGLE_PAUSE, strings.menu_pause);
                _ = t.AppendMenuW(menu, border_flags, CMD_TOGGLE_BORDER, strings.menu_border);
                _ = t.AppendMenuW(menu, autostart_flags, CMD_TOGGLE_AUTOSTART, strings.menu_autostart);
                _ = t.AppendMenuW(menu, t.MF_SEPARATOR, 0, null);
                _ = t.AppendMenuW(menu, t.MF_STRING, CMD_RELOAD_CONFIG, strings.menu_reload);
                _ = t.AppendMenuW(menu, t.MF_STRING, CMD_OPEN_CONFIG_DIR, strings.menu_open_config);
                _ = t.AppendMenuW(menu, t.MF_STRING, CMD_OPEN_LOG_DIR, strings.menu_open_log);
                _ = t.AppendMenuW(menu, t.MF_SEPARATOR, 0, null);
                _ = t.AppendMenuW(menu, t.MF_STRING, CMD_RESTART, strings.menu_restart);
                _ = t.AppendMenuW(menu, t.MF_STRING, CMD_EXIT, strings.menu_exit);

                _ = t.SetForegroundWindow(hwnd);
                _ = t.TrackPopupMenu(menu, t.TPM_RIGHTBUTTON, cursor_pt.x, cursor_pt.y, 0, hwnd, null);
                _ = t.PostMessageW(hwnd, t.WM_NULL, 0, 0);
            }
        },
        t.WM_COMMAND => {
            switch (wParam & 0xFFFF) {
                CMD_TOGGLE_PAUSE => {
                    app.setPaused(!app.hook_engine.paused.load(.acquire));
                },
                CMD_TOGGLE_BORDER => {
                    app.config.enable_border = !app.config.enable_border;
                    if (t.GetForegroundWindow()) |current_fg| {
                        app.border_mgr.onFocusChange(current_fg);
                    }
                    app.saveConfig();
                },
                CMD_TOGGLE_AUTOSTART => {
                    app.config.enable_autostart = !app.config.enable_autostart;
                    Autostart.setEnabled(app.config.enable_autostart);
                    app.saveConfig();
                },
                CMD_RELOAD_CONFIG => app.reloadConfig(),
                CMD_OPEN_CONFIG_DIR => openDirInExplorer(app, .config),
                CMD_OPEN_LOG_DIR => openDirInExplorer(app, .log),
                CMD_RESTART => app.restart(),
                CMD_EXIT => _ = t.PostQuitMessage(0),
                else => {
                    logger.warn("Tray", "unhandled command id={d}", .{wParam & 0xFFFF});
                },
            }
        },
        t.WM_TIMER => {
            if (wParam == TIMER_BORDER_REINFORCE) {
                _ = t.KillTimer(hwnd, TIMER_BORDER_REINFORCE);
                if (t.GetForegroundWindow()) |current_fg| {
                    app.border_mgr.refreshCurrent(current_fg);
                }
            }
        },
        t.WM_APP_EVENT => {
            const event: u32 = @intCast(wParam);
            // Skip the echo of our own saveConfig write; manual edits still reload.
            if (event == ConfigWatcher.CONFIG_CHANGED_EVENT and
                t.GetTickCount64() - app.last_config_write_ms >= 300)
            {
                app.reloadConfig();
            }
        },
        t.WM_APP_INTENT => {
            while (app.hook_engine.nextIntent()) |intent| {
                app.handleIntent(intent);
            }
        },
        else => return t.DefWindowProcW(hwnd, msg, wParam, lParam),
    }
    return 0;
}

fn openDirInExplorer(app: *App, kind: enum { config, log }) void {
    const dir = if (kind == .config)
        Paths.getConfigDir(app.allocator)
    else
        Paths.getLogDir(app.allocator);
    if (dir) |d| {
        defer app.allocator.free(d);
        Paths.openFolderInExplorer(app.allocator, d);
    } else |_| {}
}
