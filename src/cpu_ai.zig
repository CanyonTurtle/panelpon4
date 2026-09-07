// The CPU opponent's move picker, chosen per the difficulty set on the title
// screen (see state.difficulty). Levels 1-4 are a deliberately simple
// random-move flipper (the original v1 design -- it just pokes at a random
// swap every so often, like a distracted player) at increasing speed;
// levels 5-10 hand off to cpu_engine's actual move search instead, at
// increasing strength (see configFor for exactly how each level differs).
// Every level still waits for the board to settle first, like a player
// naturally would, and picks at most one move per timer interval.

const c = @import("constants.zig");
const s = @import("state.zig");
const sim = @import("sim.zig");
const engine = @import("cpu_engine.zig");

var move_timer: u32 = 0;

const DifficultyConfig = struct {
    move_interval: u32, // frames between moves -- lower is faster/more reactive
    engine_depth: u8, // 0 = pure random (levels 1-4); otherwise cpu_engine's search depth
    mistake_pct: u8, // 0-100: chance to ignore the engine's pick and play randomly instead
};

// Levels 1-4: same random flipper, just faster each step. Levels 5-10: the
// engine, getting both faster and more reliable (less random.y move_interval,
// deeper search, lower mistake_pct) as level increases, so the difficulty
// curve is smooth across the random/engine boundary rather than a sudden
// jump in kind.
fn configFor(level: u8) DifficultyConfig {
    return switch (level) {
        1 => .{ .move_interval = 45, .engine_depth = 0, .mistake_pct = 0 },
        2 => .{ .move_interval = 32, .engine_depth = 0, .mistake_pct = 0 },
        3 => .{ .move_interval = 20, .engine_depth = 0, .mistake_pct = 0 },
        4 => .{ .move_interval = 12, .engine_depth = 0, .mistake_pct = 0 },
        5 => .{ .move_interval = 26, .engine_depth = 1, .mistake_pct = 45 },
        6 => .{ .move_interval = 22, .engine_depth = 1, .mistake_pct = 30 },
        7 => .{ .move_interval = 18, .engine_depth = 1, .mistake_pct = 15 },
        8 => .{ .move_interval = 15, .engine_depth = 2, .mistake_pct = 8 },
        9 => .{ .move_interval = 11, .engine_depth = 2, .mistake_pct = 3 },
        10 => .{ .move_interval = 8, .engine_depth = 2, .mistake_pct = 0 },
        // state.difficulty is always clamped to 1-10 (see main.zig's title
        // screen) -- this is just a defensive fallback, not a real level.
        else => .{ .move_interval = 20, .engine_depth = 0, .mistake_pct = 0 },
    };
}

fn randomMove(self: *s.Board) void {
    self.cursor_row = @intCast(self.randRange(c.VISIBLE_ROWS));
    self.cursor_col = @intCast(self.randRange(c.COLS - 1));
    sim.trySwap(self);
}

pub fn update(self: *s.Board) void {
    if (self.boardBusy()) return; // wait for the board to settle, like a player naturally would
    const cfg = configFor(s.difficulty);
    move_timer += 1;
    if (move_timer < cfg.move_interval) return;
    move_timer = 0;

    if (cfg.engine_depth == 0 or self.randRange(100) < cfg.mistake_pct) {
        randomMove(self);
        return;
    }
    const grid = engine.Grid.fromBoard(self);
    if (engine.bestMove(grid, cfg.engine_depth)) |mv| {
        self.cursor_row = mv.row;
        self.cursor_col = mv.col;
        sim.trySwap(self);
    } else {
        randomMove(self);
    }
}

const testing = @import("std").testing;

test "cpu AI stays put for the first move_interval-1 idle frames" {
    move_timer = 0;
    s.difficulty = 3; // move_interval 20, pure random -- see configFor
    var b: s.Board = .{};
    const orig_row = b.cursor_row;
    const orig_col = b.cursor_col;
    for (0..configFor(s.difficulty).move_interval - 1) |_| update(&b);
    try testing.expectEqual(orig_row, b.cursor_row);
    try testing.expectEqual(orig_col, b.cursor_col);
}

test "cpu AI waits while its board is busy" {
    move_timer = 0;
    s.difficulty = 3;
    var b: s.Board = .{};
    b.cellAt(0, 0).state = .falling;
    const orig_row = b.cursor_row;
    const orig_col = b.cursor_col;
    for (0..configFor(s.difficulty).move_interval * 2) |_| update(&b);
    try testing.expectEqual(orig_row, b.cursor_row);
    try testing.expectEqual(orig_col, b.cursor_col);
}

test "at an engine level, the cpu finds and plays an obvious winning swap" {
    move_timer = 0;
    s.difficulty = 10; // engine_depth 2, mistake_pct 0 -- deterministic best play
    var b: s.Board = .{};
    // Row 5: 1,1,2,1 -- only swapping columns 2/3 completes a match. Nothing
    // else is on the board, so cpu_engine's own gravity pass (part of
    // scoring each candidate swap) shifts all four columns down by the same
    // amount, leaving them aligned exactly as here -- see
    // cpu_engine_test.zig's own "finds the swap that completes an immediate
    // match" test for the same setup and why it doesn't need a floor.
    b.cellAt(5, 0).* = .{ .color = 1, .state = .normal };
    b.cellAt(5, 1).* = .{ .color = 1, .state = .normal };
    b.cellAt(5, 2).* = .{ .color = 2, .state = .normal };
    b.cellAt(5, 3).* = .{ .color = 1, .state = .normal };

    for (0..configFor(s.difficulty).move_interval) |_| update(&b);

    try testing.expectEqual(@as(u8, 5), b.cursor_row);
    try testing.expectEqual(@as(u8, 2), b.cursor_col);
    try testing.expectEqual(s.CellState.swapping, b.cellAt(5, 2).state);
}
