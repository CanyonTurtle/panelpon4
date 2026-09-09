// Tests for garbage-block behavior (spawning, propagation, reveal, and the
// rigid-body group gravity in sim_garbage.zig) -- kept in a separate file so
// sim_test.zig itself stays under the project's ~500-line-per-file
// guideline.

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

test "a combo of 4 spawns a 3-wide garbage row on the opponent's board, anchored at the match" {
    var b: s.Board = .{};
    var opp: s.Board = .{};
    b.cellAt(5, 0).* = .{ .color = 1, .state = .normal };
    b.cellAt(5, 1).* = .{ .color = 1, .state = .normal };
    b.cellAt(5, 2).* = .{ .color = 1, .state = .normal };
    b.cellAt(5, 3).* = .{ .color = 1, .state = .normal };
    _ = sim.checkMatches(&b, &opp, no_settled);

    garbage.releaseIncomingGarbage(&opp); // idle by default -- releases immediately
    for (0..3) |col| try testing.expect(opp.cellAt(0, @intCast(col)).is_garbage);
    try testing.expectEqual(s.CellState.empty, opp.cellAt(0, 3).state);
    for (0..c.COLS) |col| try testing.expectEqual(s.CellState.empty, b.cellAt(0, @intCast(col)).state);
}

test "a combo of 5 spawns a 4-wide garbage row on the opponent's board" {
    var b: s.Board = .{};
    var opp: s.Board = .{};
    b.cellAt(5, 0).* = .{ .color = 1, .state = .normal };
    b.cellAt(5, 1).* = .{ .color = 1, .state = .normal };
    b.cellAt(5, 2).* = .{ .color = 1, .state = .normal };
    b.cellAt(5, 3).* = .{ .color = 1, .state = .normal };
    b.cellAt(5, 4).* = .{ .color = 1, .state = .normal };
    _ = sim.checkMatches(&b, &opp, no_settled);

    garbage.releaseIncomingGarbage(&opp);
    for (0..4) |col| try testing.expect(opp.cellAt(0, @intCast(col)).is_garbage);
    try testing.expectEqual(s.CellState.empty, opp.cellAt(0, 4).state);
}

test "a combo of 6 or more spawns a full garbage row on the opponent's board" {
    var b: s.Board = .{};
    var opp: s.Board = .{};
    for (0..6) |col| b.cellAt(5, @intCast(col)).* = .{ .color = 1, .state = .normal };
    _ = sim.checkMatches(&b, &opp, no_settled);

    garbage.releaseIncomingGarbage(&opp);
    for (0..c.COLS) |col| try testing.expect(opp.cellAt(0, @intCast(col)).is_garbage);
}

test "the first ordinary 3-match never spawns garbage" {
    var b: s.Board = .{};
    var opp: s.Board = .{};
    b.cellAt(5, 0).* = .{ .color = 1, .state = .normal };
    b.cellAt(5, 1).* = .{ .color = 1, .state = .normal };
    b.cellAt(5, 2).* = .{ .color = 1, .state = .normal };
    _ = sim.checkMatches(&b, &opp, no_settled);

    for (0..c.COLS) |col| try testing.expectEqual(s.CellState.empty, opp.cellAt(0, @intCast(col)).state);
}

test "a chain seals its garbage size only once it concludes, using the final step's size, not a sum of every step" {
    var b: s.Board = .{};
    var opp: s.Board = .{};
    b.cellAt(5, 0).* = .{ .color = 1, .state = .normal };
    b.cellAt(5, 1).* = .{ .color = 1, .state = .normal };
    b.cellAt(5, 2).* = .{ .color = 1, .state = .normal };
    _ = sim.checkMatches(&b, &opp, no_settled); // chain 0 -> 1, ordinary, no garbage
    try testing.expectEqual(@as(?s.GarbageAttack, null), b.chain_pending_garbage);

    b.cellAt(8, 3).* = .{ .color = 2, .state = .normal, .chainable = true };
    b.cellAt(8, 4).* = .{ .color = 2, .state = .normal };
    b.cellAt(8, 5).* = .{ .color = 2, .state = .normal };
    _ = sim.checkMatches(&b, &opp, no_settled); // chain 1 -> 2 (x2): would be 1 full row
    try testing.expectEqual(@as(u8, 2), b.chain);
    try testing.expectEqual(@as(u8, 1), b.chain_pending_garbage.?.rows);
    // Not released to the opponent yet -- the chain hasn't concluded (b is
    // still mid-pop), matching rule 1: garbage never falls mid-chain.
    for (0..c.COLS) |col| try testing.expectEqual(s.CellState.empty, opp.cellAt(0, @intCast(col)).state);

    b.cellAt(9, 0).* = .{ .color = 3, .state = .normal, .chainable = true };
    b.cellAt(9, 1).* = .{ .color = 3, .state = .normal };
    b.cellAt(9, 2).* = .{ .color = 3, .state = .normal };
    _ = sim.checkMatches(&b, &opp, no_settled); // chain 2 -> 3 (x3): overwrites the pending amount
    try testing.expectEqual(@as(u8, 3), b.chain);
    // 2 rows (x3's own size) -- NOT 1 + 2 = 3, the x2 step's pending amount
    // is simply discarded, not accumulated (rule 2).
    try testing.expectEqual(@as(u8, 2), b.chain_pending_garbage.?.rows);

    // Let the whole chain actually finish (every pop/recycle cascade
    // resolves and b goes idle) -- mirrors main.zig's own per-frame driving
    // (sim.simulate, then resolveChainEnd, every frame).
    var frames: u32 = 0;
    while (frames < 300) : (frames += 1) {
        sim.simulate(&b, &opp);
        garbage.resolveChainEnd(&b, &opp);
        if (!b.boardBusy()) break;
    }
    try testing.expectEqual(@as(?s.GarbageAttack, null), b.chain_pending_garbage);

    garbage.releaseIncomingGarbage(&opp);
    // Exactly 2 rows -- the x3 step's own size, not 1 (from x2) + 2 (from x3).
    for (0..2) |row| {
        for (0..c.COLS) |col| try testing.expect(opp.cellAt(@intCast(row), @intCast(col)).is_garbage);
    }
    for (0..c.COLS) |col| try testing.expectEqual(s.CellState.empty, opp.cellAt(2, @intCast(col)).state);
}

test "a match that is both a chain and a combo queues chain-shaped garbage, not combo-shaped" {
    var b: s.Board = .{};
    var opp: s.Board = .{};
    b.cellAt(5, 0).* = .{ .color = 1, .state = .normal };
    b.cellAt(5, 1).* = .{ .color = 1, .state = .normal };
    b.cellAt(5, 2).* = .{ .color = 1, .state = .normal };
    _ = sim.checkMatches(&b, &opp, no_settled);

    // A 4-block chainable match: both is_chain (x2) and is_combo (4 blocks)
    // are true. Chain-shaped (1 full row) should win, not combo-shaped
    // (a 3-wide row).
    b.cellAt(8, 2).* = .{ .color = 2, .state = .normal, .chainable = true };
    b.cellAt(8, 3).* = .{ .color = 2, .state = .normal };
    b.cellAt(8, 4).* = .{ .color = 2, .state = .normal };
    b.cellAt(8, 5).* = .{ .color = 2, .state = .normal };
    _ = sim.checkMatches(&b, &opp, no_settled);
    try testing.expectEqual(@as(u8, 2), b.chain);
    try testing.expectEqual(@as(u8, 1), b.chain_pending_garbage.?.rows);
    try testing.expectEqual(@as(u8, c.COLS), b.chain_pending_garbage.?.width);
}

test "queued garbage doesn't land while the receiving board is still busy, even though the attacker is long done" {
    var b: s.Board = .{};
    var opp: s.Board = .{};
    b.cellAt(5, 0).* = .{ .color = 1, .state = .normal };
    b.cellAt(5, 1).* = .{ .color = 1, .state = .normal };
    b.cellAt(5, 2).* = .{ .color = 1, .state = .normal };
    b.cellAt(5, 3).* = .{ .color = 1, .state = .normal }; // combo of 4
    _ = sim.checkMatches(&b, &opp, no_settled);

    opp.cellAt(9, 0).state = .falling; // opp is still mid-cascade on its own
    garbage.releaseIncomingGarbage(&opp);
    for (0..c.COLS) |col| try testing.expectEqual(s.CellState.empty, opp.cellAt(0, @intCast(col)).state);

    opp.cellAt(9, 0).state = .normal; // opp settles
    garbage.releaseIncomingGarbage(&opp);
    for (0..3) |col| try testing.expect(opp.cellAt(0, @intCast(col)).is_garbage);
}

test "garbage spawn refuses to place a piece with a hole -- it stays queued until the buffer is fully clear, rather than spawning around an obstacle" {
    var b: s.Board = .{};
    var opp: s.Board = .{};
    // Something already sitting in the spawn buffer (e.g. an earlier piece
    // still waiting to fall clear) overlaps where the incoming piece would
    // land. Placing around it would leave the new piece with a hole, which
    // can deadlock against a free-standing block (see spawnGarbage's own doc
    // comment) -- so the whole piece must stay queued instead.
    opp.cellAt(0, 1).* = .{ .color = 2, .state = .normal };
    b.cellAt(5, 0).* = .{ .color = 1, .state = .normal };
    b.cellAt(5, 1).* = .{ .color = 1, .state = .normal };
    b.cellAt(5, 2).* = .{ .color = 1, .state = .normal };
    b.cellAt(5, 3).* = .{ .color = 1, .state = .normal };
    _ = sim.checkMatches(&b, &opp, no_settled); // combo of 4 -> width-3 garbage at cols 0-2
    garbage.releaseIncomingGarbage(&opp);

    // Not placed at all -- the pre-existing block is untouched, and none of
    // the piece's cells appeared with a hole around it.
    try testing.expectEqual(@as(u8, 2), opp.cellAt(0, 1).color);
    try testing.expect(!opp.cellAt(0, 1).is_garbage);
    try testing.expect(!opp.cellAt(0, 0).is_garbage);
    try testing.expect(!opp.cellAt(0, 2).is_garbage);
    try testing.expect(opp.incoming_garbage[0] != null); // still queued, retrying

    // Once the buffer clears, the very next release places the whole piece.
    opp.cellAt(0, 1).* = s.Cell{};
    garbage.releaseIncomingGarbage(&opp);
    try testing.expect(opp.cellAt(0, 0).is_garbage);
    try testing.expect(opp.cellAt(0, 1).is_garbage);
    try testing.expect(opp.cellAt(0, 2).is_garbage);
    try testing.expectEqual(@as(?s.GarbageAttack, null), opp.incoming_garbage[0]);
}

test "propagated garbage does not count toward the combo threshold" {
    var b: s.Board = .{};
    var opp: s.Board = .{};
    b.cellAt(5, 0).* = .{ .color = 1, .state = .normal };
    b.cellAt(5, 1).* = .{ .color = 1, .state = .normal };
    b.cellAt(5, 2).* = .{ .color = 1, .state = .normal };
    b.cellAt(5, 3).* = .{ .state = .normal, .is_garbage = true }; // propagates, but must not count
    _ = sim.checkMatches(&b, &opp, no_settled);

    try testing.expectEqual(@as(u8, 1), b.chain); // first match: not a chain continuation
    // Not a combo either (only 3 REAL cells matched) -- no popup, no
    // combo-sized garbage spawn, even though the connected group (including
    // the propagated garbage) has 4 members total.
    for (b.match_popups) |p| try testing.expect(!p.active);
    for (0..c.COLS) |col| try testing.expectEqual(s.CellState.empty, opp.cellAt(0, @intCast(col)).state);
}

test "combo garbage spawn sizing counts only real cells, ignoring propagated garbage" {
    var b: s.Board = .{};
    var opp: s.Board = .{};
    b.cellAt(5, 0).* = .{ .color = 1, .state = .normal };
    b.cellAt(5, 1).* = .{ .color = 1, .state = .normal };
    b.cellAt(5, 2).* = .{ .color = 1, .state = .normal };
    b.cellAt(5, 3).* = .{ .color = 1, .state = .normal }; // 4 real matched cells
    b.cellAt(5, 4).* = .{ .state = .normal, .is_garbage = true }; // propagates, doesn't count
    _ = sim.checkMatches(&b, &opp, no_settled);
    garbage.releaseIncomingGarbage(&opp);

    // real_count == 4 -> width-3 garbage row, NOT width-4 (which the total
    // member_count of 5, including the propagated cell, would wrongly
    // trigger if it weren't excluded).
    for (0..3) |col| try testing.expect(opp.cellAt(0, @intCast(col)).is_garbage);
    try testing.expectEqual(s.CellState.empty, opp.cellAt(0, 3).state);
}

test "linked garbage falls and lands as one rigid body, not per column independently" {
    var b: s.Board = .{};
    var opp: s.Board = .{};
    // A 3-wide garbage row dropping onto an UNEVEN floor: col 1 has a
    // taller obstacle (row 8) than col 0/col 2 (nothing until row 10). The
    // whole group must stop the instant col 1 makes contact, landing
    // together at row 7 -- not col 0/col 2 continuing on down past it.
    b.cellAt(10, 0).* = .{ .state = .normal, .is_garbage = true };
    b.cellAt(10, 1).* = .{ .state = .normal, .is_garbage = true };
    b.cellAt(10, 2).* = .{ .state = .normal, .is_garbage = true };
    // The obstacle itself needs anchoring all the way to row 22 (the true
    // bottom of the ring buffer) or ordinary gravity treats it as
    // unsupported and lets it fall away too, silently flattening the
    // "uneven floor" this test depends on (a recurring test-fixture
    // pitfall in this project).
    b.cellAt(18, 1).* = .{ .color = 2, .state = .normal };
    b.cellAt(19, 1).* = .{ .color = 3, .state = .normal };
    b.cellAt(20, 1).* = .{ .color = 2, .state = .normal };
    b.cellAt(21, 1).* = .{ .color = 3, .state = .normal };
    b.cellAt(22, 1).* = .{ .color = 2, .state = .normal };

    for (0..100) |_| sim.simulate(&b, &opp);

    try testing.expectEqual(s.CellState.normal, b.cellAt(17, 0).state);
    try testing.expect(b.cellAt(17, 0).is_garbage);
    try testing.expectEqual(s.CellState.normal, b.cellAt(17, 1).state);
    try testing.expect(b.cellAt(17, 1).is_garbage);
    try testing.expectEqual(s.CellState.normal, b.cellAt(17, 2).state);
    try testing.expect(b.cellAt(17, 2).is_garbage);
    // Col 0/2 did NOT continue past row 17 down toward the true floor.
    try testing.expectEqual(s.CellState.empty, b.cellAt(18, 0).state);
    try testing.expectEqual(s.CellState.empty, b.cellAt(18, 2).state);
}

test "a resting garbage group re-falls together once its support disappears" {
    var b: s.Board = .{};
    var opp: s.Board = .{};
    // Note this deliberately doesn't route the support's removal through an
    // actual match/pop -- a garbage clump resting directly on a match would
    // correctly propagate into it once triggered (see the propagation tests
    // above), which is a different scenario than what this test is after:
    // pure gravity re-evaluating a resting body once whatever was under it
    // is simply gone, regardless of why.
    b.cellAt(10, 0).* = .{ .state = .normal, .is_garbage = true };
    b.cellAt(10, 1).* = .{ .state = .normal, .is_garbage = true };
    b.cellAt(10, 2).* = .{ .state = .normal, .is_garbage = true };
    b.cellAt(19, 0).* = .{ .color = 3, .state = .normal }; // temporary support
    b.cellAt(19, 1).* = .{ .color = 4, .state = .normal };
    b.cellAt(19, 2).* = .{ .color = 3, .state = .normal };
    // True floor, anchored all the way to row 22 (the true bottom of the
    // ring buffer) -- a single row at row 20 is no longer enough on its own
    // now that the board is taller than 21 rows; it'd be just as
    // unsupported as anything else without this.
    b.cellAt(20, 0).* = .{ .color = 3, .state = .normal };
    b.cellAt(20, 1).* = .{ .color = 4, .state = .normal };
    b.cellAt(20, 2).* = .{ .color = 3, .state = .normal };
    b.cellAt(21, 0).* = .{ .color = 4, .state = .normal };
    b.cellAt(21, 1).* = .{ .color = 3, .state = .normal };
    b.cellAt(21, 2).* = .{ .color = 4, .state = .normal };
    b.cellAt(22, 0).* = .{ .color = 3, .state = .normal };
    b.cellAt(22, 1).* = .{ .color = 4, .state = .normal };
    b.cellAt(22, 2).* = .{ .color = 3, .state = .normal };

    // The garbage falls and rests at row 18, on top of the (unrelated,
    // non-matching, never-triggered) support.
    for (0..60) |_| sim.simulate(&b, &opp);
    try testing.expectEqual(s.CellState.normal, b.cellAt(18, 0).state);
    try testing.expect(b.cellAt(18, 0).is_garbage);

    // Remove the support and let gravity respond: the garbage group above
    // should fall as one body into the new gap and land on the true floor.
    b.cellAt(19, 0).* = s.Cell{};
    b.cellAt(19, 1).* = s.Cell{};
    b.cellAt(19, 2).* = s.Cell{};
    for (0..60) |_| sim.simulate(&b, &opp);

    try testing.expectEqual(s.CellState.normal, b.cellAt(19, 0).state);
    try testing.expect(b.cellAt(19, 0).is_garbage);
    try testing.expectEqual(s.CellState.normal, b.cellAt(19, 1).state);
    try testing.expect(b.cellAt(19, 1).is_garbage);
    try testing.expectEqual(s.CellState.normal, b.cellAt(19, 2).state);
    try testing.expect(b.cellAt(19, 2).is_garbage);
}

test "a real block still mid-landing-bounce still matches, and pulls in an adjacent garbage cell that's also still bouncing" {
    var b: s.Board = .{};
    var opp: s.Board = .{};
    // Real-block gravity and garbage's own rigid-body gravity are
    // independent systems, so two pieces that land "together" from the
    // player's perspective rarely finish their landing bounce on the exact
    // same frame -- checkMatches must still catch this: a cell that's
    // already touched down and just finishing its cosmetic bounce
    // (.landing) is as settled as .normal for match purposes.
    b.cellAt(15, 0).* = .{ .color = 1, .state = .normal };
    b.cellAt(15, 1).* = .{ .color = 1, .state = .normal };
    b.cellAt(15, 2).* = .{ .color = 1, .state = .landing, .timer = 3 }; // still bouncing
    b.cellAt(15, 3).* = .{ .state = .landing, .is_garbage = true, .timer = 5 }; // also still bouncing

    try testing.expect(sim.checkMatches(&b, &opp, no_settled));
    try testing.expectEqual(s.CellState.popping, b.cellAt(15, 0).state);
    try testing.expectEqual(s.CellState.popping, b.cellAt(15, 1).state);
    try testing.expectEqual(s.CellState.popping, b.cellAt(15, 2).state);
    try testing.expectEqual(s.CellState.recycling, b.cellAt(15, 3).state);
}

test "a garbage cell that finishes falling after an adjacent match already started popping still joins it, instead of being missed forever" {
    var b: s.Board = .{};
    var opp: s.Board = .{};
    // First call: an ordinary match with nothing touching it yet -- pops on
    // its own, same as always.
    b.cellAt(15, 0).* = .{ .color = 1, .state = .normal };
    b.cellAt(15, 1).* = .{ .color = 1, .state = .normal };
    b.cellAt(15, 2).* = .{ .color = 1, .state = .normal };
    _ = sim.checkMatches(&b, &opp, no_settled);
    try testing.expectEqual(s.CellState.popping, b.cellAt(15, 0).state);
    const group_end_before = b.cellAt(15, 0).pop_group_end;

    // A garbage cell then lands right next to it a few frames later (its
    // own gravity is a separate system, so it wasn't ready on the first
    // call) -- a second checkMatches call (as simulate would trigger once
    // ITS OWN landing bounce finishes) should still sweep it into the SAME
    // still-active group, not miss it because the match it touches is
    // already .popping rather than freshly color-matched.
    b.cellAt(15, 3).* = .{ .state = .normal, .is_garbage = true };
    _ = sim.checkMatches(&b, &opp, no_settled);

    try testing.expectEqual(s.CellState.recycling, b.cellAt(15, 3).state);
    try testing.expectEqual(group_end_before, b.cellAt(15, 3).pop_group_end);
    try testing.expect(b.cellAt(15, 3).garbage_reveals);
}

test "a late-joining garbage cell still follows the per-piece bottom-row rule, not just whatever group it visually joins" {
    var b: s.Board = .{};
    var opp: s.Board = .{};
    b.cellAt(15, 0).* = .{ .color = 1, .state = .normal };
    b.cellAt(15, 1).* = .{ .color = 1, .state = .normal };
    b.cellAt(15, 2).* = .{ .color = 1, .state = .normal };
    _ = sim.checkMatches(&b, &opp, no_settled);

    // A 2-tall garbage piece (one group) lands late next to the still-active
    // match: only its bottom cell (row 16) should convert, exactly as if it
    // had been caught on the very first call.
    b.cellAt(15, 3).* = .{ .state = .normal, .is_garbage = true, .garbage_group = 7 };
    b.cellAt(16, 3).* = .{ .state = .normal, .is_garbage = true, .garbage_group = 7 };
    _ = sim.checkMatches(&b, &opp, no_settled);

    try testing.expectEqual(s.CellState.recycling, b.cellAt(15, 3).state);
    try testing.expectEqual(s.CellState.recycling, b.cellAt(16, 3).state);
    try testing.expect(!b.cellAt(15, 3).garbage_reveals);
    try testing.expect(b.cellAt(16, 3).garbage_reveals);
}

test "a garbage piece that lands well after the preamble ends does not get swept into an already-resolving group" {
    var b: s.Board = .{};
    var opp: s.Board = .{};
    b.cellAt(15, 0).* = .{ .color = 1, .state = .normal };
    b.cellAt(15, 1).* = .{ .color = 1, .state = .normal };
    b.cellAt(15, 2).* = .{ .color = 1, .state = .normal };
    _ = sim.checkMatches(&b, &opp, no_settled);
    try testing.expectEqual(s.CellState.popping, b.cellAt(15, 0).state);

    // Run the group past its shared pre-pop preamble (see Cell.pre_pop_timer)
    // -- it's now genuinely mid-cascade, not just "about to start".
    for (0..@intCast(c.PRE_POP_TOTAL_FRAMES + 2)) |_| sim.simulate(&b, &opp);
    try testing.expectEqual(@as(i16, 0), b.cellAt(15, 0).pre_pop_timer);
    try testing.expect(b.cellAt(15, 0).pop_group_end > 0); // still active

    // A separate garbage piece then lands touching it -- too late to
    // plausibly be part of the same original cascade moment (see
    // isLateJoinable's own doc comment) -- it must not pop just because it
    // happens to touch an already-recycling clump.
    b.cellAt(15, 3).* = .{ .state = .normal, .is_garbage = true };
    _ = sim.checkMatches(&b, &opp, no_settled);

    try testing.expectEqual(s.CellState.normal, b.cellAt(15, 3).state);
    try testing.expect(b.cellAt(15, 3).is_garbage);
}
