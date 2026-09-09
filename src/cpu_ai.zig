// The CPU opponent's move picker, chosen per the difficulty set on the title
// screen (see state.difficulty). Every level from 1-10 always plays
// cpu_engine's own actual best-scored move (see configFor) -- never a
// random or deliberately mistaken one. Lower levels are weaker because
// they see less and want less: a shallower search, a slower reaction time,
// and a much lower preference for a chain over an equivalently-sized flat
// match (so they play correctly, just myopically, grabbing whatever's
// immediately in front of them). It picks at most one action per timer
// interval, but
// -- like a player, whose own input is never blocked by unrelated activity
// elsewhere on the board (see input.updateSwap) -- no longer waits for the
// *whole* board to go idle first: it reasons about (see cpu_grid.Grid.
// fromBoard) and can act on whatever's true right now, including cells
// that are still falling/landing/mid-swap elsewhere.
//
// Crucially, the engine only ever *decides* a target cell -- it never
// teleports the cursor there. `target` is that decision, and every
// subsequent tick just steps the cursor one cell closer to it (exactly the
// single-cell-at-a-time movement input.moveCursor gives the player), only
// actually swapping once the cursor has genuinely arrived. This is what
// keeps the CPU bound to the same movement restriction a player has, rather
// than being able to act on any two cells anywhere on the board at will.
// sim.trySwap's own per-cell check is still what actually decides whether a
// given swap succeeds, exactly as it does for the player, so none of this
// ever lets the CPU do anything a player couldn't also do from the same
// position.

const c = @import("constants.zig");
const s = @import("state.zig");
const sim = @import("sim.zig");
const board = @import("board.zig");
const engine = @import("cpu_engine.zig");

var move_timer: u32 = 0;

// The move the cursor is currently walking toward -- null means "no target
// yet, decide one next tick" (see update). Cleared once the swap at the
// target actually goes through, or once there's nothing meaningful left to
// swap there any more (the board changed while walking over).
var target: ?engine.Move = null;

const DifficultyConfig = struct {
    move_interval: u32, // frames between cursor steps (deciding a new target counts as one step)
    depth: u8, // cpu_engine's search depth (see cpu_engine.evaluateMove)
    chain_weight: i32, // see cpu_engine.chain_weight -- how much a deeper chain is valued over an equivalent flat match
    raise_bias: i32 = 0, // see cpu_engine.raise_bias -- a nudge toward raising while there's plenty of room
};

// Every level uses the exact same engine (see cpu_engine.bestAction) and
// always plays its actual best-scored move -- no randomness, no deliberate
// mistakes. What varies between levels is the engine's own priorities and
// how much of it a level can even see: reaction speed (move_interval), how
// many moves ahead it searches (depth), and how much it specifically values
// a chain over an equivalently-sized flat match (chain_weight) -- a weak
// CPU still plays *correctly*, it just plays *myopically*, grabbing
// whatever match is right in front of it rather than reasoning its way
// toward a bigger chain, and reacts slower while doing it. The very top
// levels also get a small preference for raising while there's plenty of
// headroom (raise_bias -- see cpu_engine.raiseValue), building up more
// material to set up bigger combos with, instead of only ever raising out
// of material necessity.
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
        9 => .{ .move_interval = 9, .depth = 3, .chain_weight = 115, .raise_bias = 15 },
        10 => .{ .move_interval = 8, .depth = 3, .chain_weight = 130, .raise_bias = 20 },
        // state.difficulty is always clamped to 1-10 (see main.zig's title
        // screen) -- this is just a defensive fallback, not a real level.
        else => .{ .move_interval = 20, .depth = 1, .chain_weight = 50 },
    };
}

// Picks a fresh target: the engine's own best move, always -- see
// configFor. Raising happens immediately (it doesn't need the cursor to go
// anywhere), and `.none` just leaves the cursor exactly where it is.
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

    // Walk one cell closer, on whichever axis still disagrees -- row first,
    // then column, exactly one step per tick (see moveCursor/stepDas's own
    // single-step-per-eligible-frame shape for the player).
    if (self.cursor_row != mv.row) {
        self.cursor_row = if (mv.row > self.cursor_row) self.cursor_row + 1 else self.cursor_row - 1;
        return;
    }
    if (self.cursor_col != mv.col) {
        self.cursor_col = if (mv.col > self.cursor_col) self.cursor_col + 1 else self.cursor_col - 1;
        return;
    }

    // Arrived. The board may have changed since this target was picked
    // (something might still be settling, or may have popped away
    // entirely by now) -- give up on it without swapping if there's
    // genuinely nothing left to swap (garbage, or both cells now empty,
    // mirror sim.trySwap's own permanent rejection reasons), otherwise keep
    // retrying each tick until the cells actually become swappable, same as
    // the player's own buffered-swap retry (see input.canSwapAt).
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
    s.difficulty = 10; // depth 3, chain_weight 130 -- always plays its actual best move
    var b: s.Board = .{};
    // Row 5, col 2 is the target (see the "finds and plays" test below) --
    // starting cursor col already matches (default cursor_col == 2), so
    // only the row needs to move, from its default down to 5.
    b.cellAt(5 + c.SPAWN_ROWS, 0).* = .{ .color = 1, .state = .normal };
    b.cellAt(5 + c.SPAWN_ROWS, 1).* = .{ .color = 1, .state = .normal };
    b.cellAt(5 + c.SPAWN_ROWS, 2).* = .{ .color = 2, .state = .normal };
    b.cellAt(5 + c.SPAWN_ROWS, 3).* = .{ .color = 1, .state = .normal };
    const cfg = configFor(s.difficulty);
    const start_row = b.cursor_row;

    // Each action -- deciding a target, or moving one cell toward it -- only
    // ever happens once every move_interval ticks (see update's own timer
    // gate), so the first full interval only ever decides the target; the
    // cursor itself hasn't moved yet.
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
    s.difficulty = 10; // depth 3, chain_weight 130 -- always plays its actual best move
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

    // Exactly enough intervals to: decide the target (1), walk the row down
    // from its default (9) to the target (5, 4 steps), then execute the
    // swap on arrival (1) -- 6 intervals total. Deliberately not a much
    // larger budget: once the swap lands the board changes and the CPU will
    // immediately go decide its *next* target elsewhere, which would move
    // the cursor away again and make a looser bound flaky.
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
    s.difficulty = 10; // depth 3, chain_weight 130
    var b: s.Board = .{};
    // Same (row + 2*col) % 5 board used by cpu_engine_test's own "bestAction
    // does nothing ..." test -- no swap can ever improve on it or set off a
    // match, and there's plenty of material with no dangerous height, so
    // bestAction should return .none every single decide tick. This is the
    // direct regression test for the reported "spins forever" bug: without
    // the epsilon check, the engine would always find *some* swap whose
    // structural score differs from the current one by a hair and chase it
    // forever, even though nothing is actually being accomplished.
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
