// Touch/mouse input state -- split out of state.zig (whose only consumer
// here is input.zig, plus a single `cursor_hidden` read each from main.zig
// and render.zig) to keep that file under the project's ~500-line-per-file
// guideline.
//
// True whenever touch is the active input method (see input.updateTouch) --
// hides the player's cursor (render.drawCursor) until a gamepad button
// brings it back (see main.zig). Touch aims directly at the block it
// touches down on (see touch_anchor_col/row below) rather than needing to
// see where a separate cursor currently sits, so there's nothing on-screen
// the player needs the cursor visible for while using it.
pub var cursor_hidden: bool = false;

// Touch/mouse state: swipe-only (see input.updateTouch) -- a tap or hold
// with no meaningful drag does nothing at all. Touching down picks a target
// cell directly from the touch's on-board position (`touch_anchor_col/row`);
// swiping left/right then swaps that cell with its neighbor in that
// direction (moving the anchor along with it, so a continued drag in the
// same direction keeps swapping the same physical block further across the
// board), and swiping up/down retargets to the row above/below instead
// (there's no vertical swap to perform -- blocks only ever swap
// horizontally). Starting a new touch elsewhere re-anchors to that new
// location, abandoning whatever the previous touch was doing.
//
// `touch_swipe_origin_x/y` is where the *current* swipe-detection window
// started measuring from -- reset on every new press and every time a drag
// crosses the swipe threshold in some direction (so one long continuous
// drag chains multiple swipes instead of requiring separate lift-and-touch
// gestures each time). `touch_pending_dir` implements one-deep input
// buffering: a swipe detected while the target cell can't swap yet (e.g.
// still mid-animation from the *previous* swap) is remembered -- only the
// most recent one, a newer swipe always overwrites an older still-pending
// one rather than queuing both -- and retried every frame until it
// succeeds, so a fast continuous drag chains swaps at the fastest rate the
// swap animation allows, with none silently dropped. A vertical (retarget)
// request has no such waiting condition, so it always resolves the same
// frame it's queued. Only ever drives `player` -- the CPU has no real input
// (see cpu_ai.zig).
pub var touch_active: bool = false;
pub var touch_anchor_col: u8 = 0;
pub var touch_anchor_row: u8 = 0;
pub var touch_swipe_origin_x: i32 = 0;
pub var touch_swipe_origin_y: i32 = 0;
pub var touch_pending_dir: u8 = 0;
