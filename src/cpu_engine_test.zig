const std = @import("std");
const testing = std.testing;
const c = @import("constants.zig");
const s = @import("state.zig");
const engine = @import("cpu_engine.zig");

test "fromBoard reads color, garbage, and in-flight cells correctly" {
    var b: s.Board = .{};
    b.cellAt(10, 0).* = .{ .color = 2, .state = .normal };
    b.cellAt(10, 1).* = .{ .state = .normal, .is_garbage = true };
    // Falling/landing/swapping cells already have their final color/column
    // decided, so the AI reads them as real content, not holes.
    b.cellAt(10, 2).* = .{ .color = 3, .state = .falling };
    b.cellAt(10, 3).* = .{ .color = 4, .state = .landing };
    b.cellAt(10, 4).* = .{ .color = 1, .state = .swapping };
    // A pop/recycle's eventual outcome is genuinely undecided from here, so
    // these still read as empty.
    b.cellAt(10, 5).* = .{ .color = 2, .state = .popping };

    const grid = engine.Grid.fromBoard(&b);
    try testing.expectEqual(@as(i8, 2), grid.cell[0][0]);
    try testing.expectEqual(engine.GARBAGE, grid.cell[0][1]);
    try testing.expectEqual(@as(i8, 3), grid.cell[0][2]);
    try testing.expectEqual(@as(i8, 4), grid.cell[0][3]);
    try testing.expectEqual(@as(i8, 1), grid.cell[0][4]);
    try testing.expectEqual(engine.EMPTY, grid.cell[0][5]);
}

test "bestMove sees a currently-falling cell's true color, not an empty hole" {
    var b: s.Board = .{};
    // Same fixture as "finds the swap that completes an immediate match"
    // below, except the piece landing in the match is still .falling.
    b.cellAt(15, 0).* = .{ .color = 1, .state = .normal };
    b.cellAt(15, 1).* = .{ .color = 1, .state = .normal };
    b.cellAt(15, 2).* = .{ .color = 2, .state = .normal };
    b.cellAt(15, 3).* = .{ .color = 1, .state = .falling };

    const grid = engine.Grid.fromBoard(&b);
    const mv = engine.bestMove(grid, 1) orelse return error.NoMoveFound;
    try testing.expectEqual(@as(u8, 5), mv.row);
    try testing.expectEqual(@as(u8, 2), mv.col);
}

test "bestMove finds the swap that completes an immediate match" {
    var b: s.Board = .{};
    // Row 5: 1,1,2,1 -- swapping columns 2/3 completes a run of three 1's.
    b.cellAt(15, 0).* = .{ .color = 1, .state = .normal };
    b.cellAt(15, 1).* = .{ .color = 1, .state = .normal };
    b.cellAt(15, 2).* = .{ .color = 2, .state = .normal };
    b.cellAt(15, 3).* = .{ .color = 1, .state = .normal };

    const grid = engine.Grid.fromBoard(&b);
    const mv = engine.bestMove(grid, 1) orelse return error.NoMoveFound;
    try testing.expectEqual(@as(u8, 5), mv.row);
    try testing.expectEqual(@as(u8, 2), mv.col);
}

test "bestMove never proposes swapping a garbage cell, and still finds a real winning move next to one" {
    var b: s.Board = .{};
    // Column 0 is garbage -- illegal to swap. Only the (row0, col3) swap
    // actually completes a match; every other legal pairing does nothing.
    b.cellAt(10, 0).* = .{ .state = .normal, .is_garbage = true };
    b.cellAt(10, 1).* = .{ .color = 1, .state = .normal };
    b.cellAt(10, 2).* = .{ .color = 1, .state = .normal };
    b.cellAt(10, 3).* = .{ .color = 2, .state = .normal };
    b.cellAt(10, 4).* = .{ .color = 1, .state = .normal };

    const grid = engine.Grid.fromBoard(&b);
    const mv = engine.bestMove(grid, 1) orelse return error.NoMoveFound;
    try testing.expectEqual(@as(u8, 0), mv.row);
    try testing.expectEqual(@as(u8, 3), mv.col);
}

test "bestMove never proposes swapping two cells of the identical color, even when a lookahead bonus would otherwise make it look best" {
    var b: s.Board = .{};
    // (5,2)/(5,3) are the SAME color -- a strict no-op must never be a legal
    // candidate; (8,0)-(8,3) below is a genuine winning swap elsewhere.
    b.cellAt(5 + c.SPAWN_ROWS, 2).* = .{ .color = 1, .state = .normal };
    b.cellAt(5 + c.SPAWN_ROWS, 3).* = .{ .color = 1, .state = .normal };
    b.cellAt(8 + c.SPAWN_ROWS, 0).* = .{ .color = 2, .state = .normal };
    b.cellAt(8 + c.SPAWN_ROWS, 1).* = .{ .color = 2, .state = .normal };
    b.cellAt(8 + c.SPAWN_ROWS, 2).* = .{ .color = 3, .state = .normal };
    b.cellAt(8 + c.SPAWN_ROWS, 3).* = .{ .color = 2, .state = .normal };

    const grid = engine.Grid.fromBoard(&b);
    const mv = engine.bestMove(grid, 3) orelse return error.NoMoveFound;
    try testing.expect(!(mv.row == 5 and mv.col == 2));
}

test "bestMove on a completely empty board finds no legal swap" {
    var b: s.Board = .{};
    const grid = engine.Grid.fromBoard(&b);
    try testing.expectEqual(@as(?engine.Move, null), engine.bestMove(grid, 1));
}

test "bestMove prefers a swap that sets off a chain over an equally-sized flat match elsewhere" {
    var b: s.Board = .{};
    // Every column is gap-free down to row 11, matching an idle real board.

    // Columns 0-3: swapping 2/3 slides a matching 0 into row 10, clearing a
    // cell that was splitting a stack of three 3's -- a genuine second pass.
    b.cellAt(18, 0).* = .{ .color = 3, .state = .normal };
    b.cellAt(19, 0).* = .{ .color = 3, .state = .normal };
    b.cellAt(20, 0).* = .{ .color = 0, .state = .normal };
    b.cellAt(21, 0).* = .{ .color = 3, .state = .normal };
    b.cellAt(20, 1).* = .{ .color = 0, .state = .normal };
    b.cellAt(21, 1).* = .{ .color = 4, .state = .normal }; // filler, just for gap-free support
    b.cellAt(20, 2).* = .{ .color = 2, .state = .normal };
    b.cellAt(21, 2).* = .{ .color = 1, .state = .normal }; // filler
    b.cellAt(20, 3).* = .{ .color = 0, .state = .normal };
    b.cellAt(21, 3).* = .{ .color = 4, .state = .normal }; // filler

    // Columns 4-5: an unrelated, equally-sized flat match with nothing left
    // to cascade into, for comparison against the chain above.
    b.cellAt(19, 4).* = .{ .color = 1, .state = .normal };
    b.cellAt(20, 4).* = .{ .color = 4, .state = .normal };
    b.cellAt(21, 4).* = .{ .color = 1, .state = .normal };
    b.cellAt(20, 5).* = .{ .color = 1, .state = .normal };
    b.cellAt(21, 5).* = .{ .color = 2, .state = .normal }; // filler

    const grid = engine.Grid.fromBoard(&b);
    const mv = engine.bestMove(grid, 1) orelse return error.NoMoveFound;
    try testing.expectEqual(@as(u8, 10), mv.row);
    try testing.expectEqual(@as(u8, 2), mv.col);
}

test "chain_weight scales only the chain-continuation bonus, not a flat match's own face value" {
    defer engine.chain_weight = 100; // restore the default so no other test sees this

    // A single-pass match: chain_depth never exceeds 1, so there's no chain
    // bonus to scale -- score must be identical regardless of chain_weight.
    var g_flat: engine.Grid = .{};
    g_flat.cell[10][0] = 1;
    g_flat.cell[10][1] = 1;
    g_flat.cell[10][2] = 1;
    engine.chain_weight = 10;
    const flat_low = engine.simulateCascade(&g_flat);
    var g_flat2: engine.Grid = .{};
    g_flat2.cell[10][0] = 1;
    g_flat2.cell[10][1] = 1;
    g_flat2.cell[10][2] = 1;
    engine.chain_weight = 130;
    const flat_high = engine.simulateCascade(&g_flat2);
    try testing.expectEqual(flat_low, flat_high);

    // The post-swap board from the "prefers a chain" test above, which
    // genuinely cascades in two passes -- low weight stays near flat value.
    var g_chain: engine.Grid = .{};
    g_chain.cell[8][0] = 3;
    g_chain.cell[9][0] = 3;
    g_chain.cell[10][0] = 0;
    g_chain.cell[10][1] = 0;
    g_chain.cell[10][2] = 0; // post-swap: was 2 pre-swap
    g_chain.cell[10][3] = 2; // post-swap: was 0 pre-swap
    g_chain.cell[11][0] = 3;
    g_chain.cell[11][1] = 4;
    g_chain.cell[11][2] = 1;
    g_chain.cell[11][3] = 4;
    var g_chain_low = g_chain;
    engine.chain_weight = 10;
    const chain_low = engine.simulateCascade(&g_chain_low);
    var g_chain_high = g_chain;
    engine.chain_weight = 130;
    const chain_high = engine.simulateCascade(&g_chain_high);
    // Pass 1: 3 blocks * BASE_WEIGHT(10) = 30, always. Pass 2 (chain_cubed
    // 8): weight 10 -> +0 bonus -> 30; weight 130 -> +9 bonus -> 300.
    try testing.expectEqual(@as(i32, 60), chain_low);
    try testing.expectEqual(@as(i32, 330), chain_high);
}

test "raiseValue treats a mostly-garbage board as short on material, same as an empty one" {
    // One sparse row of garbage, low enough that heightDangerPenalty is 0
    // for both grids -- isolates the realCellCount comparison from height.
    var b_garbage: s.Board = .{};
    for (0..c.COLS) |col| b_garbage.cellAt(11 + c.SPAWN_ROWS, @intCast(col)).* = .{ .state = .normal, .is_garbage = true };
    const grid_garbage = engine.Grid.fromBoard(&b_garbage);
    const grid_empty: engine.Grid = .{};
    try testing.expectEqual(engine.raiseValue(grid_empty), engine.raiseValue(grid_garbage));
}

test "bestAction raises on a completely empty board" {
    var b: s.Board = .{};
    const grid = engine.Grid.fromBoard(&b);
    try testing.expectEqual(engine.Action.raise, engine.bestAction(grid, 1));
}

test "bestAction raises when material is scarce and no swap accomplishes anything" {
    var b: s.Board = .{};
    // Five distinct colors, one cell each -- no swap can complete a run,
    // and material is far below LOW_MATERIAL_THRESHOLD.
    b.cellAt(21, 0).* = .{ .color = 0, .state = .normal };
    b.cellAt(21, 1).* = .{ .color = 1, .state = .normal };
    b.cellAt(21, 2).* = .{ .color = 2, .state = .normal };
    b.cellAt(21, 3).* = .{ .color = 3, .state = .normal };
    b.cellAt(21, 4).* = .{ .color = 4, .state = .normal };

    const grid = engine.Grid.fromBoard(&b);
    try testing.expectEqual(engine.Action.raise, engine.bestAction(grid, 1));
}

test "bestAction still takes an obvious winning swap even with scarce material" {
    var b: s.Board = .{};
    // Material is far below threshold, but a real match always outscores
    // raising by a wide enough margin to still win.
    b.cellAt(15, 0).* = .{ .color = 1, .state = .normal };
    b.cellAt(15, 1).* = .{ .color = 1, .state = .normal };
    b.cellAt(15, 2).* = .{ .color = 2, .state = .normal };
    b.cellAt(15, 3).* = .{ .color = 1, .state = .normal };

    const grid = engine.Grid.fromBoard(&b);
    const action = engine.bestAction(grid, 1);
    try testing.expectEqual(engine.Action{ .swap = .{ .row = 5, .col = 2 } }, action);
}

test "bestAction refuses to raise a skinny pillar that's already dangerously tall, even with scarce material" {
    var b: s.Board = .{};
    // One column stacked 10 rows high, nothing else: material is scarce
    // (would favor raising) but the column is already near the top.
    var lr: u8 = 2;
    while (lr < 12) : (lr += 1) {
        b.cellAt(lr + c.SPAWN_ROWS, 0).* = .{ .color = @intCast(lr % 2), .state = .normal };
    }

    const grid = engine.Grid.fromBoard(&b);
    const action = engine.bestAction(grid, 1);
    try testing.expect(action != .raise);
}

test "bestAction does nothing when the best swap and raising are both within epsilon of the status quo" {
    var b: s.Board = .{};
    // A (row + 2*col) % 5 pattern: no swap can improve adjacency/match, and
    // material (72 cells) is plentiful, so raising is disfavored too.
    var lr: u8 = 0;
    while (lr < c.VISIBLE_ROWS) : (lr += 1) {
        for (0..c.COLS) |col_usize| {
            const col: u8 = @intCast(col_usize);
            b.cellAt(lr + c.SPAWN_ROWS, col).* = .{ .color = @intCast((@as(u32, lr) + 2 * col) % 5), .state = .normal };
        }
    }

    const grid = engine.Grid.fromBoard(&b);
    const action = engine.bestAction(grid, 1);
    try testing.expectEqual(engine.Action.none, action);
}

test "raiseValue penalizes a dangerously tall column enough to outweigh scarce material" {
    var b: s.Board = .{};
    var lr: u8 = 2;
    while (lr < 12) : (lr += 1) {
        b.cellAt(lr + c.SPAWN_ROWS, 0).* = .{ .color = @intCast(lr % 2), .state = .normal };
    }
    const grid = engine.Grid.fromBoard(&b);
    try testing.expect(engine.raiseValue(grid) < 0);
}

test "raise_bias nudges raiseValue up only while there's comfortably more headroom than the danger check requires" {
    // A column 6 rows tall -- post-raise height 7, right at the "plenty of
    // room" gate's boundary (PLENTY_OF_ROOM_MARGIN = DANGER_MARGIN + 2 = 5).
    var b_room: s.Board = .{};
    var lr: u8 = 6;
    while (lr < 12) : (lr += 1) {
        b_room.cellAt(lr + c.SPAWN_ROWS, 0).* = .{ .color = @intCast(lr % 2), .state = .normal };
    }
    const grid_room = engine.Grid.fromBoard(&b_room);
    engine.raise_bias = 0;
    const room_without_bias = engine.raiseValue(grid_room);
    engine.raise_bias = 20;
    try testing.expectEqual(room_without_bias + 20, engine.raiseValue(grid_room));

    // One row taller -- post-raise height 8, just past the gate, so
    // raise_bias no longer applies even though it's nowhere near danger.
    var b_tight: s.Board = .{};
    lr = 5;
    while (lr < 12) : (lr += 1) {
        b_tight.cellAt(lr + c.SPAWN_ROWS, 0).* = .{ .color = @intCast(lr % 2), .state = .normal };
    }
    const grid_tight = engine.Grid.fromBoard(&b_tight);
    engine.raise_bias = 0;
    const tight_without_bias = engine.raiseValue(grid_tight);
    engine.raise_bias = 20;
    defer engine.raise_bias = 0; // restore the default so no other test sees this
    try testing.expectEqual(tight_without_bias, engine.raiseValue(grid_tight));
}

test "bestMove still finds the winning swap at deeper, beam-pruned search depths" {
    var b: s.Board = .{};
    b.cellAt(15, 0).* = .{ .color = 1, .state = .normal };
    b.cellAt(15, 1).* = .{ .color = 1, .state = .normal };
    b.cellAt(15, 2).* = .{ .color = 2, .state = .normal };
    b.cellAt(15, 3).* = .{ .color = 1, .state = .normal };

    const grid = engine.Grid.fromBoard(&b);
    // Depths 2-4 route the lookahead through beam pruning -- an obvious
    // win should never be lost to it.
    for ([_]u8{ 2, 3, 4 }) |depth| {
        const mv = engine.bestMove(grid, depth) orelse return error.NoMoveFound;
        try testing.expectEqual(@as(u8, 5), mv.row);
        try testing.expectEqual(@as(u8, 2), mv.col);
    }
}

test "bestMove still prefers a chain-triggering swap over a flat match at deeper, beam-pruned search depths" {
    var b: s.Board = .{};
    // Identical fixture to the depth-1 version of this same test above --
    // see its own comments for exactly why each cell is where it is.
    b.cellAt(18, 0).* = .{ .color = 3, .state = .normal };
    b.cellAt(19, 0).* = .{ .color = 3, .state = .normal };
    b.cellAt(20, 0).* = .{ .color = 0, .state = .normal };
    b.cellAt(21, 0).* = .{ .color = 3, .state = .normal };
    b.cellAt(20, 1).* = .{ .color = 0, .state = .normal };
    b.cellAt(21, 1).* = .{ .color = 4, .state = .normal };
    b.cellAt(20, 2).* = .{ .color = 2, .state = .normal };
    b.cellAt(21, 2).* = .{ .color = 1, .state = .normal };
    b.cellAt(20, 3).* = .{ .color = 0, .state = .normal };
    b.cellAt(21, 3).* = .{ .color = 4, .state = .normal };

    b.cellAt(19, 4).* = .{ .color = 1, .state = .normal };
    b.cellAt(20, 4).* = .{ .color = 4, .state = .normal };
    b.cellAt(21, 4).* = .{ .color = 1, .state = .normal };
    b.cellAt(20, 5).* = .{ .color = 1, .state = .normal };
    b.cellAt(21, 5).* = .{ .color = 2, .state = .normal };

    const grid = engine.Grid.fromBoard(&b);
    for ([_]u8{ 3, 4 }) |depth| {
        const mv = engine.bestMove(grid, depth) orelse return error.NoMoveFound;
        try testing.expectEqual(@as(u8, 10), mv.row);
        try testing.expectEqual(@as(u8, 2), mv.col);
    }
}

test "a densely packed board (many more legal swaps than the beam width) still resolves cleanly at deep search depths" {
    var b: s.Board = .{};
    // A 3-color diagonal stripe: nothing pre-matches, but nearly every pair
    // is a legal swap -- well more than BEAM_WIDTH, exercising real pruning.
    for (0..12) |row| {
        for (0..6) |col| {
            b.cellAt(@intCast(row + c.SPAWN_ROWS), @intCast(col)).* = .{ .color = @intCast((row + col) % 3), .state = .normal };
        }
    }
    const grid = engine.Grid.fromBoard(&b);
    // Just needs to terminate and return a legal move -- a pruning-path
    // sanity check, not a specific-move assertion.
    for ([_]u8{ 2, 3, 4 }) |depth| {
        _ = engine.bestMove(grid, depth) orelse return error.NoMoveFound;
    }
}
