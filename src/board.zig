// Row generation, the rising floor, and (re)starting a game all take an
// explicit `*s.Board` so the same logic drives both sides of a match.

const c = @import("constants.zig");
const s = @import("state.zig");
const row_cache = @import("state_row_cache.zig");
const garbage = @import("sim_garbage.zig");

// Frames needed per pixel of rise -- larger is slower.
const RISE_START_FRAMES_PER_PIXEL: u32 = 32;
const RISE_FLOOR_FRAMES_PER_PIXEL: u32 = 4; // fastest/hardest -- unchanged from before
const RISE_SCORE_PER_LEVEL: u32 = 1200;

pub fn riseSpeedFramesPerPixel(score: u32) u32 {
    const level = score / RISE_SCORE_PER_LEVEL;
    const base = if (level >= RISE_START_FRAMES_PER_PIXEL - RISE_FLOOR_FRAMES_PER_PIXEL)
        RISE_FLOOR_FRAMES_PER_PIXEL
    else
        RISE_START_FRAMES_PER_PIXEL - level;
    // Story mode's rise-speed-scale knob (constants.RISE_SPEED_SCALE_PCT);
    // floored at 1 frame/pixel so it can never divide down to instant/zero.
    const scaled = base * c.RISE_SPEED_SCALE_PCT / 100;
    return @max(scaled, 1);
}

// Draws from the shared RNG stream (never either board's own rng_state), so
// the result depends only on call count since last reseed, not the board.
fn sharedRandRange(n: u32) u32 {
    var x = row_cache.shared_row_rng_state;
    x ^= x << 13;
    x ^= x >> 17;
    x ^= x << 5;
    row_cache.shared_row_rng_state = x;
    return x % n;
}

// Avoids 3-in-a-row checks against the shared sequence (above1/above2), not
// either board's real stack, which diverges and would defeat rowForIndex.
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

// Kept separate from resetGame (which runs once per board) so the second
// board's reset can't re-zero shared_rows_count and desync the two boards.
pub fn resetSharedRows() void {
    row_cache.shared_rows_count = 0;
}

// Mirrors each board's own idle title-screen rngNext() perturbation, so
// dawdling on the title screen still changes the eventual row sequence.
pub fn perturbSharedRng() void {
    _ = sharedRandRange(2);
}

// Colors for the `index`-th risen row, shared by both boards: generated and
// cached on first reach, replayed (identical) on second (see tests below).
fn rowForIndex(index: u32) [c.COLS]u8 {
    if (index < row_cache.shared_rows_count) return row_cache.shared_rows[index % row_cache.SHARED_ROW_CACHE];

    const above1: ?[c.COLS]u8 = if (index >= 1) row_cache.shared_rows[(index - 1) % row_cache.SHARED_ROW_CACHE] else null;
    const above2: ?[c.COLS]u8 = if (index >= 2) row_cache.shared_rows[(index - 2) % row_cache.SHARED_ROW_CACHE] else null;
    const colors = pickRowColors(above1, above2);
    row_cache.shared_rows[index % row_cache.SHARED_ROW_CACHE] = colors;
    row_cache.shared_rows_count = index + 1;
    return colors;
}

// Writes this board's next shared row, advancing rows_generated -- its
// index into the shared sequence above.
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

    // cursor_row is relative to `top`, so decrement it here to keep tracking
    // the same physical row rather than snapping down after this shift.
    if (self.cursor_row > 0) self.cursor_row -= 1;
}

fn rowOccupied(self: *s.Board, row: u8) bool {
    for (0..c.COLS) |col| {
        if (self.cellAt(row, @intCast(col)).state != .empty) return true;
    }
    return false;
}

fn hasActivePop(self: *s.Board) bool {
    for (0..c.ROWS) |lr| {
        for (0..c.COLS) |col| {
            const state = self.cellAt(@intCast(lr), @intCast(col)).state;
            if (state == .popping or state == .recycling) return true;
        }
    }
    return false;
}

// The real loss condition, checked continuously. Remembers its progress at
// the ceiling; only .popping/.recycling pauses it -- only clearing resets it.
pub fn updateDangerTimer(self: *s.Board) void {
    if (self.game_over) return;
    if (!rowOccupied(self, c.SPAWN_ROWS)) {
        self.danger_timer = 0;
        return;
    }
    if (hasActivePop(self)) return;
    self.danger_timer += 1;
    if (self.danger_timer >= c.DANGER_FORGIVENESS_FRAMES) self.game_over = true;
}

// Finishes the current row's remaining rise over a fixed MANUAL_RAISE_FRAMES
// duration (see updateRise); a no-op while cooling down or already raising.
pub fn tryManualRaise(self: *s.Board) void {
    if (self.manual_raise_cooldown > 0 or self.manual_raise_elapsed > 0) return;
    self.manual_raise_start_scroll = self.scroll_px;
    self.manual_raise_elapsed = 1;
    self.manual_raise_cooldown = c.MANUAL_RAISE_COOLDOWN;
}

pub fn updateRise(self: *s.Board) void {
    // Cooldown ticks every frame regardless of board state, unlike the
    // raise it gates, which pauses while busy like the automatic rise.
    if (self.manual_raise_cooldown > 0) self.manual_raise_cooldown -= 1;

    if (self.boardBusy()) return;

    if (self.manual_raise_elapsed > 0) {
        // Recomputed fresh each frame (not accumulated) so it lands exactly
        // on TILE at MANUAL_RAISE_FRAMES with no rounding drift.
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

// Resets all state except rng_state (preserved so a restart doesn't repeat
// the same reveal colors); fills an initial stack from the shared rows.
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

// Attract-mode-only flourish (main.zig's start()/updateTitleDemo): a taller,
// non-uniform stack topped by a falling garbage slab, never a real match start.
const ATTRACT_MAX_ROWS: u8 = 8;
const ATTRACT_GARBAGE_ROWS: u8 = 2;
// Per-column rows shaved off the uniform stack's top -- two arbitrary, fixed
// silhouettes (comptime-shuffled particles trick, render_bg.zig, applies here too).
const ATTRACT_CUTS = [2][c.COLS]u8{ .{ 0, 3, 1, 4, 2, 0 }, .{ 2, 0, 4, 1, 0, 3 } };

pub fn seedAttractDemo(self: *s.Board, variant: u8) void {
    const top_row = c.SPAWN_ROWS + c.VISIBLE_ROWS - ATTRACT_MAX_ROWS;
    var r: u8 = top_row;
    while (r < c.ROWS) : (r += 1) writeNextRow(self, r);

    const cuts = ATTRACT_CUTS[variant % ATTRACT_CUTS.len];
    for (0..c.COLS) |ci| {
        var cleared: u8 = 0;
        while (cleared < cuts[ci]) : (cleared += 1) {
            self.cellAt(top_row + cleared, @intCast(ci)).* = s.Cell{};
        }
    }

    _ = garbage.spawnGarbage(self, ATTRACT_GARBAGE_ROWS, c.COLS, 0);
}

// Resets the shared row cache and both boards, then starts the "3 2 1
// START" countdown. The only place either board ever gets reset.
pub fn beginCountdown() void {
    resetSharedRows();
    resetGame(&s.player);
    resetGame(&s.cpu);
    s.countdown_timer = c.COUNTDOWN_TOTAL_FRAMES;
    s.started = false;
}

// Starts the closing "pop everything" wipe; called once, right when
// `winner` first leaves .none.
pub fn beginClosing() void {
    s.closing_timer = c.CLOSING_TOTAL_FRAMES;
}

// Awards this match's point (a draw awards neither side), then checks
// whether that's enough to take the best-of-N series.
pub fn awardMatchPoint(winner: s.Winner) void {
    switch (winner) {
        .player => s.player_points += 1,
        .cpu => s.cpu_points += 1,
        .draw, .none => {},
    }
    if (s.player_points >= c.POINTS_TO_WIN) {
        s.set_winner = .player;
    } else if (s.cpu_points >= c.POINTS_TO_WIN) {
        s.set_winner = .cpu;
    }
}

const testing = @import("std").testing;

test "resetGame restarts rows_generated from the same baseline regardless of prior value" {
    var a: s.Board = .{ .rows_generated = 42 };
    var b: s.Board = .{ .rows_generated = 0 };
    resetGame(&a);
    resetGame(&b);
    try testing.expectEqual(b.rows_generated, a.rows_generated);
}

test "doRise no longer ends the game directly -- see updateDangerTimer's forgiveness timer" {
    var b: s.Board = .{};
    b.cellAt(c.SPAWN_ROWS, 0).state = .normal;
    doRise(&b);
    try testing.expect(!b.game_over);
}

test "updateDangerTimer keeps counting through an ordinary swap/fall at the ceiling, unlike a pop" {
    var b: s.Board = .{};
    b.cellAt(c.SPAWN_ROWS, 0).state = .falling; // busy, but not a pop/recycle -- still counts
    for (0..c.DANGER_FORGIVENESS_FRAMES - 1) |_| updateDangerTimer(&b);
    try testing.expect(!b.game_over);
    updateDangerTimer(&b);
    try testing.expect(b.game_over);
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

test "updateDangerTimer pauses (without resetting) while a match/garbage is actively popping" {
    var b: s.Board = .{};
    b.cellAt(c.SPAWN_ROWS, 0).state = .normal;
    for (0..c.DANGER_FORGIVENESS_FRAMES - 1) |_| updateDangerTimer(&b);
    try testing.expectEqual(c.DANGER_FORGIVENESS_FRAMES - 1, b.danger_timer);

    // A match starts resolving elsewhere on the board -- paused, not reset,
    // however long it takes (never counted as a swap-spam exploit).
    b.cellAt(5, 1).state = .popping;
    for (0..c.DANGER_FORGIVENESS_FRAMES * 3) |_| updateDangerTimer(&b);
    try testing.expectEqual(c.DANGER_FORGIVENESS_FRAMES - 1, b.danger_timer);
    try testing.expect(!b.game_over);

    // Once the pop finishes, it resumes from exactly where it left off.
    b.cellAt(5, 1).state = .empty;
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
    row_cache.shared_row_rng_state = 12345;
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
    row_cache.shared_row_rng_state = 999;

    // `b` caches index 0 first; `a` must see the identical result later.
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

test "awardMatchPoint tallies points and declares a set winner at POINTS_TO_WIN" {
    s.player_points = 0;
    s.cpu_points = 0;
    s.set_winner = .none;

    awardMatchPoint(.player);
    try testing.expectEqual(@as(u8, 1), s.player_points);
    try testing.expectEqual(s.Winner.none, s.set_winner); // not enough yet (POINTS_TO_WIN=2)

    awardMatchPoint(.draw); // awards nobody
    try testing.expectEqual(@as(u8, 1), s.player_points);
    try testing.expectEqual(@as(u8, 0), s.cpu_points);

    awardMatchPoint(.player);
    try testing.expectEqual(@as(u8, 2), s.player_points);
    try testing.expectEqual(s.Winner.player, s.set_winner);
}
