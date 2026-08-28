const geom = @import("../calc/geometry.zig");

// Discrete one-shot intents dispatched asynchronously to the main thread
pub const UserIntent = union(enum) {
    // Actions targeting the active foreground window
    center_active_window,
    toggle_active_topmost,
    toggle_active_maximize,
    close_active_window,
    restore_last_minimized,
    focus_direction: geom.Direction,
    abort_gesture,

    // Mouse actions with screen coordinates
    minimize_at: struct { pt: geom.Point },
    adjust_opacity_at: struct { pt: geom.Point, delta: i32 },
};
