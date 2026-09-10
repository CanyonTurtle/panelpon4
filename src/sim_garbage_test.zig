// Tests for garbage-block recycling/propagation behavior: swappability,
// matching into an adjacent garbage cell, staggered reveal timing and
// colors. Kept in a separate file so sim_test.zig itself stays under the
// project's ~500-line-per-file guideline; the combo/chain spawn-sizing,
// queueing, and rigid-body falling/landing tests live in the companion
// sim_garbage_spawn_test.zig, split out for the same reason.

const std = @import("std");
const testing = std.testing;
const c = @import("constants.zig");
const s = @import("state.zig");
const sim = @import("sim.zig");
const garbage = @import("sim_garbage.zig");

const no_settled: [c.ROWS][c.COLS]bool = std.mem.zeroes([c.ROWS][c.COLS]bool);

test "a garbage cell is never swappable" {
    var b: s.Board = .{};
    const row = b.cursor_row + c.SPAWN_ROWS;
    b.cellAt(row, b.cursor_col).* = .{ .state = .normal, .is_garbage = true };
    b.cellAt(row, b.cursor_col + 1).* = .{ .color = 1, .state = .normal };
    sim.trySwap(&b);
    try testing.expect(b.cellAt(row, b.cursor_col).is_garbage);
    try testing.expectEqual(@as(u8, 1), b.cellAt(row, b.cursor_col + 1).color);
}

test "a match propagates into an orthogonally adjacent garbage cell, recycling it" {
    var b: s.Board = .{};
    var opp: s.Board = .{};
    b.cellAt(5, 0).* = .{ .color = 1, .state = .normal };
    b.cellAt(5, 1).* = .{ .color = 1, .state = .normal };
    b.cellAt(5, 2).* = .{ .color = 1, .state = .normal };
    b.cellAt(5, 3).* = .{ .state = .normal, .is_garbage = true }; // touches col 2
    _ = sim.checkMatches(&b, &opp, no_settled);

    try testing.expectEqual(s.CellState.recycling, b.cellAt(5, 3).state);
}

test "a match pulls in a whole garbage piece even if only one of its cells actually touches the match" {
    var b: s.Board = .{};
    var opp: s.Board = .{};
    // Both cells belong to the SAME piece (garbage_group defaults to 0 for
    // both here, same as one spawnGarbage call would give them) -- only
    // (6,2) actually touches the match, but (7,2) comes along too because
    // it's part of the same piece, not because of transitive spatial
    // touching (see sim_recycle_test.zig for the case where two DIFFERENT
    // pieces touch each other and must NOT both get pulled in this way).
    b.cellAt(5, 0).* = .{ .color = 1, .state = .normal };
    b.cellAt(5, 1).* = .{ .color = 1, .state = .normal };
    b.cellAt(5, 2).* = .{ .color = 1, .state = .normal };
    b.cellAt(6, 2).* = .{ .state = .normal, .is_garbage = true }; // touches the match
    b.cellAt(7, 2).* = .{ .state = .normal, .is_garbage = true }; // same piece, doesn't touch the match itself
    _ = sim.checkMatches(&b, &opp, no_settled);

    try testing.expectEqual(s.CellState.recycling, b.cellAt(6, 2).state);
    try testing.expectEqual(s.CellState.recycling, b.cellAt(7, 2).state);
}

test "recycling cells in the same group are staggered one at a time, not simultaneous" {
    var b: s.Board = .{};
    var opp: s.Board = .{};
    b.cellAt(5, 0).* = .{ .color = 1, .state = .normal };
    b.cellAt(5, 1).* = .{ .color = 1, .state = .normal };
    b.cellAt(5, 2).* = .{ .color = 1, .state = .normal };
    b.cellAt(6, 2).* = .{ .state = .normal, .is_garbage = true }; // touches the match
    b.cellAt(7, 2).* = .{ .state = .normal, .is_garbage = true }; // touches the garbage above it
    _ = sim.checkMatches(&b, &opp, no_settled);

    // Member ordering sweeps bottom-right to top-left (rows first -- see
    // checkMatches), so the lower cell (7,2) gets an earlier own-turn timer
    // than the one above it (6,2) -- a fixed delay apart (see
    // POP_STAGGER_FRAMES), not the same instant. This staggered timer is
    // exactly what render.drawRecyclingCell uses to reveal each one on its
    // own turn, one cell at a time, rather than all at once.
    const earlier = b.cellAt(7, 2).timer;
    const later = b.cellAt(6, 2).timer;
    try testing.expectEqual(earlier + c.POP_STAGGER_FRAMES, later);
    // Both garbage members share the same whole-group resolution timer
    // (see real_group_end/group_end in checkMatches -- garbage always
    // resolves on the full group's schedule), and here it also happens to
    // equal the real matched cells' own resolution timer, since in this
    // particular layout the *real* cells (5,0)-(5,2) are the last members
    // in the whole group's stagger order anyway (garbage sorts before them
    // -- see the bottom-right-to-top-left ordering). That's a coincidence
    // of this specific arrangement, not a general guarantee -- see the next
    // test for a layout where they genuinely differ.
    try testing.expectEqual(b.cellAt(5, 0).pop_group_end, b.cellAt(6, 2).pop_group_end);
    try testing.expectEqual(b.cellAt(6, 2).pop_group_end, b.cellAt(7, 2).pop_group_end);
}

test "a real match's own cells free up for gravity as soon as their own pop finishes, not held hostage by a slower-finishing garbage clump in the same group" {
    var b: s.Board = .{};
    var opp: s.Board = .{};
    // Real match on row 6; garbage at row 5 touches it from above. Row 5
    // sorts *after* row 6 in the group's bottom-right-to-top-left stagger
    // order, so this garbage cell ends up the very last member overall --
    // its own group resolution (which stays on the full group's schedule)
    // finishes a full POP_STAGGER_FRAMES later than the real cells' own.
    b.cellAt(6, 0).* = .{ .color = 1, .state = .normal };
    b.cellAt(6, 1).* = .{ .color = 1, .state = .normal };
    b.cellAt(6, 2).* = .{ .color = 1, .state = .normal };
    b.cellAt(5, 2).* = .{ .state = .normal, .is_garbage = true };
    // A block sitting directly above one of the real matched cells, with
    // nothing else supporting it -- once (6,1) actually clears to empty,
    // this should immediately start falling into the freed space, proving
    // the space is genuinely usable again right then, not just visually
    // "gone" while still logically blocked.
    b.cellAt(5, 1).* = .{ .color = 2, .state = .normal };
    _ = sim.checkMatches(&b, &opp, no_settled);

    const member_count = 4; // 3 real + 1 garbage
    const real_group_end: i16 = c.PRE_POP_TOTAL_FRAMES + c.POP_FRAMES + 2 * c.POP_STAGGER_FRAMES; // real cells are i=0,1,2
    const full_group_end: i16 = c.PRE_POP_TOTAL_FRAMES + c.POP_FRAMES + (member_count - 1) * c.POP_STAGGER_FRAMES; // garbage is i=3

    try testing.expect(full_group_end > real_group_end);
    try testing.expectEqual(real_group_end, b.cellAt(6, 0).pop_group_end);
    try testing.expectEqual(real_group_end, b.cellAt(6, 1).pop_group_end);
    try testing.expectEqual(real_group_end, b.cellAt(6, 2).pop_group_end);
    try testing.expectEqual(full_group_end, b.cellAt(5, 2).pop_group_end);

    for (0..@intCast(real_group_end - 1)) |_| sim.simulate(&b, &opp);
    try testing.expectEqual(s.CellState.popping, b.cellAt(6, 1).state); // not yet -- one frame short

    sim.simulate(&b, &opp); // the real cells' own resolution frame
    try testing.expectEqual(s.CellState.empty, b.cellAt(6, 0).state);
    try testing.expectEqual(s.CellState.empty, b.cellAt(6, 2).state);
    // The block that was resting above (6,1) already started falling into
    // the newly-freed space, same frame -- the space is immediately usable,
    // not just visually cleared.
    try testing.expectEqual(s.CellState.falling, b.cellAt(6, 1).state);
    // Garbage is a wholly separate piece from the real match -- it just sits
    // there, inert, still mid-recycle, completely unaffected by the real
    // match resolving around it.
    try testing.expectEqual(s.CellState.recycling, b.cellAt(5, 2).state);
    try testing.expect(b.cellAt(5, 2).is_garbage);

    for (0..@intCast(full_group_end - real_group_end)) |_| sim.simulate(&b, &opp);
    // The garbage cell has now finished its own, separate resolution --
    // this piece's only cell, so it converts to a real, chainable block --
    // and, same frame, immediately starts falling into (6,2), which the
    // real match freed long before this piece was done. `(5,2)` itself is
    // left empty behind it.
    try testing.expectEqual(s.CellState.falling, b.cellAt(6, 2).state);
    try testing.expect(!b.cellAt(6, 2).is_garbage);
    try testing.expect(b.cellAt(6, 2).chainable);
    try testing.expectEqual(s.CellState.empty, b.cellAt(5, 2).state);
}

test "an unrelated garbage cell elsewhere does not recycle" {
    var b: s.Board = .{};
    var opp: s.Board = .{};
    b.cellAt(5, 0).* = .{ .color = 1, .state = .normal };
    b.cellAt(5, 1).* = .{ .color = 1, .state = .normal };
    b.cellAt(5, 2).* = .{ .color = 1, .state = .normal };
    b.cellAt(9, 5).* = .{ .state = .normal, .is_garbage = true }; // far away, untouched
    _ = sim.checkMatches(&b, &opp, no_settled);

    try testing.expectEqual(s.CellState.normal, b.cellAt(9, 5).state);
    try testing.expect(b.cellAt(9, 5).is_garbage);
}

test "a recycled garbage cell reveals a fresh chainable block only once its whole group finishes" {
    var b: s.Board = .{};
    var opp: s.Board = .{};
    b.cellAt(15, 0).* = .{ .color = 1, .state = .normal };
    b.cellAt(15, 1).* = .{ .color = 1, .state = .normal };
    b.cellAt(15, 2).* = .{ .color = 1, .state = .normal };
    b.cellAt(15, 3).* = .{ .state = .normal, .is_garbage = true };
    // A genuine floor directly below the garbage cell -- anchored all the
    // way to row 22 (the true bottom of the ring buffer), or gravity would
    // treat the "floor" itself as unsupported and let it fall away, leaving
    // the revealed block nothing to rest on (the project's standing
    // test-fixture pitfall). This keeps the revealed block at a known
    // position (row 15) so the assertions below are unambiguous.
    b.cellAt(16, 3).* = .{ .color = 3, .state = .normal };
    b.cellAt(17, 3).* = .{ .color = 4, .state = .normal };
    b.cellAt(18, 3).* = .{ .color = 3, .state = .normal };
    b.cellAt(19, 3).* = .{ .color = 4, .state = .normal };
    b.cellAt(20, 3).* = .{ .color = 3, .state = .normal };
    b.cellAt(21, 3).* = .{ .color = 4, .state = .normal };
    b.cellAt(22, 3).* = .{ .color = 3, .state = .normal };
    _ = sim.checkMatches(&b, &opp, no_settled);
    // (This match's 4 members -- 3 real + 1 propagated garbage -- also cross
    // the combo threshold and spawn combo garbage on the opponent's board;
    // that's correct, expected behavior for a match this size, not something
    // this test needs to isolate against.)

    const member_count = 4; // 3 matched + 1 propagated garbage
    const group_end: i16 = c.PRE_POP_TOTAL_FRAMES + c.POP_FRAMES + (member_count - 1) * c.POP_STAGGER_FRAMES;
    const color_at_start = b.cellAt(15, 3).color;

    for (0..@intCast(group_end - 1)) |_| sim.simulate(&b, &opp);
    try testing.expectEqual(s.CellState.recycling, b.cellAt(15, 3).state);
    try testing.expect(b.cellAt(15, 3).is_garbage);
    // The color doesn't change while recycling -- it was picked once, up
    // front, when the whole event was first detected.
    try testing.expectEqual(color_at_start, b.cellAt(15, 3).color);

    sim.simulate(&b, &opp); // the final frame: the whole group resolves together
    try testing.expectEqual(s.CellState.normal, b.cellAt(15, 3).state);
    try testing.expect(!b.cellAt(15, 3).is_garbage);
    try testing.expect(b.cellAt(15, 3).chainable);
    // Reveal doesn't reassign the color either -- what the player saw
    // throughout the pop is exactly what it becomes.
    try testing.expectEqual(color_at_start, b.cellAt(15, 3).color);
}

test "a garbage cell's color is picked the instant recycling starts, not at reveal" {
    var b: s.Board = .{};
    var opp: s.Board = .{};
    b.cellAt(5, 0).* = .{ .color = 1, .state = .normal };
    b.cellAt(5, 1).* = .{ .color = 1, .state = .normal };
    b.cellAt(5, 2).* = .{ .color = 1, .state = .normal };
    b.cellAt(5, 3).* = .{ .state = .normal, .is_garbage = true };
    _ = sim.checkMatches(&b, &opp, no_settled);

    // Still garbage=true (hasn't resolved yet) but already has a real color
    // ready for the moment its own staggered turn comes up (see
    // render.drawRecyclingCell) -- not still the zero-valued default a
    // genuinely-unrevealed cell would have.
    try testing.expectEqual(s.CellState.recycling, b.cellAt(5, 3).state);
    try testing.expect(b.cellAt(5, 3).is_garbage);
    try testing.expect(b.cellAt(5, 3).color < c.NUM_COLORS);
}

