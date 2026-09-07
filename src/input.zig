// Gamepad and touch input: cursor movement (with DAS) and swap triggering,
// always driving the player's own board (see state.player) -- the CPU has
// no real input; see cpu_ai.zig for its random-move equivalent. Not unit
// tested (it dereferences WASM4's real memory-mapped gamepad/mouse
// registers, which only make sense under an actual WASM4 host) -- see
// sim.zig for the swap/match logic it drives, which is tested.

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

// Touch acts as a virtual joystick relative to the *current* cursor, not a
// direct pointer: it never teleports the cursor to the touched tile. Touching
// one of the cursor's own two tiles swaps (once per press, no matter how
// long it's held or how the touch wanders while still on those tiles);
// touching anywhere else moves the cursor one step toward it, through the
// same moveCursor/DAS repeat the gamepad directions use. This keeps touch no
// more capable than the physical controls -- reaching a distant swap still
// takes the same number of discrete steps as walking the cursor there with
// the d-pad -- and requires deliberately positioning the cursor rather than
// dragging it straight to the target.
pub fn updateTouch() void {
    const held = w4.MOUSE_BUTTONS.* & w4.MOUSE_LEFT != 0;
    if (!held) {
        s.touch_active = false;
        s.touch_swapped_this_press = false;
        stepDas(0, &s.touch_held_dir, &s.touch_das_counter);
        return;
    }
    if (!s.touch_active) {
        s.touch_active = true;
        s.touch_swapped_this_press = false;
    }

    const mx = w4.MOUSE_X.*;
    const my = w4.MOUSE_Y.*;
    const board_w = @as(i32, c.COLS) * c.TILE;
    const board_h = @as(i32, c.VISIBLE_ROWS) * c.TILE;
    if (mx < c.BOARD_X or mx >= c.BOARD_X + board_w or my < c.BOARD_Y or my >= c.BOARD_Y + board_h) {
        stepDas(0, &s.touch_held_dir, &s.touch_das_counter); // off the board: hold steady, no move or swap
        return;
    }

    const col: u8 = @intCast(@divTrunc(@as(i32, mx) - c.BOARD_X, c.TILE));
    var row_signed = @divTrunc(@as(i32, my) - c.BOARD_Y + @as(i32, @intCast(s.player.scroll_px)), c.TILE);
    if (row_signed < 0) row_signed = 0;
    if (row_signed > c.VISIBLE_ROWS - 1) row_signed = c.VISIBLE_ROWS - 1;
    const row: u8 = @intCast(row_signed);

    const col_in_span = col == s.player.cursor_col or col == s.player.cursor_col + 1;
    if (row == s.player.cursor_row and col_in_span) {
        if (!s.touch_swapped_this_press) {
            sim.trySwap(&s.player);
            s.touch_swapped_this_press = true;
        }
        stepDas(0, &s.touch_held_dir, &s.touch_das_counter);
        return;
    }

    const dir: u8 = if (row < s.player.cursor_row)
        w4.BUTTON_UP
    else if (row > s.player.cursor_row)
        w4.BUTTON_DOWN
    else if (col < s.player.cursor_col)
        w4.BUTTON_LEFT
    else
        w4.BUTTON_RIGHT;
    stepDas(dir, &s.touch_held_dir, &s.touch_das_counter);
}
