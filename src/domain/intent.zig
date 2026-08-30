const geom = @import("../calc/geometry.zig");
const t = @import("../platform/win32.zig");

// Discrete one-shot intents dispatched asynchronously to the main thread
pub const UserIntent = union(enum) {
    // Keyboard actions
    center_active_window,
    toggle_active_topmost,
    toggle_active_maximize,
    close_active_window,
    restore_last_minimized,
    focus_direction: geom.Direction,
    move_window_direction: geom.Direction,
    abort_gesture,

    // Mouse actions
    minimize_at: struct { pt: geom.Point },
    adjust_opacity_at: struct { pt: geom.Point, delta: i32 },

    // System lifecycle and focus intents
    foreground_changed: t.HWND,
    window_closed_or_hidden: t.HWND,
};
