// The CPU opponent's move picker (see state.difficulty). Every level always
// plays cpu_engine's real best move; only depth/speed/chain bias vary.

const c = @import("constants.zig");
const s = @import("state.zig");
const sim = @import("sim.zig");
const board = @import("board.zig");
const engine = @import("cpu_engine.zig");

var move_timer: u32 = 0;

// Cursor's walk destination; null means "decide next tick" (see update).
// Cleared once swapped, or once nothing's left to swap there.
var target: ?engine.Move = null;

const DifficultyConfig = struct {
    move_interval: u32, // frames between cursor steps (deciding a new target counts as one step)
    depth: u8, // cpu_engine's search depth (see cpu_engine.evaluateMove)
    chain_weight: i32, // see cpu_engine.chain_weight -- how much a deeper chain is valued over an equivalent flat match
    raise_bias: i32 = 0, // see cpu_engine.raise_bias -- a nudge toward raising while there's plenty of room
};

// Every level plays the engine's real best move; only reaction speed, depth,
// and chain_weight/raise_bias vary, so a weak CPU plays correctly, just myopically.
fn configFor(level: u8) DifficultyConfig {
    return switch (level) {
        1 => .{ .move_interval = 40, .depth = 1, .chain_weight = 10 },
        2 => .{ .move_interval = 34, .depth = 1, .chain_weight = 20 },
        3 => .{ .move_interval = 28, .depth = 1, .chain_weight = 35 },
        4 => .{ .move_interval = 24, .depth = 1, .chain_weight = 50 },
        5 => .{ .move_interval = 20, .depth = 2, .chain_weight = 65 },
        6 => .{ .move_interval = 17, .depth = 2, .chain_weight = 80 },
        7 => .{ .move_interval = 12, .depth = 2, .chain_weight = 100 },
        8 => .{ .move_interval = 11, .depth = 3, .chain_weight = 100, .raise_bias = 10 },
        9 => .{ .move_interval = 9, .depth = 3, .chain_weight = 100, .raise_bias = 15 },
        10 => .{ .move_interval = 8, .depth = 3, .chain_weight = 100, .raise_bias = 20 },
        // state.difficulty is always clamped to 1-10 (see main.zig's title
        // screen) -- this is just a defensive fallback, not a real level.
        else => .{ .move_interval = 20, .depth = 1, .chain_weight = 50 },
    };
}

// Picks a fresh target: always the engine's best move (see configFor).
// Raising happens immediately; `.none` leaves the cursor where it is.
fn pickTarget(self: *s.Board, cfg: DifficultyConfig) void {
    engine.chain_weight = cfg.chain_weight;
    engine.raise_bias = cfg.raise_bias;
    const grid = engine.Grid.fromBoard(self);
    switch (engine.bestAction(grid, cfg.depth)) {
        .raise => board.tryManualRaise(self),
        .swap => |mv| target = mv,
        .none => {},
    }
}

pub fn update(self: *s.Board) void {
    const cfg = configFor(s.difficulty);
    move_timer += 1;
    if (move_timer < cfg.move_interval) return;
    move_timer = 0;

    const mv = target orelse {
        pickTarget(self, cfg);
        return;
    };

    // Walk one cell closer, row first then column, one step per tick --
    // same single-step shape as the player's own moveCursor/stepDas.
    if (self.cursor_row != mv.row) {
        self.cursor_row = if (mv.row > self.cursor_row) self.cursor_row + 1 else self.cursor_row - 1;
        return;
    }
    if (self.cursor_col != mv.col) {
        self.cursor_col = if (mv.col > self.cursor_col) self.cursor_col + 1 else self.cursor_col - 1;
        return;
    }

    // Arrived. Abandon the target if it's now permanently unswappable
    // (garbage or both empty), else keep retrying until swappable.
    const abs_row = mv.row + c.SPAWN_ROWS;
    const a = self.cellAt(abs_row, mv.col);
    const b = self.cellAt(abs_row, mv.col + 1);
    if (a.is_garbage or b.is_garbage or (a.state == .empty and b.state == .empty)) {
        target = null;
    } else if (sim.swappable(a.state) and sim.swappable(b.state)) {
        sim.trySwap(self);
        target = null;
    }
}

const testing = @import("std").testing;

test "cpu AI stays put for the first move_interval-1 idle frames" {
    move_timer = 0;
    target = null;
    s.difficulty = 6; // move_interval 17 -- see configFor
    var b: s.Board = .{};
    const orig_row = b.cursor_row;
    const orig_col = b.cursor_col;
    for (0..configFor(s.difficulty).move_interval - 1) |_| update(&b);
    try testing.expectEqual(orig_row, b.cursor_row);
    try testing.expectEqual(orig_col, b.cursor_col);
}

test "cpu AI walks its cursor one cell at a time toward the engine's target, never teleporting" {
    move_timer = 0;
    target = null;
    s.difficulty = 10; // depth 3, chain_weight 100 -- always plays its actual best move
    var b: s.Board = .{};
    // Row 5, col 2 is the target; cursor_col already defaults to 2, so
    // only the row needs to move, from its default down to 5.
    b.cellAt(5 + c.SPAWN_ROWS, 0).* = .{ .color = 1, .state = .normal };
    b.cellAt(5 + c.SPAWN_ROWS, 1).* = .{ .color = 1, .state = .normal };
    b.cellAt(5 + c.SPAWN_ROWS, 2).* = .{ .color = 2, .state = .normal };
    b.cellAt(5 + c.SPAWN_ROWS, 3).* = .{ .color = 1, .state = .normal };
    const cfg = configFor(s.difficulty);
    const start_row = b.cursor_row;

    // Each action (deciding a target, or moving one cell) only happens once
    // per move_interval ticks, so the first interval only decides the target.
    for (0..cfg.move_interval) |_| update(&b);
    try testing.expectEqual(start_row, b.cursor_row);

    // The next interval takes exactly one step toward it, never further.
    for (0..cfg.move_interval) |_| update(&b);
    const after_one_step = b.cursor_row;
    try testing.expect(after_one_step != start_row);
    try testing.expect((if (start_row > after_one_step) start_row - after_one_step else after_one_step - start_row) == 1);
    try testing.expectEqual(s.CellState.normal, b.cellAt(5 + c.SPAWN_ROWS, 2).state); // not swapped yet -- still walking
}

test "at an engine level, the cpu finds and plays an obvious winning swap" {
    move_timer = 0;
    target = null;
    s.difficulty = 10; // depth 3, chain_weight 100 -- always plays its actual best move
    var b: s.Board = .{};
    // Row 5: 1,1,2,1 -- only swapping cols 2/3 completes a match. No floor
    // needed: gravity shifts all 4 columns down equally, keeping them aligned.
    b.cellAt(5 + c.SPAWN_ROWS, 0).* = .{ .color = 1, .state = .normal };
    b.cellAt(5 + c.SPAWN_ROWS, 1).* = .{ .color = 1, .state = .normal };
    b.cellAt(5 + c.SPAWN_ROWS, 2).* = .{ .color = 2, .state = .normal };
    b.cellAt(5 + c.SPAWN_ROWS, 3).* = .{ .color = 1, .state = .normal };

    // 6 intervals: decide (1) + walk 4 rows (4) + swap (1). Deliberately tight
    // -- once it swaps the CPU picks a new target, which would move the cursor again.
    for (0..6 * configFor(s.difficulty).move_interval) |_| update(&b);

    try testing.expectEqual(@as(u8, 5), b.cursor_row);
    try testing.expectEqual(@as(u8, 2), b.cursor_col);
    try testing.expectEqual(s.CellState.swapping, b.cellAt(5 + c.SPAWN_ROWS, 2).state);
}

test "at an engine level, the cpu raises instead of swapping on an empty board" {
    move_timer = 0;
    target = null;
    s.difficulty = 10;
    var b: s.Board = .{};
    // Nothing to swap and nothing to lose -- cpu_engine.bestAction always
    // raises here (see its own "raises on a completely empty board" test).
    for (0..configFor(s.difficulty).move_interval) |_| update(&b);
    try testing.expectEqual(@as(u32, 1), b.manual_raise_elapsed);
}

test "cpu AI sits still (no spinning) when there's genuinely no good move" {
    move_timer = 0;
    target = null;
    s.difficulty = 10; // depth 3, chain_weight 100
    var b: s.Board = .{};
    var lr: u8 = 0;
    while (lr < c.VISIBLE_ROWS) : (lr += 1) {
        for (0..c.COLS) |col_usize| {
            const col: u8 = @intCast(col_usize);
            b.cellAt(lr + c.SPAWN_ROWS, col).* = .{ .color = @intCast((@as(u32, lr) + 2 * col) % 5), .state = .normal };
        }
    }
    const start_row = b.cursor_row;
    const start_col = b.cursor_col;
    for (0..40 * configFor(s.difficulty).move_interval) |_| update(&b);
    try testing.expectEqual(start_row, b.cursor_row);
    try testing.expectEqual(start_col, b.cursor_col);
}

test "cpu AI on arrival abandons a stale target when unswappable, else retries" {
    s.difficulty = 10; // depth 3, chain_weight 100 -- always plays its actual best move
    const cfg = configFor(s.difficulty);
    var b: s.Board = .{};
    b.cursor_row = 5;
    b.cursor_col = 2;

    // Garbage at the target: abandon without swapping.
    move_timer = 0;
    target = .{ .row = 5, .col = 2 };
    b.cellAt(5 + c.SPAWN_ROWS, 2).* = .{ .color = 1, .state = .normal, .is_garbage = true };
    b.cellAt(5 + c.SPAWN_ROWS, 3).* = .{ .color = 1, .state = .normal };
    for (0..cfg.move_interval) |_| update(&b);
    try testing.expectEqual(@as(?engine.Move, null), target);
    try testing.expectEqual(s.CellState.normal, b.cellAt(5 + c.SPAWN_ROWS, 2).state);

    // Both cells empty: abandon without swapping.
    move_timer = 0;
    target = .{ .row = 5, .col = 2 };
    b.cellAt(5 + c.SPAWN_ROWS, 2).* = .{ .state = .empty };
    b.cellAt(5 + c.SPAWN_ROWS, 3).* = .{ .state = .empty };
    for (0..cfg.move_interval) |_| update(&b);
    try testing.expectEqual(@as(?engine.Move, null), target);

    // Not yet swappable (still falling): keep retrying each tick instead of
    // abandoning, then swap once it becomes swappable.
    move_timer = 0;
    target = .{ .row = 5, .col = 2 };
    b.cellAt(5 + c.SPAWN_ROWS, 2).* = .{ .color = 1, .state = .falling };
    b.cellAt(5 + c.SPAWN_ROWS, 3).* = .{ .color = 2, .state = .normal };
    for (0..cfg.move_interval) |_| update(&b);
    try testing.expect(target != null);
    try testing.expectEqual(s.CellState.falling, b.cellAt(5 + c.SPAWN_ROWS, 2).state);

    b.cellAt(5 + c.SPAWN_ROWS, 2).* = .{ .color = 1, .state = .normal };
    for (0..cfg.move_interval) |_| update(&b);
    try testing.expectEqual(@as(?engine.Move, null), target);
    try testing.expectEqual(s.CellState.swapping, b.cellAt(5 + c.SPAWN_ROWS, 2).state);
}
