const geom = @import("../calc/geometry.zig");

/// Only discrete one-shot intents travel through the async queue.
/// Continuous gestures (drag/resize) are realtime input streams owned by
/// GestureStateMachine, which must be started synchronously with the
/// physical button press — an async start can be overtaken by the button's
/// WM_*BUTTONUP and leave the state machine stuck dragging.
pub const UserIntent = union(enum) {
    // Keyboard intents (target = current foreground window, resolved by
    // the dispatcher at handling time).
    center_active_window,
    toggle_active_topmost,
    close_active_window,

    // Mouse intents (carry screen absolute coordinates).
    minimize_at: struct { pt: geom.Point },
    adjust_opacity_at: struct { pt: geom.Point, delta: i32 },
};
