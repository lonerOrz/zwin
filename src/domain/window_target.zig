const t = @import("../platform/win32.zig");

/// A window handle bound to the interaction session it was resolved in.
/// Stale targets (from a previous drag/interaction session or a destroyed
/// HWND) are silently dropped by the worker instead of being executed.
pub const WindowTarget = struct {
    hwnd: t.HWND,
    session_id: u64,

    pub fn isValid(self: WindowTarget, current_active_session: u64) bool {
        return self.session_id == current_active_session and t.IsWindow(self.hwnd) != 0;
    }
};
