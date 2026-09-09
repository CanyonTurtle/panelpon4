const std = @import("std");
const testing = std.testing;
const c = @import("constants.zig");
const s = @import("state.zig");
const engine = @import("cpu_engine.zig");

test "fromBoard reads color, garbage, and in-flight cells correctly" {
    var b: s.Board = .{};
    b.cellAt(10, 0).* = .{ .color = 2, .state = .normal };
    b.cellAt(10, 1).* = .{ .state = .normal, .is_garbage = true };
    // Falling/landing/swapping cells already have their final logical
    // color/column decided (see cpu_grid.Grid.fromBoard's own doc comment),
    // so the AI can now reason about them mid-cascade instead of treating
    // them as holes -- this is what lets it act on (and see the true shape
    // of) a board that isn't fully idle yet.
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
    // Identical to "finds the swap that completes an immediate match" below,
    // except the piece that needs to land in the match is still .falling,
    // not yet .normal. Before Grid.fromBoard read falling cells for real,
    // this column would have looked like an empty hole here, and swapping
    // col 2 into it would just relocate a lone color-2 cell into empty
    // space -- no match, and the engine would have no way to recognize this
    // as the winning swap it actually is.
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
    // Column 0 is garbage -- illegal to swap. Columns 1-4 are set up so only
    // the (row0, col3) swap (columns 3/4) actually completes a match; every
    // other legal pairing (anything not touching column 0) does nothing.
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
    // (5,2)/(5,3) are the SAME color -- swapping them is a strict no-op (the
    // grid comes out byte-for-byte identical), so it must never be a legal
    // candidate at all. Before this was excluded, its own immediate value
    // (always exactly the board's baseline structural score, since nothing
    // changed) could still pick up a full discounted lookahead credit for
    // whatever already was the board's best next move -- see (8,0)-(8,3)
    // below, a genuine winning swap elsewhere -- a bonus that had nothing to
    // do with this swap ever being played. That let a true no-op occasionally
    // outscore every real option, and since playing it never changes the
    // board, the next decide tick reached the exact same conclusion --
    // exactly the reported "CPU spins forever swapping the same two blocks"
    // bug.
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
    // Every column below is gap-free (bottom-settled) down to row 11, the
    // true floor of this simplified grid -- matching what a real, idle
    // board always looks like (gravity is continuous in the real game, so
    // nothing is ever left floating); a swap candidate that isn't evaluated
    // against a properly settled column would get its cells relocated by
    // simulateCascade's own opening gravity pass before matches are even
    // checked, which is exactly the trap this scenario avoids.

    // Columns 0-3: a "blocker" removal that sets off a real 2-deep chain.
    // Row 10 (columns 0-2, color 0) isn't a match yet -- column 2 there is a
    // deliberate mismatch (color 2) -- but swapping columns 2/3 slides a
    // matching 0 into place, completing it. That clears column 0's row 10
    // cell, which was splitting an otherwise-matching stack of three 3's
    // (rows 8, 9, and 11); gravity then compacts them into one contiguous
    // run -- a genuine second pass, not just a bigger first one.
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

    // Columns 4-5: an unrelated, equally-sized flat match -- swapping row
    // 10's columns 4/5 slides a matching 1 into column 4 (rows 9 and 11 are
    // already 1, split by a differently-colored row 10), completing a
    // vertical run of three with nothing left to cascade into.
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

    // A single-pass, non-chaining match: chain_depth never exceeds 1, so
    // chain_cubed - 1 == 0 -- its score must come out identical regardless
    // of chain_weight, since there's no chain bonus to scale in the first
    // place.
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

    // The exact post-swap board from the "prefers a swap that sets off a
    // chain" test above (same fixture, with the winning swap -- row 10,
    // cols 2/3 -- already applied), which genuinely cascades in two passes.
    // A low chain_weight should score it much closer to (barely more than)
    // its own flat per-block value; a high one should score it decisively
    // higher, per the module's own chain_depth^3 curve.
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
    // Pass 1 (chain_depth 1, chain_cubed 1, so no bonus at any weight): 3
    // real blocks * BASE_WEIGHT(10) * multiplier 1 = 30, always. Pass 2
    // (chain_depth 2, chain_cubed 8): at weight 10, bonus = (8-1)*10/100 =
    // 0 (truncated) -> multiplier 1 -> 30; at weight 130, bonus =
    // (8-1)*130/100 = 9 -> multiplier 10 -> 300. Totals: 60 vs. 330.
    try testing.expectEqual(@as(i32, 60), chain_low);
    try testing.expectEqual(@as(i32, 330), chain_high);
}

test "bestAction raises on a completely empty board" {
    var b: s.Board = .{};
    const grid = engine.Grid.fromBoard(&b);
    try testing.expectEqual(engine.Action.raise, engine.bestAction(grid, 1));
}

test "bestAction raises when material is scarce and no swap accomplishes anything" {
    var b: s.Board = .{};
    // Five distinct colors, one cell each, nothing else on the board -- no
    // swap here can ever complete a run (there's only one of each color),
    // and there's nowhere near enough material to be worth playing one
    // anyway (see cpu_engine's LOW_MATERIAL_THRESHOLD).
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
    // Same near-empty setup used elsewhere in this file -- material is far
    // below the low-material threshold, but a real match (worth several
    // hundred points -- see simulateCascade/BASE_WEIGHT) always beats
    // raising by a wide enough margin that scarce material never talks the
    // engine out of taking a free win.
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
    // A single column stacked 10 rows high (alternating colors, so nothing
    // matches on its own) and nothing else on the board at all: real
    // material is far below the low-material threshold (which alone would
    // strongly favor raising -- see the previous tests), but the column is
    // already within a few rows of the top, and raising always pushes every
    // column up by one more row (see board.doRise) -- exactly the situation
    // that used to make the engine kill itself chasing material.
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
    // The whole board, filled with a (row + 2*col) % 5 pattern using all 5
    // colors. A plain (row + col) % k stripe always lets some swap realign
    // two cells to match their neighbor (the pattern is diagonal-invariant:
    // shifting one row is the same as shifting one column), handing the
    // engine a free adjacency-score improvement from nowhere -- this one
    // isn't, by construction (swapping two cells in the same row moves each
    // by +-2*col worth of value, which never lines up with the +-1*row step
    // to its new vertical neighbors, and symmetrically for column swaps).
    // No swap here can improve on the status quo or set off a real match
    // (no three consecutive cells in either direction ever share a color to
    // begin with), and there's plenty of material (72 real cells, well
    // above LOW_MATERIAL_THRESHOLD) with no dangerous height, so raising is
    // disfavored too. With nothing better to do, the engine should just sit
    // still rather than shuffle blocks around or raise for no reason.
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
    // A column 6 rows tall (grid rows 6-11) -- post-raise height 7, right
    // at the "plenty of room" gate's own boundary (PLENTY_OF_ROOM_MARGIN =
    // DANGER_MARGIN + 2 = 5, so post-raise heights up to ROWS - 5 = 7 still
    // qualify).
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

    // One row taller (7, grid rows 5-11) -- post-raise height 8, just past
    // the gate -- raise_bias no longer applies at all, even though this is
    // still nowhere near heightDangerPenalty's own much steeper threshold.
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
    // Depths 2-4 all route the lookahead through bestMoveValue's beam
    // pruning (see BEAM_WIDTH) -- an obvious, immediate win should never be
    // lost to it at any depth.
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
    // Fill the whole board with a color pattern that never runs 3+ the same
    // way in a row or column (a 3-color diagonal stripe: color depends on
    // (row+col) mod 3), so nothing pre-matches, but nearly every adjacent
    // pair is still a legal (if usually pointless) swap -- comfortably more
    // than BEAM_WIDTH candidates, exercising the partial-sort/pruning path
    // for real rather than only ever seeing a handful of candidates.
    for (0..12) |row| {
        for (0..6) |col| {
            b.cellAt(@intCast(row + c.SPAWN_ROWS), @intCast(col)).* = .{ .color = @intCast((row + col) % 3), .state = .normal };
        }
    }
    const grid = engine.Grid.fromBoard(&b);
    // Just needs to terminate and return a legal move at each depth --
    // there are 60 legal swaps here, none of them winning outright, so this
    // is a pruning-path sanity/regression check, not a specific-move
    // assertion.
    for ([_]u8{ 2, 3, 4 }) |depth| {
        _ = engine.bestMove(grid, depth) orelse return error.NoMoveFound;
    }
}
