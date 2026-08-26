const geom = @import("../calc/geometry.zig");

// Discrete one-shot intents dispatched asynchronously to the main thread
pub const UserIntent = union(enum) {
    // Actions targeting the active foreground window
    center_active_window,
    toggle_active_topmost,
    close_active_window,
    abort_gesture,

    // Mouse actions with screen coordinates
    minimize_at: struct { pt: geom.Point },
    adjust_opacity_at: struct { pt: geom.Point, delta: i32 },
};
