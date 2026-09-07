// Gamepad and touch input: cursor movement and swap triggering, always
// driving the player's own board (see state.player) -- the CPU has no real
// input; see cpu_ai.zig for its random-move equivalent. Not unit tested (it
// dereferences WASM4's real memory-mapped gamepad/mouse registers, which
// only make sense under an actual WASM4 host) -- see sim.zig for the
// swap/match logic it ultimately drives, which is tested.

const c = @import("constants.zig");
const s = @import("state.zig");
const w4 = @import("wasm4.zig");
const sim = @import("sim.zig");

pub fn justPressed(gp: u8, btn: u8) bool {
    return (gp & btn) != 0 and (s.prev_gamepad & btn) == 0;
}

pub fn moveCursor(dir: u8) void {
    if (dir == w4.BUTTON_LEFT) {
        if (s.player.cursor_col > 0) s.player.cursor_col -= 1;
    } else if (dir == w4.BUTTON_RIGHT) {
        if (s.player.cursor_col < c.COLS - 2) s.player.cursor_col += 1;
    } else if (dir == w4.BUTTON_UP) {
        if (s.player.cursor_row > 0) s.player.cursor_row -= 1;
    } else if (dir == w4.BUTTON_DOWN) {
        if (s.player.cursor_row < c.VISIBLE_ROWS - 1) s.player.cursor_row += 1;
    }
}

// Shared DAS (delayed auto-shift) logic: given a single direction (or 0) held
// this frame, and pointers to that input method's own held_dir/das_counter,
// moves the cursor at most once per frame with the standard first-move-then-
// repeat timing. Kept generic over which held_dir/das_counter it touches so
// the gamepad and touch can each hold a direction across frames without
// clobbering each other's timing.
fn stepDas(cur_dir: u8, held: *u8, counter: *u8) void {
    if (cur_dir == 0) {
        held.* = 0;
        counter.* = 0;
        return;
    }
    if (cur_dir != held.*) {
        held.* = cur_dir;
        counter.* = c.MOVE_DAS_FIRST;
        moveCursor(cur_dir);
    } else {
        if (counter.* == 0) {
            counter.* = c.MOVE_DAS_REPEAT;
            moveCursor(cur_dir);
        } else {
            counter.* -= 1;
        }
    }
}

pub fn updateCursorMovement(gp: u8) void {
    const dirs = [_]u8{ w4.BUTTON_LEFT, w4.BUTTON_RIGHT, w4.BUTTON_UP, w4.BUTTON_DOWN };
    var cur_dir: u8 = 0;
    for (dirs) |d| {
        if (gp & d != 0) {
            cur_dir = d;
            break;
        }
    }
    stepDas(cur_dir, &s.held_dir, &s.das_counter);
}

// A fresh press always tries the swap immediately; if the cursor's current
// pair can't swap yet (still mid-animation from a previous swap), the press
// is buffered (state.button_pending_swap) instead of dropped, and retried
// here again every frame until it succeeds -- see canSwapAt below, shared
// with touch's own buffering. Lets mashing X chain swaps at the fastest rate
// the swap animation allows, with none silently lost to bad timing.
pub fn updateSwap(gp: u8) void {
    if (justPressed(gp, w4.BUTTON_1)) s.button_pending_swap = true;
    if (s.button_pending_swap and canSwapAt(s.player.cursor_row, s.player.cursor_col)) {
        sim.trySwap(&s.player);
        s.button_pending_swap = false;
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
// swap) and keep retrying only the latter.
fn canSwapAt(row: u8, col: u8) bool {
    const a = s.player.cellAt(row, col);
    const b = s.player.cellAt(row, col + 1);
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
        s.touch_active = false;
        return;
    }

    const mx: i32 = w4.MOUSE_X.*;
    const my: i32 = w4.MOUSE_Y.*;

    if (!s.touch_active) {
        s.touch_active = true;
        s.cursor_hidden = true;
        s.touch_swipe_origin_x = mx;
        s.touch_swipe_origin_y = my;
        s.touch_pending_dir = 0;

        // Re-anchor to wherever this new touch landed -- clamped onto the
        // board so a finger landing just outside its exact pixels still
        // picks the nearest cell rather than being ignored outright.
        var col = @divTrunc(mx - c.BOARD_X, c.TILE);
        if (col < 0) col = 0;
        if (col > c.COLS - 1) col = c.COLS - 1;
        var row = @divTrunc(my - c.BOARD_Y + @as(i32, @intCast(s.player.scroll_px)), c.TILE);
        if (row < 0) row = 0;
        if (row > c.VISIBLE_ROWS - 1) row = c.VISIBLE_ROWS - 1;
        s.touch_anchor_col = @intCast(col);
        s.touch_anchor_row = @intCast(row);
    }

    const dx = mx - s.touch_swipe_origin_x;
    const dy = my - s.touch_swipe_origin_y;
    const adx = @abs(dx);
    const ady = @abs(dy);
    if (@max(adx, ady) >= TOUCH_SWIPE_THRESHOLD) {
        // Reset the measurement origin here (not just on touch-down) so one
        // long continuous drag keeps generating swipes as it travels,
        // rather than needing separate lift-and-touch gestures each time.
        s.touch_swipe_origin_x = mx;
        s.touch_swipe_origin_y = my;
        // Newest swipe always wins over whatever was still pending -- only
        // ever one buffered at a time.
        s.touch_pending_dir = if (adx > ady)
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
    switch (s.touch_pending_dir) {
        w4.BUTTON_UP => {
            if (s.touch_anchor_row > 0) s.touch_anchor_row -= 1;
            s.touch_pending_dir = 0;
        },
        w4.BUTTON_DOWN => {
            if (s.touch_anchor_row < c.VISIBLE_ROWS - 1) s.touch_anchor_row += 1;
            s.touch_pending_dir = 0;
        },
        w4.BUTTON_LEFT => {
            if (s.touch_anchor_col == 0) {
                s.touch_pending_dir = 0; // no neighbor to swap with -- drop it, not stuck retrying forever
                return;
            }
            const target = s.touch_anchor_col - 1;
            if (!canSwapAt(s.touch_anchor_row, target)) return; // keep pending, retry next frame
            s.player.cursor_row = s.touch_anchor_row;
            s.player.cursor_col = target;
            sim.trySwap(&s.player);
            s.touch_anchor_col = target; // the touched block moved left with it
            s.touch_pending_dir = 0;
        },
        w4.BUTTON_RIGHT => {
            if (s.touch_anchor_col >= c.COLS - 1) {
                s.touch_pending_dir = 0;
                return;
            }
            if (!canSwapAt(s.touch_anchor_row, s.touch_anchor_col)) return;
            s.player.cursor_row = s.touch_anchor_row;
            s.player.cursor_col = s.touch_anchor_col;
            sim.trySwap(&s.player);
            s.touch_anchor_col += 1; // the touched block moved right with it
            s.touch_pending_dir = 0;
        },
        else => {},
    }
}
