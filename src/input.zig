// Gamepad/touch input. Functions take an explicit `board` plus its DAS/
// buffering fields. Not unit tested: dereferences WASM4's real registers.

const c = @import("constants.zig");
const s = @import("state.zig");
const touch_state = @import("state_touch.zig");
const w4 = @import("wasm4.zig");
const sim = @import("sim.zig");

// `prev` is explicit, not always state.prev_gamepad, so a second real player
// (versus mode) is checked against their own previous-frame snapshot too.
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

// Shared DAS: moves the cursor at most once/frame with first-move-then-
// repeat timing, generic over whose held_dir/das_counter it touches.
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

// A fresh press tries the swap immediately; if it can't swap yet, it's
// buffered (`pending`) and retried every frame until it succeeds.
pub fn updateSwap(board: *s.Board, pending: *bool, gp: u8, prev: u8) void {
    if (justPressed(gp, prev, w4.BUTTON_1)) pending.* = true;
    if (pending.* and canSwapAt(board, board.cursor_row, board.cursor_col)) {
        sim.trySwap(board);
        pending.* = false;
    }
}

// Minimum drag (px) to register as a swipe -- responsive, but immune to a
// trembling tap.
const TOUCH_SWIPE_THRESHOLD: i32 = 8;

// Mirrors sim.trySwap's own guard without performing the swap, so a pending
// swipe can tell "never valid" apart from "not valid yet" and keep retrying.
pub fn canSwapAt(board: *s.Board, row: u8, col: u8) bool {
    // row is window-relative; add SPAWN_ROWS for the absolute row (mirrors
    // sim.trySwap's identical conversion).
    const abs_row = row + c.SPAWN_ROWS;
    const a = board.cellAt(abs_row, col);
    const b = board.cellAt(abs_row, col + 1);
    if (!sim.swappable(a.state) or !sim.swappable(b.state)) return false;
    if (a.is_garbage or b.is_garbage) return false;
    if (a.state == .empty and b.state == .empty) return false;
    return true;
}

// Swipe-only: aims directly at the touched block (touch_anchor_col/row)
// rather than moving a separate cursor, and hides the cursor while active.
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

        // Clamp onto the board so a finger just outside it still picks the
        // nearest cell, rather than being ignored.
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
        // Reset here (not just on touch-down) so one continuous drag keeps
        // generating swipes as it travels.
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

// Retargeting always succeeds immediately; a swap retries next frame until
// the target pair is actually swappable.
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
