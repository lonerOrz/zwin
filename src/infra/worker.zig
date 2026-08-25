const std = @import("std");
const t = @import("../platform/win32.zig");
const logger = @import("logger.zig");

pub const WindowGeometryCmd = struct {
    hwnd: t.HWND,
    x: i32,
    y: i32,
    w: i32,
    h: i32,
    flags: u32,
    insert_after: ?t.HWND = null,
};

// Fixed 8-deep FIFO for one-shot cmds; raise cap if a real
// workload ever starves it. Move/resize still coalesce via postCoalesced.
const fifo_cap = 8;

pub const WindowWorker = struct {
    lock: t.SRWLOCK = .{},
    cond: t.CONDITION_VARIABLE = .{},
    queue: [fifo_cap]WindowGeometryCmd = undefined,
    q_head: usize = 0,
    q_len: usize = 0,
    pending: ?WindowGeometryCmd = null,
    running: bool = true,
    thread: ?std.Thread = null,

    pub fn start(self: *WindowWorker) !void {
        self.thread = try std.Thread.spawn(.{}, workerLoop, .{self});
    }

    pub fn stop(self: *WindowWorker) void {
        t.AcquireSRWLockExclusive(&self.lock);
        self.running = false;
        t.ReleaseSRWLockExclusive(&self.lock);
        t.WakeConditionVariable(&self.cond);
        if (self.thread) |th| th.join();
        self.thread = null;
    }

    /// Reliable FIFO delivery for discrete commands (center, topmost).
    pub fn post(self: *WindowWorker, cmd: WindowGeometryCmd) void {
        t.AcquireSRWLockExclusive(&self.lock);
        const full = self.q_len == fifo_cap;
        if (!full) {
            self.queue[(self.q_head + self.q_len) % fifo_cap] = cmd;
            self.q_len += 1;
        }
        t.WakeConditionVariable(&self.cond);
        t.ReleaseSRWLockExclusive(&self.lock);
        if (full) logger.warn("Worker", "command queue full, dropping discrete command", .{});
    }

    /// Latest-wins delivery for high-frequency move/resize streams.
    pub fn postCoalesced(self: *WindowWorker, cmd: WindowGeometryCmd) void {
        t.AcquireSRWLockExclusive(&self.lock);
        defer t.ReleaseSRWLockExclusive(&self.lock);
        self.pending = cmd;
        t.WakeConditionVariable(&self.cond);
    }

    fn workerLoop(self: *WindowWorker) void {
        while (true) {
            var cmd: WindowGeometryCmd = undefined;
            t.AcquireSRWLockExclusive(&self.lock);
            while (self.q_len == 0 and self.pending == null and self.running) {
                _ = t.SleepConditionVariableSRW(&self.cond, &self.lock, t.INFINITE, 0);
            }
            if (!self.running and self.q_len == 0 and self.pending == null) {
                t.ReleaseSRWLockExclusive(&self.lock);
                break;
            }
            if (self.q_len > 0) {
                cmd = self.queue[self.q_head];
                self.q_head = (self.q_head + 1) % fifo_cap;
                self.q_len -= 1;
            } else {
                cmd = self.pending.?;
                self.pending = null;
            }
            t.ReleaseSRWLockExclusive(&self.lock);

            _ = t.SetWindowPos(cmd.hwnd, cmd.insert_after, cmd.x, cmd.y, cmd.w, cmd.h, cmd.flags);
        }
    }
};
