const std = @import("std");
const t = @import("../platform/win32.zig");
const WindowTarget = @import("../domain/window_target.zig").WindowTarget;
const logger = @import("logger.zig");

pub const StreamingOp = union(enum) {
    move: struct { x: i32, y: i32 },
    resize: struct { x: i32, y: i32, w: i32, h: i32, wmsz: usize = 0 },
};

pub const DiscreteOp = union(enum) {
    set_bounds: struct { x: i32, y: i32, w: i32, h: i32 },
    set_topmost: struct { is_topmost: bool },
};

// Bounded FIFO capacity for discrete tasks
const fifo_cap = 8;

pub const WindowWorker = struct {
    lock: t.SRWLOCK = .{},
    cond: t.CONDITION_VARIABLE = .{},

    // Ordered FIFO for discrete operations
    fifo_queue: [fifo_cap]struct {
        target: WindowTarget,
        op: DiscreteOp,
    } = undefined,
    fifo_head: usize = 0,
    fifo_len: usize = 0,

    // Latest-wins coalescing slot for high-frequency streaming gestures
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

    // Increment session and clear streaming slot — call at the end of a gesture
    pub fn invalidateSession(self: *WindowWorker) u64 {
        t.AcquireSRWLockExclusive(&self.lock);
        defer t.ReleaseSRWLockExclusive(&self.lock);
        self.active_session_id +%= 1;
        self.streaming_slot = null;
        return self.active_session_id;
    }

    // Read-only snapshot of current session — safe to call from any context, no side effects
    pub fn fetchSessionId(self: *WindowWorker) u64 {
        t.AcquireSRWLockExclusive(&self.lock);
        defer t.ReleaseSRWLockExclusive(&self.lock);
        return self.active_session_id;
    }

    // Enqueue discrete operation with guaranteed delivery
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

    // Enqueue latest streaming operation, overriding previous pending frame
    pub fn postStreaming(self: *WindowWorker, target: WindowTarget, op: StreamingOp) void {
        t.AcquireSRWLockExclusive(&self.lock);
        defer t.ReleaseSRWLockExclusive(&self.lock);
        self.streaming_slot = .{ .target = target, .op = op };
        t.WakeConditionVariable(&self.cond);
    }

    fn workerLoop(self: *WindowWorker) void {
        // Boost worker thread priority for responsive window positioning
        _ = t.SetThreadPriority(t.GetCurrentThread(), t.THREAD_PRIORITY_HIGHEST);
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

            // Drain FIFO discrete ops first
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

            // Consume the streaming coalescing slot
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
                // Allow grid-aware windows (terminals) to adjust sizing bounds via WM_SIZING
                var rc: t.RECT = .{ .left = r.x, .top = r.y, .right = r.x + r.w, .bottom = r.y + r.h };
                var smto_result: usize = 0;
                if (r.wmsz != 0 and t.SendMessageTimeoutW(
                    hwnd,
                    t.WM_SIZING,
                    r.wmsz,
                    @bitCast(@intFromPtr(&rc)),
                    t.SMTO_ABORTIFHUNG,
                    32,
                    &smto_result,
                ) != 0) {
                    _ = t.SetWindowPos(
                        hwnd,
                        null,
                        rc.left,
                        rc.top,
                        rc.right - rc.left,
                        rc.bottom - rc.top,
                        t.SWP_NOZORDER | t.SWP_NOACTIVATE | t.SWP_NOCOPYBITS | t.SWP_NOOWNERZORDER,
                    );
                    return;
                }
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
