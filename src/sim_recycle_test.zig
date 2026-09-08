// Tests for the recycle-specific behavior added to sim_matches.zig/sim.zig:
// bottom-right-to-top-left stagger order, garbage *pieces* (Cell.garbage_group
// -- one persistent id per combo/chain that spawned it, retained regardless
// of what a piece happens to be touching) rather than transient spatial
// adjacency deciding both what a match pulls in and the "only the bottom row
// per piece converts" rule, and recycled colors never completing a run of 3
// -- kept in a separate file so sim_garbage_test.zig itself stays under the
// project's ~500-line-per-file guideline.

const std = @import("std");
const testing = std.testing;
const c = @import("constants.zig");
const s = @import("state.zig");
const sim = @import("sim.zig");

const no_settled: [c.ROWS][c.COLS]bool = std.mem.zeroes([c.ROWS][c.COLS]bool);

test "garbage recycles bottom-right to top-left, rows first" {
    var b: s.Board = .{};
    var opp: s.Board = .{};
    // An L-shaped clump:
    //   row8: .  .  X
    //   row9: .  X  X
    // triggered by row10's real match. Row 9 (bottom) should stagger before
    // row 8 (top); within row 9, col 2 (right) should stagger before col 1
    // (left).
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
    // Piece 1 (rows 8-9, 2 tall) touches the real match directly at its
    // bottom. Piece 2 (row 7, a completely different origin) just happens
    // to be resting on top of piece 1, touching it -- propagation still
    // reaches it (a pop connects through a whole physically-touching
    // clump, same as always), but piece 2 is its OWN separate 1-row piece,
    // so it converts fully, independent of piece 1 only converting its own
    // bottom row.
    b.cellAt(7, 2).* = .{ .state = .normal, .is_garbage = true, .garbage_group = 2 };
    b.cellAt(8, 2).* = .{ .state = .normal, .is_garbage = true, .garbage_group = 1 };
    b.cellAt(9, 2).* = .{ .state = .normal, .is_garbage = true, .garbage_group = 1 };
    b.cellAt(10, 0).* = .{ .color = 1, .state = .normal };
    b.cellAt(10, 1).* = .{ .color = 1, .state = .normal };
    b.cellAt(10, 2).* = .{ .color = 1, .state = .normal };
    _ = sim.checkMatches(&b, &opp, no_settled);

    // Both pieces are pulled into the same event -- propagation goes
    // through the whole physically-connected clump, crossing from piece 1
    // into piece 2 where they touch.
    try testing.expectEqual(s.CellState.recycling, b.cellAt(7, 2).state);
    try testing.expectEqual(s.CellState.recycling, b.cellAt(8, 2).state);
    try testing.expectEqual(s.CellState.recycling, b.cellAt(9, 2).state);

    // Piece 1's own bottom row (9) converts; its row 8 doesn't (piece 1's
    // own cell is right below it). Piece 2's row 7 converts too -- it's a
    // different, genuinely 1-row piece, so nothing of *its own* group is
    // below it (row 8 belongs to piece 1), regardless of piece 1 only
    // partially converting right underneath it.
    try testing.expect(b.cellAt(9, 2).garbage_reveals);
    try testing.expect(!b.cellAt(8, 2).garbage_reveals);
    try testing.expect(b.cellAt(7, 2).garbage_reveals);
}

test "two separate 1-row pieces stacked together each convert on their own -- the rule is per piece, not per event" {
    var b: s.Board = .{};
    var opp: s.Board = .{};
    // Piece 1 (row 9) touches a match below it; piece 2 (row 8), a
    // different origin sitting directly on top of piece 1, touches its own
    // separate match above it. Both are genuinely only 1 row tall on their
    // own, even though they're touching each other -- so both should
    // convert, not just the lower one (the bug this test guards against:
    // treating the touching stack as one 2-tall clump and only letting the
    // bottom-most cell overall convert).
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
    // Column 2 is 2 rows tall (rows 8-9); column 1 is only 1 row tall (row
    // 9). Both touch row 10's real match. Column 1 has nothing garbage
    // below its own single cell, so it converts on its own, independent of
    // column 2's taller stack.
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
    // Floor anchor at row 22 (the true ring-buffer bottom -- see this
    // project's standing test-fixture pitfall) so nothing here falls away
    // unexpectedly once the match clears and gravity re-evaluates.
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

    // The row-20 match cleared, so the clump that was at rows 18-19 falls:
    // row 19 (the converting one) lands at row 20 as a real block; row 18
    // (the flash-only one, still garbage) lands at row 19, resting on top of
    // it, ready for a future match. (Not asserting `chainable` here -- it's
    // granted the instant the cell converts, but this fall-and-land-without-
    // matching legitimately spends it again by the same standing rule any
    // ordinary revealed block follows; see sim_garbage_test.zig's own
    // "reveals a fresh chainable block" test for that instant, before any
    // further falling, instead.)
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
        // A full 6-wide, 1-row-tall garbage row -- every cell should
        // convert (nothing garbage below any of them), so all 6 get a
        // real, freely-chosen color -- exactly where a naive independent
        // random pick would risk an accidental 3-in-a-row.
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
    // Two pre-existing, already-settled real blocks of color 2 sit directly
    // above where a single garbage cell (col 2) will reveal -- the reveal
    // must not also pick color 2, or it would complete a vertical run of 3.
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

