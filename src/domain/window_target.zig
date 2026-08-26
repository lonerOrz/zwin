const t = @import("../platform/win32.zig");

// Target window bound to an interaction session to invalidate stale operations
pub const WindowTarget = struct {
    hwnd: t.HWND,
    session_id: u64,

    pub fn isValid(self: WindowTarget, current_active_session: u64) bool {
        return self.session_id == current_active_session and t.IsWindow(self.hwnd) != 0;
    }
};
