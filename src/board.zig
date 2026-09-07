// Row generation, the rising floor, and (re)starting a game -- all take an
// explicit `*s.Board` (see state.zig) so the exact same logic drives both
// the player's and the CPU's side of a vs-CPU match.

const c = @import("constants.zig");
const s = @import("state.zig");

// Frames needed per pixel of rise -- larger is slower. Starts at a quarter
// of the original pace (32 vs. the old 8) and eases toward the floor much
// more gradually too (a wider start-to-floor range spread over a bigger
// per-level score threshold, vs. the old steep ramp that maxed out by score
// 2400).
const RISE_START_FRAMES_PER_PIXEL: u32 = 32;
const RISE_FLOOR_FRAMES_PER_PIXEL: u32 = 4; // fastest/hardest -- unchanged from before
const RISE_SCORE_PER_LEVEL: u32 = 1200;

pub fn riseSpeedFramesPerPixel(score: u32) u32 {
    const level = score / RISE_SCORE_PER_LEVEL;
    if (level >= RISE_START_FRAMES_PER_PIXEL - RISE_FLOOR_FRAMES_PER_PIXEL) return RISE_FLOOR_FRAMES_PER_PIXEL;
    return RISE_START_FRAMES_PER_PIXEL - level;
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

// Requests a manual raise (the Z button): finishes whatever fraction of the
// current row is left to rise, over a fixed MANUAL_RAISE_FRAMES duration
// regardless of how much was already risen -- see updateRise, which actually
// carries it out once per frame from here on. A no-op while still cooling
// down from the last one or while a raise is already in progress (pressing
// Z again mid-raise doesn't stack or restart it).
pub fn tryManualRaise(self: *s.Board) void {
    if (self.manual_raise_cooldown > 0 or self.manual_raise_elapsed > 0) return;
    self.manual_raise_start_scroll = self.scroll_px;
    self.manual_raise_elapsed = 1;
    self.manual_raise_cooldown = c.MANUAL_RAISE_COOLDOWN;
}

pub fn updateRise(self: *s.Board) void {
    // The cooldown is a plain countdown on how often Z can be *pressed* --
    // ticks every frame regardless of board state, unlike the raise it
    // gates, which (like the normal automatic rise) pauses while busy.
    if (self.manual_raise_cooldown > 0) self.manual_raise_cooldown -= 1;

    if (self.boardBusy()) return;

    if (self.manual_raise_elapsed > 0) {
        // Recomputed fresh from start_scroll/elapsed each frame (not
        // accumulated incrementally) so it lands on exactly TILE at
        // MANUAL_RAISE_FRAMES with no rounding drift, whatever fraction of
        // the row was left when it was triggered.
        const remaining: u32 = @as(u32, @intCast(c.TILE)) - self.manual_raise_start_scroll;
        self.scroll_px = self.manual_raise_start_scroll + (remaining * self.manual_raise_elapsed) / c.MANUAL_RAISE_FRAMES;
        if (self.manual_raise_elapsed >= c.MANUAL_RAISE_FRAMES) {
            self.manual_raise_elapsed = 0;
        } else {
            self.manual_raise_elapsed += 1;
        }
        if (self.scroll_px >= @as(u32, @intCast(c.TILE))) {
            self.scroll_px -= @as(u32, @intCast(c.TILE));
            doRise(self);
        }
        return;
    }

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
    try testing.expectEqual(@as(u32, 32), riseSpeedFramesPerPixel(0));
    try testing.expectEqual(@as(u32, 31), riseSpeedFramesPerPixel(1200));
    try testing.expectEqual(@as(u32, 4), riseSpeedFramesPerPixel(33600));
    try testing.expectEqual(@as(u32, 4), riseSpeedFramesPerPixel(60000)); // stays floored well past that
}

test "a manual raise finishes the current row in exactly MANUAL_RAISE_FRAMES, from a clean boundary" {
    var b: s.Board = .{};
    tryManualRaise(&b);
    // Every frame but the busy-check itself is free (empty board), so this
    // runs uninterrupted.
    for (0..c.MANUAL_RAISE_FRAMES - 1) |_| {
        updateRise(&b);
        try testing.expectEqual(@as(u8, 0), b.top); // hasn't actually risen yet
    }
    const before_top = b.top;
    updateRise(&b); // the MANUAL_RAISE_FRAMES-th frame: should land exactly on TILE and rise
    try testing.expectEqual(@as(u8, (before_top + 1) % c.ROWS), b.top);
    try testing.expectEqual(@as(u32, 0), b.scroll_px); // consumed exactly, no leftover
    try testing.expectEqual(@as(u32, 0), b.manual_raise_elapsed); // finished, not left dangling
}

test "a manual raise only finishes the fraction of the row already in progress" {
    var b: s.Board = .{};
    b.scroll_px = @intCast(c.TILE - 4); // already 4px away from the next row
    tryManualRaise(&b);
    for (0..c.MANUAL_RAISE_FRAMES) |_| updateRise(&b);
    // Still exactly one row risen (not two), even though far less scroll
    // distance was needed than a full tile's worth.
    try testing.expectEqual(@as(u8, 1), b.top);
    try testing.expectEqual(@as(u32, 0), b.scroll_px);
}

test "manual raise is blocked by its own cooldown until it elapses" {
    var b: s.Board = .{};
    tryManualRaise(&b);
    for (0..c.MANUAL_RAISE_FRAMES) |_| updateRise(&b);
    try testing.expectEqual(@as(u8, 1), b.top); // first raise succeeded

    tryManualRaise(&b); // still cooling down -- should be a no-op
    try testing.expectEqual(@as(u32, 0), b.manual_raise_elapsed);

    // Tick down the remaining cooldown (already spent MANUAL_RAISE_FRAMES of
    // it during the raise itself above).
    for (0..c.MANUAL_RAISE_COOLDOWN - c.MANUAL_RAISE_FRAMES) |_| updateRise(&b);
    tryManualRaise(&b); // cooldown has now fully elapsed -- should work
    try testing.expectEqual(@as(u32, 1), b.manual_raise_elapsed);
}

test "manual raise pauses like the automatic rise while the board is busy" {
    var b: s.Board = .{};
    b.cellAt(0, 0).state = .falling; // makes boardBusy() true
    tryManualRaise(&b);
    for (0..c.MANUAL_RAISE_FRAMES * 2) |_| updateRise(&b);
    // Never progressed at all while busy.
    try testing.expectEqual(@as(u32, 1), b.manual_raise_elapsed);
    try testing.expectEqual(@as(u8, 0), b.top);
}
