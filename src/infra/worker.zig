const std = @import("std");
const t = @import("../platform/win32.zig");
const WindowTarget = @import("../domain/window_target.zig").WindowTarget;
const logger = @import("logger.zig");

pub const StreamingOp = union(enum) {
    move: struct { x: i32, y: i32 },
    resize: struct { x: i32, y: i32, w: i32, h: i32 },
};

pub const DiscreteOp = union(enum) {
    set_bounds: struct { x: i32, y: i32, w: i32, h: i32 },
    set_topmost: struct { is_topmost: bool },
};

// Fixed 8-deep FIFO for discrete tasks; raise cap if a real
// workload ever starves it.
const fifo_cap = 8;

pub const WindowWorker = struct {
    lock: t.SRWLOCK = .{},
    cond: t.CONDITION_VARIABLE = .{},

    // 1. Strictly ordered bounded FIFO (discrete critical ops).
    fifo_queue: [fifo_cap]struct {
        target: WindowTarget,
        op: DiscreteOp,
    } = undefined,
    fifo_head: usize = 0,
    fifo_len: usize = 0,

    // 2. Latest-wins streaming slot (single active mouse stream).
    streaming_slot: ?struct {
        target: WindowTarget,
        op: StreamingOp,
    } = null,

    active_session_id: u64 = 0,
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

    /// Bump the global session id so every queued streaming and discrete op
    /// from previous sessions is silently invalidated. Returns the new id so
    /// callers can hand out matching targets.
    pub fn invalidateSession(self: *WindowWorker) u64 {
        t.AcquireSRWLockExclusive(&self.lock);
        defer t.ReleaseSRWLockExclusive(&self.lock);
        self.active_session_id +%= 1;
        self.streaming_slot = null;
        return self.active_session_id;
    }

    /// Reliable FIFO delivery for discrete ops (center, topmost).
    pub fn postDiscrete(self: *WindowWorker, target: WindowTarget, op: DiscreteOp) void {
        t.AcquireSRWLockExclusive(&self.lock);
        const full = self.fifo_len == fifo_cap;
        if (!full) {
            self.fifo_queue[(self.fifo_head + self.fifo_len) % fifo_cap] = .{
                .target = target,
                .op = op,
            };
            self.fifo_len += 1;
        }
        t.WakeConditionVariable(&self.cond);
        t.ReleaseSRWLockExclusive(&self.lock);
        if (full) logger.warn("Worker", "fifo queue full, dropped discrete task", .{});
    }

    /// Latest-wins delivery for high-frequency move/resize streams.
    pub fn postStreaming(self: *WindowWorker, target: WindowTarget, op: StreamingOp) void {
        t.AcquireSRWLockExclusive(&self.lock);
        defer t.ReleaseSRWLockExclusive(&self.lock);
        self.streaming_slot = .{ .target = target, .op = op };
        t.WakeConditionVariable(&self.cond);
    }

    fn workerLoop(self: *WindowWorker) void {
        while (true) {
            t.AcquireSRWLockExclusive(&self.lock);
            while (self.fifo_len == 0 and self.streaming_slot == null and self.running) {
                _ = t.SleepConditionVariableSRW(&self.cond, &self.lock, t.INFINITE, 0);
            }
            if (!self.running and self.fifo_len == 0 and self.streaming_slot == null) {
                t.ReleaseSRWLockExclusive(&self.lock);
                break;
            }

            const current_session = self.active_session_id;

            // Drain FIFO discrete ops first.
            if (self.fifo_len > 0) {
                const task = self.fifo_queue[self.fifo_head];
                self.fifo_head = (self.fifo_head + 1) % fifo_cap;
                self.fifo_len -= 1;
                t.ReleaseSRWLockExclusive(&self.lock);

                if (task.target.isValid(current_session)) {
                    executeDiscrete(task.target.hwnd, task.op);
                }
                continue;
            }

            // Consume the streaming coalescing slot.
            if (self.streaming_slot) |task| {
                self.streaming_slot = null;
                t.ReleaseSRWLockExclusive(&self.lock);

                if (task.target.isValid(current_session)) {
                    executeStreaming(task.target.hwnd, task.op);
                }
                continue;
            }

            t.ReleaseSRWLockExclusive(&self.lock);
        }
    }

    fn executeDiscrete(hwnd: t.HWND, op: DiscreteOp) void {
        switch (op) {
            .set_bounds => |b| {
                _ = t.SetWindowPos(hwnd, null, b.x, b.y, b.w, b.h, t.SWP_NOACTIVATE | t.SWP_NOZORDER);
            },
            .set_topmost => |top| {
                _ = t.SetWindowPos(
                    hwnd,
                    if (top.is_topmost) t.HWND_TOPMOST else t.HWND_NOTOPMOST,
                    0,
                    0,
                    0,
                    0,
                    t.SWP_NOMOVE | t.SWP_NOSIZE | t.SWP_NOACTIVATE,
                );
            },
        }
    }

    fn executeStreaming(hwnd: t.HWND, op: StreamingOp) void {
        switch (op) {
            .move => |m| {
                _ = t.SetWindowPos(
                    hwnd,
                    null,
                    m.x,
                    m.y,
                    0,
                    0,
                    t.SWP_NOSIZE | t.SWP_NOZORDER | t.SWP_NOACTIVATE | t.SWP_NOCOPYBITS | t.SWP_NOOWNERZORDER,
                );
            },
            .resize => |r| {
                _ = t.SetWindowPos(
                    hwnd,
                    null,
                    r.x,
                    r.y,
                    r.w,
                    r.h,
                    t.SWP_NOZORDER | t.SWP_NOACTIVATE | t.SWP_NOCOPYBITS | t.SWP_NOOWNERZORDER,
                );
            },
        }
    }
};
