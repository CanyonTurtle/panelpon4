// Tests for recycle-specific behavior: stagger order, per-piece (not
// spatial) bottom-row-converts rule, and recycled colors avoiding a run of 3.

const std = @import("std");
const testing = std.testing;
const c = @import("constants.zig");
const s = @import("state.zig");
const sim = @import("sim.zig");

const no_settled: [c.ROWS][c.COLS]bool = std.mem.zeroes([c.ROWS][c.COLS]bool);

test "garbage recycles bottom-right to top-left, rows first" {
    var b: s.Board = .{};
    var opp: s.Board = .{};
    // An L-shaped clump (row8: col2; row9: col1,col2): row 9 (bottom) should
    // stagger before row 8 (top); within row 9, col 2 before col 1.
    b.cellAt(8, 2).* = .{ .state = .normal, .is_garbage = true };
    b.cellAt(9, 1).* = .{ .state = .normal, .is_garbage = true };
    b.cellAt(9, 2).* = .{ .state = .normal, .is_garbage = true };
    b.cellAt(10, 0).* = .{ .color = 1, .state = .normal };
    b.cellAt(10, 1).* = .{ .color = 1, .state = .normal };
    b.cellAt(10, 2).* = .{ .color = 1, .state = .normal };
    _ = sim.checkMatches(&b, &opp, no_settled);

    try testing.expect(b.cellAt(9, 2).timer < b.cellAt(9, 1).timer);
    try testing.expect(b.cellAt(9, 1).timer < b.cellAt(8, 2).timer);
}

test "a garbage clump taller than one row only marks its bottom row (per column) as converting" {
    var b: s.Board = .{};
    var opp: s.Board = .{};
    // A 2-row-tall, 1-col-wide clump at column 2, triggered by row10's
    // real match.
    b.cellAt(8, 2).* = .{ .state = .normal, .is_garbage = true };
    b.cellAt(9, 2).* = .{ .state = .normal, .is_garbage = true };
    b.cellAt(10, 0).* = .{ .color = 1, .state = .normal };
    b.cellAt(10, 1).* = .{ .color = 1, .state = .normal };
    b.cellAt(10, 2).* = .{ .color = 1, .state = .normal };
    _ = sim.checkMatches(&b, &opp, no_settled);

    try testing.expect(!b.cellAt(8, 2).garbage_reveals); // top: flash-only
    try testing.expect(b.cellAt(9, 2).garbage_reveals); // bottom: converts
}

test "a pop propagates into a different garbage piece resting against the triggered one, but each piece still keeps its own bottom-row rule" {
    var b: s.Board = .{};
    var opp: s.Board = .{};
    // Piece 1 (rows 8-9) touches the match at its bottom. Piece 2 (row 7)
    // just rests on top of it -- its own separate 1-row piece, converting fully.
    b.cellAt(7, 2).* = .{ .state = .normal, .is_garbage = true, .garbage_group = 2 };
    b.cellAt(8, 2).* = .{ .state = .normal, .is_garbage = true, .garbage_group = 1 };
    b.cellAt(9, 2).* = .{ .state = .normal, .is_garbage = true, .garbage_group = 1 };
    b.cellAt(10, 0).* = .{ .color = 1, .state = .normal };
    b.cellAt(10, 1).* = .{ .color = 1, .state = .normal };
    b.cellAt(10, 2).* = .{ .color = 1, .state = .normal };
    _ = sim.checkMatches(&b, &opp, no_settled);

    try testing.expectEqual(s.CellState.recycling, b.cellAt(7, 2).state);
    try testing.expectEqual(s.CellState.recycling, b.cellAt(8, 2).state);
    try testing.expectEqual(s.CellState.recycling, b.cellAt(9, 2).state);

    // Piece 1's bottom row (9) converts, row 8 doesn't. Piece 2's row 7
    // converts too -- nothing of its own group is below it.
    try testing.expect(b.cellAt(9, 2).garbage_reveals);
    try testing.expect(!b.cellAt(8, 2).garbage_reveals);
    try testing.expect(b.cellAt(7, 2).garbage_reveals);
}

test "two separate 1-row pieces stacked together each convert on their own -- the rule is per piece, not per event" {
    var b: s.Board = .{};
    var opp: s.Board = .{};
    // Two genuinely 1-row pieces stacked and touching -- guards against
    // treating them as one 2-tall clump that only lets the bottom convert.
    b.cellAt(7, 0).* = .{ .color = 2, .state = .normal };
    b.cellAt(7, 1).* = .{ .color = 2, .state = .normal };
    b.cellAt(7, 2).* = .{ .color = 2, .state = .normal };
    b.cellAt(8, 2).* = .{ .state = .normal, .is_garbage = true, .garbage_group = 2 };
    b.cellAt(9, 2).* = .{ .state = .normal, .is_garbage = true, .garbage_group = 1 };
    b.cellAt(10, 0).* = .{ .color = 1, .state = .normal };
    b.cellAt(10, 1).* = .{ .color = 1, .state = .normal };
    b.cellAt(10, 2).* = .{ .color = 1, .state = .normal };
    _ = sim.checkMatches(&b, &opp, no_settled);

    try testing.expectEqual(s.CellState.recycling, b.cellAt(8, 2).state);
    try testing.expectEqual(s.CellState.recycling, b.cellAt(9, 2).state);
    try testing.expect(b.cellAt(8, 2).garbage_reveals);
    try testing.expect(b.cellAt(9, 2).garbage_reveals);
}

test "each column of a wider clump converts independently -- a 1-tall column still converts even next to a 2-tall one" {
    var b: s.Board = .{};
    var opp: s.Board = .{};
    // Column 2 is 2 rows tall; column 1 is only 1 row -- it converts on its
    // own, independent of column 2's taller stack.
    b.cellAt(8, 2).* = .{ .state = .normal, .is_garbage = true };
    b.cellAt(9, 1).* = .{ .state = .normal, .is_garbage = true };
    b.cellAt(9, 2).* = .{ .state = .normal, .is_garbage = true };
    b.cellAt(10, 0).* = .{ .color = 1, .state = .normal };
    b.cellAt(10, 1).* = .{ .color = 1, .state = .normal };
    b.cellAt(10, 2).* = .{ .color = 1, .state = .normal };
    _ = sim.checkMatches(&b, &opp, no_settled);

    try testing.expect(b.cellAt(9, 1).garbage_reveals);
    try testing.expect(b.cellAt(9, 2).garbage_reveals);
    try testing.expect(!b.cellAt(8, 2).garbage_reveals);
}

test "after the whole group resolves, a converting cell becomes real+chainable and a non-converting one stays plain garbage" {
    var b: s.Board = .{};
    var opp: s.Board = .{};
    b.cellAt(18, 2).* = .{ .state = .normal, .is_garbage = true };
    b.cellAt(19, 2).* = .{ .state = .normal, .is_garbage = true };
    b.cellAt(20, 0).* = .{ .color = 1, .state = .normal };
    b.cellAt(20, 1).* = .{ .color = 1, .state = .normal };
    b.cellAt(20, 2).* = .{ .color = 1, .state = .normal };
    // Floor anchor at row 22 (the true ring-buffer bottom) so nothing here
    // falls away once the match clears.
    b.cellAt(21, 0).* = .{ .color = 2, .state = .normal };
    b.cellAt(21, 1).* = .{ .color = 3, .state = .normal };
    b.cellAt(21, 2).* = .{ .color = 2, .state = .normal };
    b.cellAt(22, 0).* = .{ .color = 3, .state = .normal };
    b.cellAt(22, 1).* = .{ .color = 2, .state = .normal };
    b.cellAt(22, 2).* = .{ .color = 3, .state = .normal };
    _ = sim.checkMatches(&b, &opp, no_settled);

    var frames: u32 = 0;
    while (frames < 300) : (frames += 1) {
        sim.simulate(&b, &opp);
        if (!b.boardBusy()) break;
    }
    try testing.expect(!b.boardBusy());

    // Row 19 lands at row 20 as a real block; row 18 rests on top, still
    // garbage. `chainable` not asserted -- see sim_garbage_test.zig instead.
    try testing.expectEqual(s.CellState.normal, b.cellAt(20, 2).state);
    try testing.expect(!b.cellAt(20, 2).is_garbage);

    try testing.expectEqual(s.CellState.normal, b.cellAt(19, 2).state);
    try testing.expect(b.cellAt(19, 2).is_garbage);
    try testing.expect(!b.cellAt(19, 2).garbage_reveals);
}

test "recycled garbage colors never complete a run of 3, across many random seeds" {
    var seed: u32 = 1;
    while (seed < 500) : (seed += 41) {
        var b: s.Board = .{ .rng_state = seed };
        var opp: s.Board = .{};
        // A full 6-wide garbage row -- every cell converts with a freely
        // chosen color, where a naive pick would risk an accidental run.
        for (0..c.COLS) |col| b.cellAt(9, @intCast(col)).* = .{ .state = .normal, .is_garbage = true };
        b.cellAt(10, 0).* = .{ .color = 1, .state = .normal };
        b.cellAt(10, 1).* = .{ .color = 1, .state = .normal };
        b.cellAt(10, 2).* = .{ .color = 1, .state = .normal };
        _ = sim.checkMatches(&b, &opp, no_settled);

        var colors: [c.COLS]u8 = undefined;
        for (0..c.COLS) |col| {
            const cell = b.cellAt(9, @intCast(col));
            try testing.expect(cell.garbage_reveals);
            colors[col] = cell.color;
        }
        for (0..c.COLS - 2) |i| {
            try testing.expect(!(colors[i] == colors[i + 1] and colors[i + 1] == colors[i + 2]));
        }
    }
}

test "a recycled color also avoids completing a run with pre-existing settled real blocks" {
    var b: s.Board = .{};
    var opp: s.Board = .{};
    // Two settled color-2 blocks sit above where the garbage cell reveals --
    // the reveal must not also pick color 2.
    b.cellAt(7, 2).* = .{ .color = 2, .state = .normal };
    b.cellAt(8, 2).* = .{ .color = 2, .state = .normal };
    b.cellAt(9, 2).* = .{ .state = .normal, .is_garbage = true };
    b.cellAt(10, 0).* = .{ .color = 1, .state = .normal };
    b.cellAt(10, 1).* = .{ .color = 1, .state = .normal };
    b.cellAt(10, 2).* = .{ .color = 1, .state = .normal };
    _ = sim.checkMatches(&b, &opp, no_settled);

    try testing.expect(b.cellAt(9, 2).garbage_reveals);
    try testing.expect(b.cellAt(9, 2).color != 2);
}

