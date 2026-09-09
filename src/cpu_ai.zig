// The CPU opponent's move picker, chosen per the difficulty set on the title
// screen (see state.difficulty). Every level from 1-10 uses cpu_engine's
// actual move search (see configFor) -- lower levels are simply worse at it
// (a much higher chance to ignore the engine's pick and play a random legal
// swap instead, a shallower search, and a slower reaction time), not a
// different kind of AI. It picks at most one action per timer interval, but
// -- like a player, whose own input is never blocked by unrelated activity
// elsewhere on the board (see input.updateSwap) -- no longer waits for the
// *whole* board to go idle first: it reasons about (see cpu_grid.Grid.
// fromBoard) and can act on whatever's true right now, including cells
// that are still falling/landing/mid-swap elsewhere. sim.trySwap's own
// per-cell check is still what actually decides whether a given swap
// succeeds, exactly as it does for the player, so this never lets the CPU
// do anything a player couldn't also do from the same position.

const c = @import("constants.zig");
const s = @import("state.zig");
const sim = @import("sim.zig");
const board = @import("board.zig");
const engine = @import("cpu_engine.zig");

var move_timer: u32 = 0;

const DifficultyConfig = struct {
    move_interval: u32, // frames between moves -- lower is faster/more reactive
    depth: u8, // cpu_engine's search depth (see cpu_engine.evaluateMove)
    mistake_pct: u8, // 0-100: chance to ignore the engine's pick and play randomly instead
};

// All ten levels use the same engine (see cpu_engine.bestAction); they only
// differ in how often they listen to it. mistake_pct falls off steeply from
// level 1 to 10 so the low end still reads as genuinely weak (mostly
// flailing, occasionally stumbling into something) rather than merely slow.
fn configFor(level: u8) DifficultyConfig {
    return switch (level) {
        1 => .{ .move_interval = 40, .depth = 1, .mistake_pct = 70 },
        2 => .{ .move_interval = 32, .depth = 1, .mistake_pct = 55 },
        3 => .{ .move_interval = 26, .depth = 1, .mistake_pct = 40 },
        4 => .{ .move_interval = 20, .depth = 1, .mistake_pct = 28 },
        5 => .{ .move_interval = 17, .depth = 1, .mistake_pct = 18 },
        6 => .{ .move_interval = 14, .depth = 1, .mistake_pct = 10 },
        7 => .{ .move_interval = 12, .depth = 2, .mistake_pct = 6 },
        8 => .{ .move_interval = 11, .depth = 3, .mistake_pct = 3 },
        9 => .{ .move_interval = 9, .depth = 3, .mistake_pct = 1 },
        10 => .{ .move_interval = 8, .depth = 3, .mistake_pct = 0 },
        // state.difficulty is always clamped to 1-10 (see main.zig's title
        // screen) -- this is just a defensive fallback, not a real level.
        else => .{ .move_interval = 20, .depth = 1, .mistake_pct = 40 },
    };
}

fn randomMove(self: *s.Board) void {
    self.cursor_row = @intCast(self.randRange(c.VISIBLE_ROWS));
    self.cursor_col = @intCast(self.randRange(c.COLS - 1));
    sim.trySwap(self);
}

pub fn update(self: *s.Board) void {
    const cfg = configFor(s.difficulty);
    move_timer += 1;
    if (move_timer < cfg.move_interval) return;
    move_timer = 0;

    if (self.randRange(100) < cfg.mistake_pct) {
        randomMove(self);
        return;
    }

    const grid = engine.Grid.fromBoard(self);
    switch (engine.bestAction(grid, cfg.depth)) {
        .raise => board.tryManualRaise(self),
        .swap => |mv| {
            self.cursor_row = mv.row;
            self.cursor_col = mv.col;
            sim.trySwap(self);
        },
    }
}

const testing = @import("std").testing;

test "cpu AI stays put for the first move_interval-1 idle frames" {
    move_timer = 0;
    s.difficulty = 6; // move_interval 14 -- see configFor
    var b: s.Board = .{};
    const orig_row = b.cursor_row;
    const orig_col = b.cursor_col;
    for (0..configFor(s.difficulty).move_interval - 1) |_| update(&b);
    try testing.expectEqual(orig_row, b.cursor_row);
    try testing.expectEqual(orig_col, b.cursor_col);
}

test "cpu AI acts on an obvious winning swap even while the board is busy elsewhere" {
    move_timer = 0;
    s.difficulty = 10; // depth 3, mistake_pct 0 -- deterministic best play
    var b: s.Board = .{};
    // Same obvious winning swap as the "finds and plays" test below...
    b.cellAt(5 + c.SPAWN_ROWS, 0).* = .{ .color = 1, .state = .normal };
    b.cellAt(5 + c.SPAWN_ROWS, 1).* = .{ .color = 1, .state = .normal };
    b.cellAt(5 + c.SPAWN_ROWS, 2).* = .{ .color = 2, .state = .normal };
    b.cellAt(5 + c.SPAWN_ROWS, 3).* = .{ .color = 1, .state = .normal };
    // ...but with something unrelated still falling elsewhere, making
    // boardBusy() true. Unlike before, the CPU no longer waits for this to
    // settle first -- it still finds and plays the swap above.
    b.cellAt(5 + c.SPAWN_ROWS, 5).* = .{ .color = 3, .state = .falling };
    try testing.expect(b.boardBusy());

    for (0..configFor(s.difficulty).move_interval) |_| update(&b);

    try testing.expectEqual(@as(u8, 5), b.cursor_row);
    try testing.expectEqual(@as(u8, 2), b.cursor_col);
    try testing.expectEqual(s.CellState.swapping, b.cellAt(5 + c.SPAWN_ROWS, 2).state);
}

test "at an engine level, the cpu finds and plays an obvious winning swap" {
    move_timer = 0;
    s.difficulty = 10; // depth 3, mistake_pct 0 -- deterministic best play
    var b: s.Board = .{};
    // Row 5: 1,1,2,1 -- only swapping columns 2/3 completes a match. Nothing
    // else is on the board, so cpu_engine's own gravity pass (part of
    // scoring each candidate swap) shifts all four columns down by the same
    // amount, leaving them aligned exactly as here -- see
    // cpu_engine_test.zig's own "finds the swap that completes an immediate
    // match" test for the same setup and why it doesn't need a floor.
    b.cellAt(5 + c.SPAWN_ROWS, 0).* = .{ .color = 1, .state = .normal };
    b.cellAt(5 + c.SPAWN_ROWS, 1).* = .{ .color = 1, .state = .normal };
    b.cellAt(5 + c.SPAWN_ROWS, 2).* = .{ .color = 2, .state = .normal };
    b.cellAt(5 + c.SPAWN_ROWS, 3).* = .{ .color = 1, .state = .normal };

    for (0..configFor(s.difficulty).move_interval) |_| update(&b);

    try testing.expectEqual(@as(u8, 5), b.cursor_row);
    try testing.expectEqual(@as(u8, 2), b.cursor_col);
    try testing.expectEqual(s.CellState.swapping, b.cellAt(5 + c.SPAWN_ROWS, 2).state);
}

test "at an engine level, the cpu raises instead of swapping on an empty board" {
    move_timer = 0;
    s.difficulty = 10;
    var b: s.Board = .{};
    // Nothing to swap and nothing to lose -- cpu_engine.bestAction always
    // raises here (see its own "raises on a completely empty board" test).
    for (0..configFor(s.difficulty).move_interval) |_| update(&b);
    try testing.expectEqual(@as(u32, 1), b.manual_raise_elapsed);
}
