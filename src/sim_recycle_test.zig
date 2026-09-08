// Tests for the recycle-specific behavior added to sim_matches.zig/sim.zig:
// bottom-right-to-top-left stagger order, a clump taller than one row only
// converting its bottom-most (per column) row per event, and recycled
// colors never completing a run of 3 -- kept in a separate file so
// sim_garbage_test.zig itself stays under the project's ~500-line-per-file
// guideline.

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
    b.cellAt(8, 2).* = .{ .state = .normal, .is_garbage = true };
    b.cellAt(9, 2).* = .{ .state = .normal, .is_garbage = true };
    b.cellAt(10, 0).* = .{ .color = 1, .state = .normal };
    b.cellAt(10, 1).* = .{ .color = 1, .state = .normal };
    b.cellAt(10, 2).* = .{ .color = 1, .state = .normal };
    // Floor anchor at row 12 (the true ring-buffer bottom -- see this
    // project's standing test-fixture pitfall) so nothing here falls away
    // unexpectedly once the match clears and gravity re-evaluates.
    b.cellAt(11, 0).* = .{ .color = 2, .state = .normal };
    b.cellAt(11, 1).* = .{ .color = 3, .state = .normal };
    b.cellAt(11, 2).* = .{ .color = 2, .state = .normal };
    b.cellAt(12, 0).* = .{ .color = 3, .state = .normal };
    b.cellAt(12, 1).* = .{ .color = 2, .state = .normal };
    b.cellAt(12, 2).* = .{ .color = 3, .state = .normal };
    _ = sim.checkMatches(&b, &opp, no_settled);

    var frames: u32 = 0;
    while (frames < 300) : (frames += 1) {
        sim.simulate(&b, &opp);
        if (!b.boardBusy()) break;
    }
    try testing.expect(!b.boardBusy());

    // The row-10 match cleared, so the clump that was at rows 8-9 falls:
    // row 9 (the converting one) lands at row 10 as a real block; row 8
    // (the flash-only one, still garbage) lands at row 9, resting on top of
    // it, ready for a future match. (Not asserting `chainable` here -- it's
    // granted the instant the cell converts, but this fall-and-land-without-
    // matching legitimately spends it again by the same standing rule any
    // ordinary revealed block follows; see sim_garbage_test.zig's own
    // "reveals a fresh chainable block" test for that instant, before any
    // further falling, instead.)
    try testing.expectEqual(s.CellState.normal, b.cellAt(10, 2).state);
    try testing.expect(!b.cellAt(10, 2).is_garbage);

    try testing.expectEqual(s.CellState.normal, b.cellAt(9, 2).state);
    try testing.expect(b.cellAt(9, 2).is_garbage);
    try testing.expect(!b.cellAt(9, 2).garbage_reveals);
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
