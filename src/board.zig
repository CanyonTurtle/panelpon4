// Row generation, the rising floor, and (re)starting a game -- all take an
// explicit `*s.Board` (see state.zig) so the exact same logic drives both
// the player's and the CPU's side of a vs-CPU match.

const c = @import("constants.zig");
const s = @import("state.zig");

pub fn riseSpeedFramesPerPixel(score: u32) u32 {
    const level = score / 600;
    const speed = if (level > 4) 4 else 8 - level;
    return speed;
}

pub fn generateRowInto(self: *s.Board, target_phys: u8, logical_r: u8) void {
    var row_colors: [c.COLS]u8 = undefined;
    var ci: u8 = 0;
    while (ci < c.COLS) : (ci += 1) {
        var above1: i16 = -1;
        var above2: i16 = -1;
        if (logical_r >= 1) {
            const cell1 = self.cellAt(logical_r - 1, ci);
            if (cell1.state == .normal) above1 = cell1.color;
        }
        if (logical_r >= 2) {
            const cell2 = self.cellAt(logical_r - 2, ci);
            if (cell2.state == .normal) above2 = cell2.color;
        }

        var chosen: u8 = 0;
        var tries: u8 = 0;
        while (true) {
            chosen = @intCast(self.randRange(c.NUM_COLORS));
            var ok = true;
            if (ci >= 2 and row_colors[ci - 1] == chosen and row_colors[ci - 2] == chosen) ok = false;
            if (ok and above1 >= 0 and above2 >= 0 and above1 == chosen and above2 == chosen) ok = false;
            tries += 1;
            if (ok or tries > 20) break;
        }
        row_colors[ci] = chosen;
    }

    ci = 0;
    while (ci < c.COLS) : (ci += 1) {
        self.grid[target_phys][ci] = s.Cell{ .color = row_colors[ci], .state = .normal };
    }
}

pub fn doRise(self: *s.Board) void {
    // Always perform the rise first, then check the row that lands at the
    // top (logical row 0) afterward -- checking beforehand would inspect the
    // row that's just about to be retired (relabeled to the bottom buffer
    // slot), which by construction the player has already watched scroll
    // fully off the top of the screen over the preceding animation. Checking
    // post-rise instead means game_over fires the instant the stack is
    // exactly flush with the top of the visible board, never after it's
    // scrolled out of view.
    generateRowInto(self, self.top, c.ROWS - 1);
    self.top = @intCast((@as(u16, self.top) + 1) % @as(u16, c.ROWS));

    // Logical row indices are relative to `top`, so a fixed cursor_row would
    // silently point at a different (lower) absolute row after this shift,
    // which reads as the cursor snapping down. Decrement it to keep tracking
    // the same physical row it was on, so the cursor rises with the stack
    // unless the player is actively moving it.
    if (self.cursor_row > 0) self.cursor_row -= 1;

    var col: u8 = 0;
    while (col < c.COLS) : (col += 1) {
        if (self.cellAt(0, col).state != .empty) {
            self.game_over = true;
            return;
        }
    }
}

pub fn updateRise(self: *s.Board) void {
    if (self.boardBusy()) return;
    self.rise_frame_counter += 1;
    if (self.rise_frame_counter >= riseSpeedFramesPerPixel(self.score)) {
        self.rise_frame_counter = 0;
        self.scroll_px += 1;
        if (self.scroll_px >= @as(u32, @intCast(c.TILE))) {
            self.scroll_px -= @as(u32, @intCast(c.TILE));
            doRise(self);
        }
    }
}

// Resets a board to a fresh game start: every piece of state except its RNG
// stream (preserved across a restart so replaying doesn't just repeat the
// exact same row sequence -- see state.Board.rng_state), plus an initial
// stack of rows already filled in, same as a freshly-risen board would have.
pub fn resetGame(self: *s.Board) void {
    const rng_state = self.rng_state;
    self.* = s.Board{};
    self.rng_state = rng_state;

    const start_rows_filled: u8 = 5;
    var r: u8 = c.VISIBLE_ROWS - start_rows_filled;
    while (r < c.ROWS) : (r += 1) {
        generateRowInto(self, r, r);
    }
}

const testing = @import("std").testing;

test "doRise triggers game_over once a column reaches the top row" {
    var b: s.Board = .{};
    // Row 1 becomes the new row 0 after this rise -- see doRise's comment on
    // why the check happens post-rise rather than on the row being retired.
    b.cellAt(1, 0).state = .normal;
    doRise(&b);
    try testing.expect(b.game_over);
}

test "doRise does not end the game over a row that's merely about to scroll off" {
    var b: s.Board = .{};
    // Occupied row 0 is about to be retired (relabeled to the bottom buffer
    // slot) by this rise, not promoted to the top -- it must not trigger
    // game_over on its own. Row 1 (left empty here) is what becomes the new
    // row 0, and that's what actually gets checked.
    b.cellAt(0, 0).state = .normal;
    doRise(&b);
    try testing.expect(!b.game_over);
}

test "doRise shifts top and keeps the cursor tracking the same physical row" {
    var b: s.Board = .{};
    b.cursor_row = 4;
    const before_top = b.top;
    doRise(&b);
    try testing.expect(!b.game_over);
    try testing.expectEqual(@as(u8, (before_top + 1) % c.ROWS), b.top);
    try testing.expectEqual(@as(u8, 3), b.cursor_row);
}

test "generateRowInto never produces a 3-in-a-row horizontally" {
    var b: s.Board = .{};
    b.rng_state = 12345;
    for (0..50) |i| {
        generateRowInto(&b, 0, 0);
        var run: u8 = 1;
        var run_color = b.grid[0][0].color;
        for (1..c.COLS) |col| {
            if (b.grid[0][col].color == run_color) {
                run += 1;
                try testing.expect(run < 3);
            } else {
                run = 1;
                run_color = b.grid[0][col].color;
            }
        }
        _ = i;
    }
}

test "riseSpeedFramesPerPixel decreases with score and floors at 4" {
    try testing.expectEqual(@as(u32, 8), riseSpeedFramesPerPixel(0));
    try testing.expectEqual(@as(u32, 7), riseSpeedFramesPerPixel(600));
    try testing.expectEqual(@as(u32, 4), riseSpeedFramesPerPixel(6000));
}
