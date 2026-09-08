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

// Draws from the shared RNG stream (state.shared_row_rng_state) -- never
// either board's own rng_state -- so the result depends only on how many
// times this has been called since the stream was last reseeded, never on
// anything board-specific. That's what makes rowForIndex's result
// reproducible purely from an index (see its own doc comment).
fn sharedRandRange(n: u32) u32 {
    var x = s.shared_row_rng_state;
    x ^= x << 13;
    x ^= x >> 17;
    x ^= x << 5;
    s.shared_row_rng_state = x;
    return x % n;
}

// Picks one row's colors, avoiding a horizontal run of 3 within the row
// (row_colors itself) and a vertical run of 3 against the previous two rows
// -- but *in the shared sequence itself* (above1/above2), never either
// board's own actual stack content like this used to check: a board's stack
// is a downstream consequence of match play, popping, and gravity, which
// differs between boards immediately, so checking against it would make two
// boards' otherwise-identical sequences diverge and defeat the whole point
// of rowForIndex below.
fn pickRowColors(above1: ?[c.COLS]u8, above2: ?[c.COLS]u8) [c.COLS]u8 {
    var row_colors: [c.COLS]u8 = undefined;
    var ci: u8 = 0;
    while (ci < c.COLS) : (ci += 1) {
        const a1: i16 = if (above1) |a| a[ci] else -1;
        const a2: i16 = if (above2) |a| a[ci] else -1;

        var chosen: u8 = 0;
        var tries: u8 = 0;
        while (true) {
            chosen = @intCast(sharedRandRange(c.NUM_COLORS));
            var ok = true;
            if (ci >= 2 and row_colors[ci - 1] == chosen and row_colors[ci - 2] == chosen) ok = false;
            if (ok and a1 >= 0 and a2 >= 0 and a1 == chosen and a2 == chosen) ok = false;
            tries += 1;
            if (ok or tries > 20) break;
        }
        row_colors[ci] = chosen;
    }
    return row_colors;
}

// Resets the shared row cache at match start. Deliberately separate from
// resetGame (which runs once PER BOARD): calling this from inside resetGame
// would reset shared_rows_count back to 0 a second time when the second
// board resets, discarding the row the first board may have already
// generated for index 0 and replacing it with a *different* one -- exactly
// the desync this whole mechanism exists to prevent. Callers reset both
// boards and the shared cache together instead (see main.zig).
// shared_row_rng_state itself is deliberately left untouched here -- see its
// own doc comment in state.zig for why.
pub fn resetSharedRows() void {
    s.shared_rows_count = 0;
}

// Advances the shared RNG stream by one step without consuming a row --
// mirrors each board's own idle title-screen rngNext() perturbation (see
// main.zig), so how long a player dawdles on the title screen before
// starting still changes the eventual row sequence, exactly like it always
// has, just for the shared stream now instead of the player's own.
pub fn perturbSharedRng() void {
    _ = sharedRandRange(2);
}

// Returns the colors for the `index`-th row risen since the match started,
// shared by both boards (see state.shared_rows) -- generates and caches it
// the first time either board reaches that index, and simply replays the
// cached result for whichever board reaches it second, however much later.
// This -- not either board's own rng_state -- is what "predetermined at
// match start" and "the same for both players per row" mean in practice:
// the sequence depends only on shared_row_rng_state's evolution and the
// row's own position in it, never on anything board-specific, so the Nth
// row either board has ever seen rise in looks identical regardless of
// which board reached N first -- a fair, reproducible comparison of how
// each side handles the same material.
fn rowForIndex(index: u32) [c.COLS]u8 {
    if (index < s.shared_rows_count) return s.shared_rows[index % s.SHARED_ROW_CACHE];

    const above1: ?[c.COLS]u8 = if (index >= 1) s.shared_rows[(index - 1) % s.SHARED_ROW_CACHE] else null;
    const above2: ?[c.COLS]u8 = if (index >= 2) s.shared_rows[(index - 2) % s.SHARED_ROW_CACHE] else null;
    const colors = pickRowColors(above1, above2);
    s.shared_rows[index % s.SHARED_ROW_CACHE] = colors;
    s.shared_rows_count = index + 1;
    return colors;
}

// Writes this board's next shared row into `target_phys`, advancing its own
// count of how many rows it's consumed since match start (see
// Board.rows_generated, the index into the shared sequence above).
fn writeNextRow(self: *s.Board, target_phys: u8) void {
    const colors = rowForIndex(self.rows_generated);
    self.rows_generated += 1;
    var ci: u8 = 0;
    while (ci < c.COLS) : (ci += 1) {
        self.grid[target_phys][ci] = s.Cell{ .color = colors[ci], .state = .normal };
    }
}

pub fn doRise(self: *s.Board) void {
    writeNextRow(self, c.SPAWN_ROWS + self.top);
    self.top = @intCast((@as(u16, self.top) + 1) % @as(u16, c.RING_SIZE));

    // Logical row indices are relative to `top`, so a fixed cursor_row would
    // silently point at a different (lower) absolute row after this shift,
    // which reads as the cursor snapping down. Decrement it to keep tracking
    // the same physical row it was on, so the cursor rises with the stack
    // unless the player is actively moving it.
    if (self.cursor_row > 0) self.cursor_row -= 1;

    // Reaching the top row no longer ends the game by itself -- see
    // updateDangerTimer below, which checks this same condition (a block at
    // or above the ceiling) continuously every frame instead, gated behind a
    // forgiveness timer so a high-level player gets a real beat to clear it
    // rather than losing the instant a rise happens to touch row 0.
}

fn rowOccupied(self: *s.Board, row: u8) bool {
    for (0..c.COLS) |col| {
        if (self.cellAt(row, @intCast(col)).state != .empty) return true;
    }
    return false;
}

// The actual loss condition: continuously (not just right after a rise)
// checks whether the board is idle with a block at or above the ceiling
// (row 0 occupied), and ticks a forgiveness timer while both hold -- only
// once that's run for DANGER_FORGIVENESS_FRAMES (1 second) does the game
// actually end. Reset to 0 the instant either condition stops holding (the
// board goes busy again, or the danger row clears), so a close call that
// gets cleared in time never carries over into the next one.
pub fn updateDangerTimer(self: *s.Board) void {
    if (self.game_over) return;
    if (!self.boardBusy() and rowOccupied(self, c.SPAWN_ROWS)) {
        self.danger_timer += 1;
        if (self.danger_timer >= c.DANGER_FORGIVENESS_FRAMES) self.game_over = true;
    } else {
        self.danger_timer = 0;
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
// exact same reveal colors -- see state.Board.rng_state), plus an initial
// stack of rows already filled in, same as a freshly-risen board would have
// -- drawn from the shared row sequence (see writeNextRow/resetSharedRows),
// so this initial stack is identical for both boards too, not just the rows
// that rise in later.
pub fn resetGame(self: *s.Board) void {
    const rng_state = self.rng_state;
    self.* = s.Board{};
    self.rng_state = rng_state;

    const start_rows_filled: u8 = 5;
    var r: u8 = c.SPAWN_ROWS + c.VISIBLE_ROWS - start_rows_filled;
    while (r < c.ROWS) : (r += 1) {
        writeNextRow(self, r);
    }
}

const testing = @import("std").testing;

test "doRise no longer ends the game directly -- see updateDangerTimer's forgiveness timer" {
    var b: s.Board = .{};
    // At the ceiling from frame 0 -- reaching it doesn't instantly end the
    // game anymore (that's updateDangerTimer's job, gated behind its own
    // forgiveness timer).
    b.cellAt(c.SPAWN_ROWS, 0).state = .normal;
    doRise(&b);
    try testing.expect(!b.game_over);
}

test "updateDangerTimer does nothing while the board is busy, even with a block at the ceiling" {
    var b: s.Board = .{};
    b.cellAt(c.SPAWN_ROWS, 0).state = .falling; // busy, and already at the ceiling
    for (0..c.DANGER_FORGIVENESS_FRAMES * 2) |_| updateDangerTimer(&b);
    try testing.expectEqual(@as(u32, 0), b.danger_timer);
    try testing.expect(!b.game_over);
}

test "updateDangerTimer does nothing while idle with no block at the ceiling" {
    var b: s.Board = .{};
    b.cellAt(5, 0).state = .normal; // idle, but nowhere near the ceiling
    for (0..c.DANGER_FORGIVENESS_FRAMES * 2) |_| updateDangerTimer(&b);
    try testing.expectEqual(@as(u32, 0), b.danger_timer);
    try testing.expect(!b.game_over);
}

test "updateDangerTimer ends the game only after the forgiveness timer elapses while idle and at the ceiling" {
    var b: s.Board = .{};
    b.cellAt(c.SPAWN_ROWS, 0).state = .normal; // idle and at the ceiling from frame 0
    for (0..c.DANGER_FORGIVENESS_FRAMES - 1) |_| updateDangerTimer(&b);
    try testing.expect(!b.game_over);
    updateDangerTimer(&b); // the DANGER_FORGIVENESS_FRAMES-th frame
    try testing.expect(b.game_over);
}

test "updateDangerTimer resets if the board goes busy before the forgiveness timer elapses" {
    var b: s.Board = .{};
    b.cellAt(c.SPAWN_ROWS, 0).state = .normal;
    for (0..c.DANGER_FORGIVENESS_FRAMES - 1) |_| updateDangerTimer(&b);
    try testing.expectEqual(c.DANGER_FORGIVENESS_FRAMES - 1, b.danger_timer);

    b.cellAt(5, 1).state = .falling; // becomes busy for one frame
    updateDangerTimer(&b);
    try testing.expectEqual(@as(u32, 0), b.danger_timer);

    // Idle again, still at the ceiling -- needs the FULL duration again, not
    // a continuation from where it left off.
    b.cellAt(5, 1).state = .empty;
    for (0..c.DANGER_FORGIVENESS_FRAMES - 1) |_| updateDangerTimer(&b);
    try testing.expect(!b.game_over);
    updateDangerTimer(&b);
    try testing.expect(b.game_over);
}

test "updateDangerTimer resets if the ceiling clears before the forgiveness timer elapses" {
    var b: s.Board = .{};
    b.cellAt(c.SPAWN_ROWS, 0).state = .normal;
    for (0..c.DANGER_FORGIVENESS_FRAMES - 1) |_| updateDangerTimer(&b);
    try testing.expectEqual(c.DANGER_FORGIVENESS_FRAMES - 1, b.danger_timer);

    b.cellAt(c.SPAWN_ROWS, 0).state = .empty; // the danger row clears in time
    updateDangerTimer(&b);
    try testing.expectEqual(@as(u32, 0), b.danger_timer);
    try testing.expect(!b.game_over);
}

test "doRise shifts top and keeps the cursor tracking the same physical row" {
    var b: s.Board = .{};
    b.cursor_row = 4;
    const before_top = b.top;
    doRise(&b);
    try testing.expect(!b.game_over);
    try testing.expectEqual(@as(u8, (before_top + 1) % c.RING_SIZE), b.top);
    try testing.expectEqual(@as(u8, 3), b.cursor_row);
}

test "the shared row sequence never produces a 3-in-a-row horizontally" {
    var b: s.Board = .{};
    resetSharedRows();
    s.shared_row_rng_state = 12345;
    for (0..50) |i| {
        writeNextRow(&b, 0);
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

test "the shared row sequence gives the same row to both boards, whichever reaches that index first" {
    var a: s.Board = .{};
    var b: s.Board = .{};
    resetSharedRows();
    s.shared_row_rng_state = 999;

    // `b` reaches index 0 first (generating and caching it); `a` then
    // reaches the SAME index later and must see the identical result, not a
    // freshly-generated (and almost certainly different) one of its own.
    writeNextRow(&b, 0);
    writeNextRow(&a, 0);
    for (0..c.COLS) |col| try testing.expectEqual(b.grid[0][col].color, a.grid[0][col].color);

    // Continuing to advance independently (mimicking one board rising
    // faster than the other) still lines up index-for-index.
    writeNextRow(&b, 1);
    writeNextRow(&b, 2);
    writeNextRow(&a, 1);
    for (0..c.COLS) |col| try testing.expectEqual(b.grid[1][col].color, a.grid[1][col].color);
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
    try testing.expectEqual(@as(u8, (before_top + 1) % c.RING_SIZE), b.top);
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
