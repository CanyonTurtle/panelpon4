// Gamepad and touch input: cursor movement and swap triggering. Every
// function below takes an explicit `board`, plus that board's own
// held_dir/das_counter/button_pending_swap/cursor_idle_frames fields to
// track DAS/buffering state -- almost always `state.player`'s own (see
// main.zig's ordinary single-player call sites), but versus mode (see
// state.GameMode) calls the exact same functions a second time with `&s.cpu`
// and its own parallel set of fields (state.cpu_held_dir etc.), since
// GAMEPAD2 drives a real second player there instead of cpu_ai. Touch has no
// second-player equivalent -- see updateTouch, still hardcoded to the
// player's own board. Not unit tested (it dereferences WASM4's real
// memory-mapped gamepad/mouse registers, which only make sense under an
// actual WASM4 host) -- see sim.zig for the swap/match logic it ultimately
// drives, which is tested.

const c = @import("constants.zig");
const s = @import("state.zig");
const touch_state = @import("state_touch.zig");
const w4 = @import("wasm4.zig");
const sim = @import("sim.zig");

// `prev` is an explicit parameter, not always state.prev_gamepad, so this
// works correctly for a second real player too (see updateSwap below): that
// player's own "was this held last frame" has to be tracked against THEIR
// OWN previous gamepad snapshot (state.cpu_prev_gamepad in versus mode, see
// main.zig), never against the first player's (state.prev_gamepad) -- an
// earlier version of this always read state.prev_gamepad regardless of
// whose input was actually being checked, which meant the second player's
// own swap button was compared against the *first* player's press history
// instead of their own: since the first player usually isn't holding X at
// all, that history reads as permanently "not pressed", so this returned
// true every single frame the second player merely *held* X down, not just
// the one frame they first pressed it -- reported as "rapidly switches
// blocks back and forth on a single press" (see updateSwap's own repeated
// re-triggering once `pending` gets consumed and immediately re-armed).
pub fn justPressed(gp: u8, prev: u8, btn: u8) bool {
    return (gp & btn) != 0 and (prev & btn) == 0;
}

pub fn moveCursor(board: *s.Board, idle_frames: *u32, dir: u8) void {
    idle_frames.* = 0;
    if (dir == w4.BUTTON_LEFT) {
        if (board.cursor_col > 0) board.cursor_col -= 1;
    } else if (dir == w4.BUTTON_RIGHT) {
        if (board.cursor_col < c.COLS - 2) board.cursor_col += 1;
    } else if (dir == w4.BUTTON_UP) {
        if (board.cursor_row > 0) board.cursor_row -= 1;
    } else if (dir == w4.BUTTON_DOWN) {
        if (board.cursor_row < c.VISIBLE_ROWS - 1) board.cursor_row += 1;
    }
}

// Shared DAS (delayed auto-shift) logic: given a single direction (or 0) held
// this frame, and pointers to that input method's own held_dir/das_counter,
// moves the cursor at most once per frame with the standard first-move-then-
// repeat timing. Kept generic over which held_dir/das_counter (and now which
// board/idle_frames) it touches so the gamepad and touch -- and, in versus
// mode, a second real player -- can each hold a direction across frames
// without clobbering each other's timing.
fn stepDas(cur_dir: u8, held: *u8, counter: *u8, board: *s.Board, idle_frames: *u32) void {
    if (cur_dir == 0) {
        held.* = 0;
        counter.* = 0;
        return;
    }
    if (cur_dir != held.*) {
        held.* = cur_dir;
        counter.* = c.MOVE_DAS_FIRST;
        moveCursor(board, idle_frames, cur_dir);
    } else {
        if (counter.* == 0) {
            counter.* = c.MOVE_DAS_REPEAT;
            moveCursor(board, idle_frames, cur_dir);
        } else {
            counter.* -= 1;
        }
    }
}

pub fn updateCursorMovement(board: *s.Board, held: *u8, counter: *u8, idle_frames: *u32, gp: u8) void {
    idle_frames.* += 1; // moveCursor resets this back to 0 if a move actually happens this frame
    const dirs = [_]u8{ w4.BUTTON_LEFT, w4.BUTTON_RIGHT, w4.BUTTON_UP, w4.BUTTON_DOWN };
    var cur_dir: u8 = 0;
    for (dirs) |d| {
        if (gp & d != 0) {
            cur_dir = d;
            break;
        }
    }
    stepDas(cur_dir, held, counter, board, idle_frames);
}

// A fresh press always tries the swap immediately; if the cursor's current
// pair can't swap yet (still mid-animation from a previous swap), the press
// is buffered (`pending`) instead of dropped, and retried here again every
// frame until it succeeds -- see canSwapAt below, shared with touch's own
// buffering. Lets mashing X chain swaps at the fastest rate the swap
// animation allows, with none silently lost to bad timing. `prev` is that
// player's own previous-frame gamepad snapshot (state.prev_gamepad for the
// player, state.cpu_prev_gamepad for versus mode's second real player --
// see justPressed's own doc comment for why this can't just be one shared
// global).
pub fn updateSwap(board: *s.Board, pending: *bool, gp: u8, prev: u8) void {
    if (justPressed(gp, prev, w4.BUTTON_1)) pending.* = true;
    if (pending.* and canSwapAt(board, board.cursor_row, board.cursor_col)) {
        sim.trySwap(board);
        pending.* = false;
    }
}

// Minimum drag distance (px) before it registers as one discrete swipe --
// small enough to feel responsive, large enough that a barely-trembling tap
// never registers as an accidental move.
const TOUCH_SWIPE_THRESHOLD: i32 = 8;

// True if the two cells at (row, col)/(row, col+1) could be swapped right
// now -- mirrors sim.trySwap's own guard exactly, without performing the
// swap, so a pending touch swipe can tell "not valid, ever" (off the board)
// apart from "not valid *yet*" (e.g. still mid-animation from the previous
// swap) and keep retrying only the latter. Generic over which board (not
// just the player's) so cpu_ai.zig's own restricted, step-by-step cursor
// movement can share this exact check rather than duplicating it.
pub fn canSwapAt(board: *s.Board, row: u8, col: u8) bool {
    // row is relative to the visible window (cursor_row/touch_anchor_row) --
    // add SPAWN_ROWS to reach the matching absolute logical row (see
    // sim.trySwap's identical conversion).
    const abs_row = row + c.SPAWN_ROWS;
    const a = board.cellAt(abs_row, col);
    const b = board.cellAt(abs_row, col + 1);
    if (!sim.swappable(a.state) or !sim.swappable(b.state)) return false;
    if (a.is_garbage or b.is_garbage) return false;
    if (a.state == .empty and b.state == .empty) return false;
    return true;
}

// Swipe-only: a tap or a hold with no meaningful drag does nothing at all.
// Touch aims directly at the block it touches down on (state.touch_anchor_
// col/row, picked from the touch's on-board position) rather than moving a
// separate cursor toward it -- see state.zig's module comment for the full
// swipe-direction mapping. Also hides the player's cursor the instant it
// starts (state.cursor_hidden, cleared again by any gamepad button -- see
// main.zig), since touch always aims at the anchor it's already showing
// through its own gesture, not wherever the (now-irrelevant) cursor sits.
pub fn updateTouch() void {
    const held = w4.MOUSE_BUTTONS.* & w4.MOUSE_LEFT != 0;
    if (!held) {
        touch_state.touch_active = false;
        return;
    }

    const mx: i32 = w4.MOUSE_X.*;
    const my: i32 = w4.MOUSE_Y.*;

    if (!touch_state.touch_active) {
        touch_state.touch_active = true;
        touch_state.cursor_hidden = true;
        touch_state.touch_swipe_origin_x = mx;
        touch_state.touch_swipe_origin_y = my;
        touch_state.touch_pending_dir = 0;

        // Re-anchor to wherever this new touch landed -- clamped onto the
        // board so a finger landing just outside its exact pixels still
        // picks the nearest cell rather than being ignored outright.
        var col = @divTrunc(mx - c.BOARD_X, c.TILE);
        if (col < 0) col = 0;
        if (col > c.COLS - 1) col = c.COLS - 1;
        var row = @divTrunc(my - c.BOARD_Y + @as(i32, @intCast(s.player.scroll_px)), c.TILE);
        if (row < 0) row = 0;
        if (row > c.VISIBLE_ROWS - 1) row = c.VISIBLE_ROWS - 1;
        touch_state.touch_anchor_col = @intCast(col);
        touch_state.touch_anchor_row = @intCast(row);
    }

    const dx = mx - touch_state.touch_swipe_origin_x;
    const dy = my - touch_state.touch_swipe_origin_y;
    const adx = @abs(dx);
    const ady = @abs(dy);
    if (@max(adx, ady) >= TOUCH_SWIPE_THRESHOLD) {
        // Reset the measurement origin here (not just on touch-down) so one
        // long continuous drag keeps generating swipes as it travels,
        // rather than needing separate lift-and-touch gestures each time.
        touch_state.touch_swipe_origin_x = mx;
        touch_state.touch_swipe_origin_y = my;
        // Newest swipe always wins over whatever was still pending -- only
        // ever one buffered at a time.
        touch_state.touch_pending_dir = if (adx > ady)
            (if (dx > 0) w4.BUTTON_RIGHT else w4.BUTTON_LEFT)
        else
            (if (dy > 0) w4.BUTTON_DOWN else w4.BUTTON_UP);
    }

    applyPendingTouchSwipe();
}

// Retargeting (up/down) always succeeds immediately -- there's no vertical
// swap to wait on. A swap (left/right) only succeeds once the target pair
// is actually swappable; until then it just stays pending and gets retried
// here again next frame, so a fast continuous drag chains swaps at the
// fastest rate the swap animation allows rather than dropping the ones that
// arrive before the last one finishes.
fn applyPendingTouchSwipe() void {
    switch (touch_state.touch_pending_dir) {
        w4.BUTTON_UP => {
            s.cursor_idle_frames = 0;
            if (touch_state.touch_anchor_row > 0) touch_state.touch_anchor_row -= 1;
            touch_state.touch_pending_dir = 0;
        },
        w4.BUTTON_DOWN => {
            s.cursor_idle_frames = 0;
            if (touch_state.touch_anchor_row < c.VISIBLE_ROWS - 1) touch_state.touch_anchor_row += 1;
            touch_state.touch_pending_dir = 0;
        },
        w4.BUTTON_LEFT => {
            if (touch_state.touch_anchor_col == 0) {
                touch_state.touch_pending_dir = 0; // no neighbor to swap with -- drop it, not stuck retrying forever
                return;
            }
            const target = touch_state.touch_anchor_col - 1;
            if (!canSwapAt(&s.player, touch_state.touch_anchor_row, target)) return; // keep pending, retry next frame
            s.player.cursor_row = touch_state.touch_anchor_row;
            s.player.cursor_col = target;
            sim.trySwap(&s.player);
            touch_state.touch_anchor_col = target; // the touched block moved left with it
            touch_state.touch_pending_dir = 0;
        },
        w4.BUTTON_RIGHT => {
            if (touch_state.touch_anchor_col >= c.COLS - 1) {
                touch_state.touch_pending_dir = 0;
                return;
            }
            if (!canSwapAt(&s.player, touch_state.touch_anchor_row, touch_state.touch_anchor_col)) return;
            s.player.cursor_row = touch_state.touch_anchor_row;
            s.player.cursor_col = touch_state.touch_anchor_col;
            sim.trySwap(&s.player);
            touch_state.touch_anchor_col += 1; // the touched block moved right with it
            touch_state.touch_pending_dir = 0;
        },
        else => {},
    }
}
