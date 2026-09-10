// Split out of state.zig; true while touch is the active input method,
// hiding the cursor until a gamepad button brings it back.
pub var cursor_hidden: bool = false;

// Touch is swipe-only: anchors a target cell, swipes swap/retarget it;
// `touch_pending_dir` buffers one swipe until its target can swap.
pub var touch_active: bool = false;
pub var touch_anchor_col: u8 = 0;
pub var touch_anchor_row: u8 = 0;
pub var touch_swipe_origin_x: i32 = 0;
pub var touch_swipe_origin_y: i32 = 0;
pub var touch_pending_dir: u8 = 0;
