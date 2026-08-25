const std = @import("std");
const t = @import("../platform/win32.zig");
const Paths = @import("../platform/paths.zig").Paths;

pub const LogLevel = enum(u8) {
    debug,
    info,
    warn,
    err,

    pub fn label(self: LogLevel) []const u8 {
        return switch (self) {
            .debug => "DEBUG",
            .info => "INFO",
            .warn => "WARN",
            .err => "ERROR",
        };
    }
};

pub const Logger = struct {
    lock: t.SRWLOCK = .{},
    log_file: t.HANDLE = t.INVALID_HANDLE_VALUE,
    min_level: LogLevel = .info,
    max_days: u32 = 7,
    open_day: u32 = 0,

    pub var global: ?*Logger = null;

    pub fn init(max_days: u32) Logger {
        var self = Logger{ .max_days = max_days };
        self.rotateFile();
        return self;
    }

    pub fn deinit(self: *Logger) void {
        if (self.log_file != t.INVALID_HANDLE_VALUE) _ = t.CloseHandle(self.log_file);
        self.log_file = t.INVALID_HANDLE_VALUE;
    }

    fn localDayKey(st: t.SYSTEMTIME) u32 {
        return @as(u32, st.wYear) * 10000 + @as(u32, st.wMonth) * 100 + st.wDay;
    }

    fn rotateFile(self: *Logger) void {
        const pa = std.heap.page_allocator;
        const dir = Paths.getXdgLogDir(pa) catch return;
        defer pa.free(dir);

        Paths.makeDirs(dir);
        Paths.deleteOldFiles(dir, "zwin-", ".log", self.max_days);

        var st: t.SYSTEMTIME = undefined;
        t.GetLocalTime(&st);

        var path_buf: [600]u8 = undefined;
        const path = std.fmt.bufPrint(
            &path_buf,
            "{s}\\zwin-{d:0>4}-{d:0>2}-{d:0>2}.log",
            .{ dir, st.wYear, st.wMonth, st.wDay },
        ) catch return;

        if (self.log_file != t.INVALID_HANDLE_VALUE) _ = t.CloseHandle(self.log_file);
        self.log_file = Paths.openAppend(path) catch t.INVALID_HANDLE_VALUE;
        self.open_day = localDayKey(st);
    }

    pub fn log(self: *Logger, level: LogLevel, comptime tag: []const u8, comptime fmt: []const u8, args: anytype) void {
        if (@intFromEnum(level) < @intFromEnum(self.min_level)) return;

        t.AcquireSRWLockExclusive(&self.lock);
        defer t.ReleaseSRWLockExclusive(&self.lock);

        var st: t.SYSTEMTIME = undefined;
        t.GetLocalTime(&st);
        if (self.log_file == t.INVALID_HANDLE_VALUE or localDayKey(st) != self.open_day) {
            self.rotateFile();
        }
        if (self.log_file == t.INVALID_HANDLE_VALUE) return;

        var buf: [1024]u8 = undefined;
        const line = std.fmt.bufPrint(
            &buf,
            "[{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}] [{s}] [{s}] [T:{d}] " ++ fmt ++ "\n",
            .{
                st.wHour,
                st.wMinute,
                st.wSecond,
                st.wMilliseconds,
                level.label(),
                tag,
                t.GetCurrentThreadId(),
            } ++ args,
        ) catch return;

        var written: u32 = 0;
        _ = t.WriteFile(self.log_file, line.ptr, @intCast(line.len), &written, null);
    }
};

pub fn debug(comptime tag: []const u8, comptime fmt: []const u8, args: anytype) void {
    if (Logger.global) |l| l.log(.debug, tag, fmt, args);
}

pub fn info(comptime tag: []const u8, comptime fmt: []const u8, args: anytype) void {
    if (Logger.global) |l| l.log(.info, tag, fmt, args);
}

pub fn warn(comptime tag: []const u8, comptime fmt: []const u8, args: anytype) void {
    if (Logger.global) |l| l.log(.warn, tag, fmt, args);
}

pub fn err(comptime tag: []const u8, comptime fmt: []const u8, args: anytype) void {
    if (Logger.global) |l| l.log(.err, tag, fmt, args);
}
