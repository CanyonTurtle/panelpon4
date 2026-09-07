const std = @import("std");
const testing = std.testing;
const s = @import("state.zig");
const engine = @import("cpu_engine.zig");

test "fromBoard reads color, garbage, and non-normal cells correctly" {
    var b: s.Board = .{};
    b.cellAt(0, 0).* = .{ .color = 2, .state = .normal };
    b.cellAt(0, 1).* = .{ .state = .normal, .is_garbage = true };
    // Mid-animation -- shouldn't happen in practice (the AI only snapshots
    // while boardBusy() is false), but fromBoard should still treat it as
    // empty rather than reading a stale color out of it.
    b.cellAt(0, 2).* = .{ .color = 3, .state = .falling };

    const grid = engine.Grid.fromBoard(&b);
    try testing.expectEqual(@as(i8, 2), grid.cell[0][0]);
    try testing.expectEqual(engine.GARBAGE, grid.cell[0][1]);
    try testing.expectEqual(engine.EMPTY, grid.cell[0][2]);
    try testing.expectEqual(engine.EMPTY, grid.cell[0][3]);
}

test "bestMove finds the swap that completes an immediate match" {
    var b: s.Board = .{};
    // Row 5: 1,1,2,1 -- swapping columns 2/3 completes a run of three 1's.
    b.cellAt(5, 0).* = .{ .color = 1, .state = .normal };
    b.cellAt(5, 1).* = .{ .color = 1, .state = .normal };
    b.cellAt(5, 2).* = .{ .color = 2, .state = .normal };
    b.cellAt(5, 3).* = .{ .color = 1, .state = .normal };

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
    b.cellAt(0, 0).* = .{ .state = .normal, .is_garbage = true };
    b.cellAt(0, 1).* = .{ .color = 1, .state = .normal };
    b.cellAt(0, 2).* = .{ .color = 1, .state = .normal };
    b.cellAt(0, 3).* = .{ .color = 2, .state = .normal };
    b.cellAt(0, 4).* = .{ .color = 1, .state = .normal };

    const grid = engine.Grid.fromBoard(&b);
    const mv = engine.bestMove(grid, 1) orelse return error.NoMoveFound;
    try testing.expectEqual(@as(u8, 0), mv.row);
    try testing.expectEqual(@as(u8, 3), mv.col);
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
    b.cellAt(8, 0).* = .{ .color = 3, .state = .normal };
    b.cellAt(9, 0).* = .{ .color = 3, .state = .normal };
    b.cellAt(10, 0).* = .{ .color = 0, .state = .normal };
    b.cellAt(11, 0).* = .{ .color = 3, .state = .normal };
    b.cellAt(10, 1).* = .{ .color = 0, .state = .normal };
    b.cellAt(11, 1).* = .{ .color = 4, .state = .normal }; // filler, just for gap-free support
    b.cellAt(10, 2).* = .{ .color = 2, .state = .normal };
    b.cellAt(11, 2).* = .{ .color = 1, .state = .normal }; // filler
    b.cellAt(10, 3).* = .{ .color = 0, .state = .normal };
    b.cellAt(11, 3).* = .{ .color = 4, .state = .normal }; // filler

    // Columns 4-5: an unrelated, equally-sized flat match -- swapping row
    // 10's columns 4/5 slides a matching 1 into column 4 (rows 9 and 11 are
    // already 1, split by a differently-colored row 10), completing a
    // vertical run of three with nothing left to cascade into.
    b.cellAt(9, 4).* = .{ .color = 1, .state = .normal };
    b.cellAt(10, 4).* = .{ .color = 4, .state = .normal };
    b.cellAt(11, 4).* = .{ .color = 1, .state = .normal };
    b.cellAt(10, 5).* = .{ .color = 1, .state = .normal };
    b.cellAt(11, 5).* = .{ .color = 2, .state = .normal }; // filler

    const grid = engine.Grid.fromBoard(&b);
    const mv = engine.bestMove(grid, 1) orelse return error.NoMoveFound;
    try testing.expectEqual(@as(u8, 10), mv.row);
    try testing.expectEqual(@as(u8, 2), mv.col);
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
    b.cellAt(11, 0).* = .{ .color = 0, .state = .normal };
    b.cellAt(11, 1).* = .{ .color = 1, .state = .normal };
    b.cellAt(11, 2).* = .{ .color = 2, .state = .normal };
    b.cellAt(11, 3).* = .{ .color = 3, .state = .normal };
    b.cellAt(11, 4).* = .{ .color = 4, .state = .normal };

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
    b.cellAt(5, 0).* = .{ .color = 1, .state = .normal };
    b.cellAt(5, 1).* = .{ .color = 1, .state = .normal };
    b.cellAt(5, 2).* = .{ .color = 2, .state = .normal };
    b.cellAt(5, 3).* = .{ .color = 1, .state = .normal };

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
        b.cellAt(lr, 0).* = .{ .color = @intCast(lr % 2), .state = .normal };
    }

    const grid = engine.Grid.fromBoard(&b);
    const action = engine.bestAction(grid, 1);
    try testing.expect(action != .raise);
}

test "raiseValue penalizes a dangerously tall column enough to outweigh scarce material" {
    var b: s.Board = .{};
    var lr: u8 = 2;
    while (lr < 12) : (lr += 1) {
        b.cellAt(lr, 0).* = .{ .color = @intCast(lr % 2), .state = .normal };
    }
    const grid = engine.Grid.fromBoard(&b);
    try testing.expect(engine.raiseValue(grid) < 0);
}
