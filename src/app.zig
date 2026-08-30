const std = @import("std");
const t = @import("platform/win32.zig");
const geom = @import("calc/geometry.zig");
const Paths = @import("platform/paths.zig").Paths;
const Window = @import("platform/window.zig").Window;
const Config = @import("domain/config.zig").Config;
const types = @import("domain/types.zig");
const UserIntent = types.UserIntent;
const WindowTarget = types.WindowTarget;
const logger = @import("infra/logger.zig");
const Logger = logger.Logger;
const WindowWorker = @import("infra/worker.zig").WindowWorker;
const ConfigWatcher = @import("infra/watcher.zig").ConfigWatcher;
const ConfigStore = @import("infra/config_store.zig").ConfigStore;
const BorderManager = @import("wm/border.zig").BorderManager;
const OsdManager = @import("wm/osd.zig").OsdManager;
const GestureStateMachine = @import("input/gesture.zig").GestureStateMachine;
const InputEngine = @import("input/engine.zig").InputEngine;
const IntentHandler = @import("wm/intent_handler.zig").IntentHandler;
const Autostart = @import("platform/autostart.zig").Autostart;
const I18n = @import("infra/i18n.zig").I18n;
const resources = @import("platform/resources.zig");

// Tray menu command IDs
const CMD_TOGGLE_PAUSE: usize = 1001;
const CMD_TOGGLE_BORDER: usize = 1002;
const CMD_TOGGLE_AUTOSTART: usize = 1003;
const CMD_RELOAD_CONFIG: usize = 1004;
const CMD_OPEN_CONFIG_DIR: usize = 1005;
const CMD_OPEN_LOG_DIR: usize = 1006;
const CMD_EXIT: usize = 1007;
const CMD_RESTART: usize = 1008;
const CMD_TOGGLE_ADMIN: usize = 1009;

// Timer IDs
const TIMER_BORDER_REINFORCE: usize = 2001;
const TIMER_REHOOK_WATCHDOG: usize = 2002;

pub const single_instance_mutex_name = std.unicode.utf8ToUtf16LeStringLiteral("zwin_SingleInstance_Mutex");
const elevation_task_name = "zwin";

pub const App = struct {
    allocator: std.mem.Allocator,
    config: Config,
    logger_inst: Logger,
    worker: WindowWorker,
    border_mgr: BorderManager,
    osd: OsdManager = undefined,
    gesture: GestureStateMachine,
    hook_engine: InputEngine,
    watcher: ConfigWatcher = .{},
    intent_handler: IntentHandler = undefined,

    // RAII platform resources
    msg_win: ?resources.MessageWindow = null,
    tray: ?resources.TrayIcon = null,
    win_hooks: ?resources.WinEventHooks = null,
    mutex: resources.SingleInstanceMutex = .{},

    last_config_write_ms: u64 = 0,
    quitting: bool = false,
    taskbar_created_msg: u32 = 0,
    watchdog_pt: t.POINT = .{ .x = 0, .y = 0 },

    pub var global: ?*App = null;

    pub fn init(allocator: std.mem.Allocator, config: Config) !*App {
        const self = try allocator.create(App);
        errdefer allocator.destroy(self);

        self.* = .{
            .allocator = allocator,
            .config = config,
            .logger_inst = Logger.init(allocator, config.log_retention_days),
            .worker = .{},
            .border_mgr = undefined,
            .gesture = undefined,
            .hook_engine = undefined,
        };
        Logger.global = &self.logger_inst;
        logger.info("App", "zwin starting...", .{});

        self.border_mgr = BorderManager.init(&self.config);
        self.gesture = GestureStateMachine.init(&self.worker, &self.config, &self.osd);
        self.intent_handler = IntentHandler.init(
            &self.worker,
            &self.border_mgr,
            &self.osd,
            &self.gesture,
            &self.config,
        );
        self.hook_engine = InputEngine.init(&self.gesture, &self.config, &self.intent_handler);

        App.global = self;
        return self;
    }

    pub fn start(self: *App, hinst: ?t.HINSTANCE) !void {
        // Boost scheduling priority to avoid LowLevelHooksTimeout under load
        _ = t.SetPriorityClass(t.GetCurrentProcess(), t.ABOVE_NORMAL_PRIORITY_CLASS);
        _ = t.SetThreadPriority(t.GetCurrentThread(), t.THREAD_PRIORITY_ABOVE_NORMAL);

        _ = self.worker.invalidateSession();

        self.osd.init(hinst);

        self.msg_win = try resources.MessageWindow.create(hinst, appWndProc);
        const hwnd = self.msg_win.?.hwnd;

        // Register TaskbarCreated and allow UIPI bypass when elevated
        self.taskbar_created_msg = t.RegisterWindowMessageW(std.unicode.utf8ToUtf16LeStringLiteral("TaskbarCreated"));
        if (self.taskbar_created_msg != 0 and self.isAdmin()) {
            _ = t.ChangeWindowMessageFilterEx(hwnd, self.taskbar_created_msg, t.MSGFLT_ALLOW, null);
        }

        try self.worker.start();
        try self.hook_engine.install(hinst, hwnd);
        try self.watcher.start(self.allocator, hwnd);

        // Arm watchdog timer to detect detached hooks
        self.msg_win.?.setTimer(TIMER_REHOOK_WATCHDOG, 5000);

        self.syncAutostartState();

        // Hook window lifecycle and foreground focus events
        self.win_hooks = resources.WinEventHooks.install(winEventCallback);

        self.tray = resources.TrayIcon.init(hwnd, hinst);
        if (!self.tray.?.addToTaskbar()) {
            logger.err("App", "Shell_NotifyIconW(NIM_ADD) failed gle={d}", .{t.GetLastError()});
        }
        self.updateTrayState(self.hook_engine.paused.load(.acquire));

        self.refreshActiveBorder();
        logger.info("App", "zwin runtime ready (elevated={})", .{self.isAdmin()});
    }

    pub fn deinit(self: *App) void {
        logger.info("App", "zwin shutting down...", .{});

        self.hook_engine.reportDroppedIntents();

        self.osd.deinit();

        if (self.tray) |*tr| tr.deinit();
        if (self.win_hooks) |*wh| wh.uninstall();

        self.watcher.stop();
        self.hook_engine.uninstall();
        self.worker.stop();
        self.border_mgr.reset();

        if (self.msg_win) |*mw| {
            mw.killTimer(TIMER_BORDER_REINFORCE);
            mw.killTimer(TIMER_REHOOK_WATCHDOG);
            mw.destroy();
        }

        self.mutex.release();
        self.config.deinit(self.allocator);

        Logger.global = null;
        self.logger_inst.deinit();
        self.allocator.destroy(self);
    }

    pub fn restart(self: *App) void {
        logger.info("App", "restarting zwin instance...", .{});
        var path_buf: [1024]u16 = undefined;
        const len = t.GetModuleFileNameW(null, &path_buf, path_buf.len);
        if (len == 0 or len >= path_buf.len) return;

        self.mutex.release();

        const res = t.ShellExecuteW(null, std.unicode.utf8ToUtf16LeStringLiteral("open"), path_buf[0..len :0].ptr, null, null, 1);
        if (@intFromPtr(res) > 32) {
            self.quitting = true;
            _ = t.PostQuitMessage(0);
        }
    }

    pub fn isAdmin(_: *const App) bool {
        return t.IsUserAnAdmin() != 0;
    }

    // Relaunch with elevated privileges
    pub fn relaunchAsAdmin(self: *App) bool {
        if (self.isAdmin()) return false;

        logger.info("App", "elevating zwin to administrator...", .{});
        var path_buf: [1024]u16 = undefined;
        const len = t.GetModuleFileNameW(null, &path_buf, path_buf.len);
        if (len == 0 or len >= path_buf.len) return false;

        self.mutex.release();
        if (self.tray) |*tr| tr.deinit();

        const res = t.ShellExecuteW(null, std.unicode.utf8ToUtf16LeStringLiteral("runas"), path_buf[0..len :0].ptr, null, null, 1);
        if (@intFromPtr(res) > 32) {
            self.quitting = true;
            _ = t.PostQuitMessage(0);
            return true;
        }

        logger.warn("App", "elevation cancelled by user, restoring mutex", .{});
        self.restoreMutex();
        if (self.tray) |*tr| _ = tr.addToTaskbar();
        return false;
    }

    // Relaunch with unelevated privileges
    pub fn relaunchUnelevated(self: *App) bool {
        if (!self.isAdmin()) return false;

        logger.info("App", "relaunching zwin without elevation...", .{});
        var path_buf: [1024]u16 = undefined;
        const len = t.GetModuleFileNameW(null, &path_buf, path_buf.len);
        if (len == 0 or len >= path_buf.len) return false;

        self.mutex.release();
        if (self.tray) |*tr| tr.deinit();

        const exe_u8 = std.unicode.utf16LeToUtf8Alloc(self.allocator, path_buf[0..len]) catch return false;
        defer self.allocator.free(exe_u8);

        const params_w = Paths.allocPrintWide(self.allocator, "/trustlevel:0x20000 \"{s}\"", .{exe_u8}) catch return false;
        defer self.allocator.free(params_w);

        const res = t.ShellExecuteW(null, std.unicode.utf8ToUtf16LeStringLiteral("open"), std.unicode.utf8ToUtf16LeStringLiteral("runas.exe"), params_w.ptr, null, 0);
        if (@intFromPtr(res) > 32) {
            self.quitting = true;
            _ = t.PostQuitMessage(0);
            return true;
        }

        logger.warn("App", "de-elevation launch failed, restoring mutex", .{});
        self.restoreMutex();
        if (self.tray) |*tr| _ = tr.addToTaskbar();
        return false;
    }

    fn restoreMutex(self: *App) void {
        self.mutex = resources.SingleInstanceMutex.acquire(single_instance_mutex_name) orelse {
            logger.err("App", "mutex re-create failed gle={d}", .{t.GetLastError()});
            return;
        };
    }

    // Execute schtasks command silently
    fn runSchtasks(self: *App, args_u8: []const u8) bool {
        const cmd_wide = Paths.allocPrintWide(self.allocator, "schtasks.exe {s}", .{args_u8}) catch return false;
        defer self.allocator.free(cmd_wide);

        var si: t.STARTUPINFOW = .{ .cb = @sizeOf(t.STARTUPINFOW) };
        var pi: t.PROCESS_INFORMATION = undefined;
        if (t.CreateProcessW(null, cmd_wide.ptr, null, null, 0, t.CREATE_NO_WINDOW, null, null, &si, &pi) == 0) return false;
        _ = t.CloseHandle(pi.hThread);
        defer _ = t.CloseHandle(pi.hProcess);

        _ = t.WaitForSingleObject(pi.hProcess, 10_000);
        var exit_code: u32 = 1;
        _ = t.GetExitCodeProcess(pi.hProcess, &exit_code);
        return exit_code == 0;
    }

    // Register ONLOGON task at highest run level for silent elevated autostart
    fn ensureElevationTask(self: *App) void {
        var path_buf: [1024]u16 = undefined;
        const len = t.GetModuleFileNameW(null, &path_buf, path_buf.len);
        if (len == 0 or len >= path_buf.len) return;

        const exe_u8 = std.unicode.utf16LeToUtf8Alloc(self.allocator, path_buf[0..len]) catch return;
        defer self.allocator.free(exe_u8);

        const args = std.fmt.allocPrint(self.allocator, "/Create /F /TN \"{s}\" /TR \\\"{s}\\\" /SC ONLOGON /RL HIGHEST", .{ elevation_task_name, exe_u8 }) catch return;
        defer self.allocator.free(args);

        if (self.runSchtasks(args)) {
            logger.info("App", "elevation task registered", .{});
        } else {
            logger.warn("App", "failed to register elevation task", .{});
        }
    }

    fn deleteElevationTask(self: *App) void {
        const args = std.fmt.allocPrint(self.allocator, "/Delete /F /TN \"{s}\"", .{elevation_task_name}) catch return;
        defer self.allocator.free(args);

        if (self.runSchtasks(args)) {
            logger.info("App", "elevation scheduled task removed", .{});
        } else {
            logger.warn("App", "failed to remove elevation scheduled task", .{});
        }
    }

    // Ensure registry Run key and scheduled task are mutually exclusive
    pub fn syncAutostartState(self: *App) void {
        if (!self.config.autostart) {
            Autostart.setEnabled(false);
            if (self.isAdmin()) self.deleteElevationTask();
            return;
        }

        if (self.config.run_as_admin and self.isAdmin()) {
            Autostart.setEnabled(false);
            self.ensureElevationTask();
        } else {
            if (self.isAdmin()) self.deleteElevationTask();
            Autostart.setEnabled(true);
        }
    }

    // Reload config: update settings and autostart without auto-restarting
    pub fn reloadConfig(self: *App) void {
        if (self.quitting) return;
        logger.info("App", "reloading config from disk", .{});

        const prev_autostart = self.config.autostart;
        const prev_run_as_admin = self.config.run_as_admin;
        self.config.deinit(self.allocator);
        self.config = ConfigStore.load(self.allocator);

        if (self.config.autostart != prev_autostart or self.config.run_as_admin != prev_run_as_admin) {
            self.syncAutostartState();
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
        if (self.msg_win) |*mw| {
            mw.setTimer(TIMER_BORDER_REINFORCE, 60);
        }
    }

    // Dispatch WinEvent-generated intents through the main thread
    fn enqueueIntentFromWinEvent(self: *App, intent: UserIntent) void {
        self.handleIntent(intent);
    }

    pub fn handleIntent(self: *App, intent: UserIntent) void {
        self.intent_handler.dispatch(intent);
        switch (intent) {
            .foreground_changed => self.scheduleBorderReinforce(),
            .window_closed_or_hidden => self.refreshActiveBorder(),
            else => {},
        }
    }

    pub fn refreshActiveBorder(self: *App) void {
        if (t.GetForegroundWindow()) |fg| {
            self.border_mgr.onFocusChange(fg);
            self.scheduleBorderReinforce();
        }
    }

    pub fn updateTrayState(self: *App, is_paused: bool) void {
        const strings = I18n.getStrings(self.config.language);
        const tip = if (is_paused) strings.tray_paused else strings.tray_running;

        if (self.tray) |*tr| tr.update(is_paused, tip);
    }
};

fn winEventCallback(_: t.HWINEVENTHOOK, event: u32, hwnd: t.HWND, idObject: i32, idChild: i32, _: u32, _: u32) callconv(.winapi) void {
    if (idObject != t.OBJID_WINDOW or idChild != 0) return;
    const app = App.global orelse return;

    switch (event) {
        t.EVENT_SYSTEM_FOREGROUND => {
            const target = if (@intFromPtr(hwnd) != 0) hwnd else (t.GetForegroundWindow() orelse return);
            app.enqueueIntentFromWinEvent(.{ .foreground_changed = target });
        },
        t.EVENT_OBJECT_SHOW => app.refreshActiveBorder(),
        t.EVENT_SYSTEM_MINIMIZEEND => {
            app.intent_handler.removeMinimized(hwnd);
            app.refreshActiveBorder();
        },
        t.EVENT_SYSTEM_MINIMIZESTART => {
            if (Window.getTrueTopLevel(hwnd)) |_| {
                app.intent_handler.recordMinimized(hwnd);
            }
            app.border_mgr.onWindowClosedOrHidden(hwnd);
            app.refreshActiveBorder();
        },
        t.EVENT_OBJECT_DESTROY => {
            app.intent_handler.removeMinimized(hwnd);
            app.enqueueIntentFromWinEvent(.{ .window_closed_or_hidden = hwnd });
        },
        t.EVENT_OBJECT_HIDE => {
            app.enqueueIntentFromWinEvent(.{ .window_closed_or_hidden = hwnd });
        },
        else => {},
    }
}

fn appWndProc(hwnd: t.HWND, msg: u32, wParam: t.WPARAM, lParam: t.LPARAM) callconv(.winapi) t.LRESULT {
    const app = App.global orelse return t.DefWindowProcW(hwnd, msg, wParam, lParam);

    // Re-add tray icon if Explorer restarts
    if (app.taskbar_created_msg != 0 and msg == app.taskbar_created_msg) {
        if (app.tray) |*tr| _ = tr.addToTaskbar();
        app.updateTrayState(app.hook_engine.paused.load(.acquire));
        return 0;
    }

    switch (msg) {
        t.WM_TRAY => {
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
                const border_flags = t.MF_STRING | (if (app.config.border) t.MF_CHECKED else t.MF_UNCHECKED);
                const autostart_flags = t.MF_STRING | (if (app.config.autostart) t.MF_CHECKED else t.MF_UNCHECKED);
                const admin_flags = t.MF_STRING | (if (app.isAdmin()) t.MF_CHECKED else t.MF_UNCHECKED);
                const admin_label = if (app.isAdmin()) strings.menu_normal else strings.menu_admin;

                _ = t.AppendMenuW(menu, pause_flags, CMD_TOGGLE_PAUSE, strings.menu_pause);
                _ = t.AppendMenuW(menu, border_flags, CMD_TOGGLE_BORDER, strings.menu_border);
                _ = t.AppendMenuW(menu, autostart_flags, CMD_TOGGLE_AUTOSTART, strings.menu_autostart);
                _ = t.AppendMenuW(menu, admin_flags, CMD_TOGGLE_ADMIN, admin_label);
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
                    app.config.border = !app.config.border;
                    if (t.GetForegroundWindow()) |current_fg| {
                        app.border_mgr.onFocusChange(current_fg);
                    }
                    ConfigStore.updateBoolOption(app.allocator, "border", app.config.border);
                    app.last_config_write_ms = t.GetTickCount64();
                },
                CMD_TOGGLE_AUTOSTART => {
                    app.config.autostart = !app.config.autostart;
                    app.syncAutostartState();
                    ConfigStore.updateBoolOption(app.allocator, "autostart", app.config.autostart);
                    app.last_config_write_ms = t.GetTickCount64();
                },
                CMD_RELOAD_CONFIG => app.reloadConfig(),
                CMD_OPEN_CONFIG_DIR => openDirInExplorer(app, .config),
                CMD_OPEN_LOG_DIR => openDirInExplorer(app, .log),
                CMD_RESTART => app.restart(),
                CMD_TOGGLE_ADMIN => {
                    const want_admin = !app.isAdmin();
                    app.config.run_as_admin = want_admin;

                    if (!want_admin and app.isAdmin()) app.deleteElevationTask();

                    app.syncAutostartState();
                    ConfigStore.updateBoolOption(app.allocator, "run_as_admin", want_admin);
                    app.last_config_write_ms = t.GetTickCount64();

                    const launched = if (want_admin) app.relaunchAsAdmin() else app.relaunchUnelevated();
                    if (!launched) {
                        app.config.run_as_admin = !want_admin;
                        app.syncAutostartState();
                        ConfigStore.updateBoolOption(app.allocator, "run_as_admin", !want_admin);
                        logger.info("App", "elevation preference rolled back to match current token", .{});
                    }
                },
                CMD_EXIT => {
                    app.quitting = true;
                    _ = t.PostQuitMessage(0);
                },
                else => {},
            }
        },
        t.WM_TIMER => {
            if (wParam == TIMER_BORDER_REINFORCE) {
                if (app.msg_win) |mw| mw.killTimer(TIMER_BORDER_REINFORCE);
                if (t.GetForegroundWindow()) |current_fg| {
                    app.border_mgr.refreshCurrent(current_fg);
                }
            } else if (wParam == TIMER_REHOOK_WATCHDOG) {
                var cur: t.POINT = undefined;
                if (!app.quitting and t.GetCursorPos(&cur) != 0) {
                    const moved = cur.x != app.watchdog_pt.x or cur.y != app.watchdog_pt.y;
                    const last_seen = app.hook_engine.last_hook_mouse_ms.load(.acquire);

                    if (moved and t.GetTickCount64() - last_seen > 6000) {
                        app.hook_engine.reinstall();
                    }
                    app.watchdog_pt = cur;
                }
            }
        },
        t.WM_APP_EVENT => {
            const event: u32 = @intCast(wParam);
            // Ignore change notifications caused by our own recent saves
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
            app.hook_engine.reportDroppedIntents();
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
