// Tests for garbage-block behavior (spawning, propagation, reveal, and the
// rigid-body group gravity in sim_garbage.zig) -- kept in a separate file so
// sim_test.zig itself stays under the project's ~500-line-per-file
// guideline.

const std = @import("std");
const testing = std.testing;
const c = @import("constants.zig");
const s = @import("state.zig");
const sim = @import("sim.zig");

const no_settled: [c.ROWS][c.COLS]bool = std.mem.zeroes([c.ROWS][c.COLS]bool);

test "a garbage cell is never swappable" {
    s.resetForTest();
    s.cellAt(s.cursor_row, s.cursor_col).* = .{ .state = .normal, .is_garbage = true };
    s.cellAt(s.cursor_row, s.cursor_col + 1).* = .{ .color = 1, .state = .normal };
    sim.trySwap();
    try testing.expect(s.cellAt(s.cursor_row, s.cursor_col).is_garbage);
    try testing.expectEqual(@as(u8, 1), s.cellAt(s.cursor_row, s.cursor_col + 1).color);
}

test "a match propagates into an orthogonally adjacent garbage cell, recycling it" {
    s.resetForTest();
    s.cellAt(5, 0).* = .{ .color = 1, .state = .normal };
    s.cellAt(5, 1).* = .{ .color = 1, .state = .normal };
    s.cellAt(5, 2).* = .{ .color = 1, .state = .normal };
    s.cellAt(5, 3).* = .{ .state = .normal, .is_garbage = true }; // touches col 2
    _ = sim.checkMatches(no_settled);

    try testing.expectEqual(s.CellState.recycling, s.cellAt(5, 3).state);
}

test "garbage propagation chains transitively through multiple garbage cells" {
    s.resetForTest();
    s.cellAt(5, 0).* = .{ .color = 1, .state = .normal };
    s.cellAt(5, 1).* = .{ .color = 1, .state = .normal };
    s.cellAt(5, 2).* = .{ .color = 1, .state = .normal };
    s.cellAt(6, 2).* = .{ .state = .normal, .is_garbage = true }; // touches the match
    s.cellAt(7, 2).* = .{ .state = .normal, .is_garbage = true }; // only touches the garbage above it
    _ = sim.checkMatches(no_settled);

    try testing.expectEqual(s.CellState.recycling, s.cellAt(6, 2).state);
    try testing.expectEqual(s.CellState.recycling, s.cellAt(7, 2).state);
}

test "recycling cells in the same group are staggered one at a time, not simultaneous" {
    s.resetForTest();
    s.cellAt(5, 0).* = .{ .color = 1, .state = .normal };
    s.cellAt(5, 1).* = .{ .color = 1, .state = .normal };
    s.cellAt(5, 2).* = .{ .color = 1, .state = .normal };
    s.cellAt(6, 2).* = .{ .state = .normal, .is_garbage = true }; // touches the match
    s.cellAt(7, 2).* = .{ .state = .normal, .is_garbage = true }; // touches the garbage above it
    _ = sim.checkMatches(no_settled);

    // Row-major member ordering puts (6,2) before (7,2), so (6,2) gets an
    // earlier own-turn timer than (7,2) -- a fixed delay apart (see
    // POP_STAGGER_FRAMES), not the same instant. This staggered timer is
    // exactly what render.drawRecyclingCell uses to reveal each one on its
    // own turn, one cell at a time, rather than all at once.
    const earlier = s.cellAt(6, 2).timer;
    const later = s.cellAt(7, 2).timer;
    try testing.expectEqual(earlier + c.POP_STAGGER_FRAMES, later);
    // Both members (and the 3 real matched cells) share the same whole-group
    // resolution timer regardless of their own individual stagger.
    try testing.expectEqual(s.cellAt(5, 0).pop_group_end, s.cellAt(6, 2).pop_group_end);
    try testing.expectEqual(s.cellAt(6, 2).pop_group_end, s.cellAt(7, 2).pop_group_end);
}

test "an unrelated garbage cell elsewhere does not recycle" {
    s.resetForTest();
    s.cellAt(5, 0).* = .{ .color = 1, .state = .normal };
    s.cellAt(5, 1).* = .{ .color = 1, .state = .normal };
    s.cellAt(5, 2).* = .{ .color = 1, .state = .normal };
    s.cellAt(9, 5).* = .{ .state = .normal, .is_garbage = true }; // far away, untouched
    _ = sim.checkMatches(no_settled);

    try testing.expectEqual(s.CellState.normal, s.cellAt(9, 5).state);
    try testing.expect(s.cellAt(9, 5).is_garbage);
}

test "a recycled garbage cell reveals a fresh chainable block only once its whole group finishes" {
    s.resetForTest();
    s.cellAt(5, 0).* = .{ .color = 1, .state = .normal };
    s.cellAt(5, 1).* = .{ .color = 1, .state = .normal };
    s.cellAt(5, 2).* = .{ .color = 1, .state = .normal };
    s.cellAt(5, 3).* = .{ .state = .normal, .is_garbage = true };
    // A genuine floor directly below the garbage cell -- anchored all the
    // way to row 10 (the true bottom of the ring buffer), or gravity would
    // treat the "floor" itself as unsupported and let it fall away, leaving
    // the revealed block nothing to rest on (the project's standing
    // test-fixture pitfall). This keeps the revealed block at a known
    // position (row 5) so the assertions below are unambiguous.
    s.cellAt(6, 3).* = .{ .color = 3, .state = .normal };
    s.cellAt(7, 3).* = .{ .color = 4, .state = .normal };
    s.cellAt(8, 3).* = .{ .color = 3, .state = .normal };
    s.cellAt(9, 3).* = .{ .color = 4, .state = .normal };
    s.cellAt(10, 3).* = .{ .color = 3, .state = .normal };
    _ = sim.checkMatches(no_settled);
    // (This match's 4 members -- 3 real + 1 propagated garbage -- also cross
    // the combo threshold and spawn combo garbage at row 0 elsewhere on the
    // board; that's correct, expected behavior for a match this size, not
    // something this test needs to isolate against.)

    const member_count = 4; // 3 matched + 1 propagated garbage
    const group_end: i16 = c.POP_FRAMES + (member_count - 1) * c.POP_STAGGER_FRAMES;
    const color_at_start = s.cellAt(5, 3).color;

    for (0..@intCast(group_end - 1)) |_| sim.simulate();
    try testing.expectEqual(s.CellState.recycling, s.cellAt(5, 3).state);
    try testing.expect(s.cellAt(5, 3).is_garbage);
    // The color doesn't change while recycling -- it was picked once, up
    // front, when the whole event was first detected.
    try testing.expectEqual(color_at_start, s.cellAt(5, 3).color);

    sim.simulate(); // the final frame: the whole group resolves together
    try testing.expectEqual(s.CellState.normal, s.cellAt(5, 3).state);
    try testing.expect(!s.cellAt(5, 3).is_garbage);
    try testing.expect(s.cellAt(5, 3).chainable);
    // Reveal doesn't reassign the color either -- what the player saw
    // throughout the pop is exactly what it becomes.
    try testing.expectEqual(color_at_start, s.cellAt(5, 3).color);
}

test "a garbage cell's color is picked the instant recycling starts, not at reveal" {
    s.resetForTest();
    s.cellAt(5, 0).* = .{ .color = 1, .state = .normal };
    s.cellAt(5, 1).* = .{ .color = 1, .state = .normal };
    s.cellAt(5, 2).* = .{ .color = 1, .state = .normal };
    s.cellAt(5, 3).* = .{ .state = .normal, .is_garbage = true };
    _ = sim.checkMatches(no_settled);

    // Still garbage=true (hasn't resolved yet) but already has a real color
    // ready for the moment its own staggered turn comes up (see
    // render.drawRecyclingCell) -- not still the zero-valued default a
    // genuinely-unrevealed cell would have.
    try testing.expectEqual(s.CellState.recycling, s.cellAt(5, 3).state);
    try testing.expect(s.cellAt(5, 3).is_garbage);
    try testing.expect(s.cellAt(5, 3).color < c.NUM_COLORS);
}

test "a combo of 4 spawns a 3-wide garbage row anchored at the match" {
    s.resetForTest();
    s.cellAt(5, 0).* = .{ .color = 1, .state = .normal };
    s.cellAt(5, 1).* = .{ .color = 1, .state = .normal };
    s.cellAt(5, 2).* = .{ .color = 1, .state = .normal };
    s.cellAt(5, 3).* = .{ .color = 1, .state = .normal };
    _ = sim.checkMatches(no_settled);

    for (0..3) |col| try testing.expect(s.cellAt(0, @intCast(col)).is_garbage);
    try testing.expectEqual(s.CellState.empty, s.cellAt(0, 3).state);
}

test "a combo of 5 spawns a 4-wide garbage row" {
    s.resetForTest();
    s.cellAt(5, 0).* = .{ .color = 1, .state = .normal };
    s.cellAt(5, 1).* = .{ .color = 1, .state = .normal };
    s.cellAt(5, 2).* = .{ .color = 1, .state = .normal };
    s.cellAt(5, 3).* = .{ .color = 1, .state = .normal };
    s.cellAt(5, 4).* = .{ .color = 1, .state = .normal };
    _ = sim.checkMatches(no_settled);

    for (0..4) |col| try testing.expect(s.cellAt(0, @intCast(col)).is_garbage);
    try testing.expectEqual(s.CellState.empty, s.cellAt(0, 4).state);
}

test "a combo of 6 or more spawns a full garbage row" {
    s.resetForTest();
    for (0..6) |col| s.cellAt(5, @intCast(col)).* = .{ .color = 1, .state = .normal };
    _ = sim.checkMatches(no_settled);

    for (0..c.COLS) |col| try testing.expect(s.cellAt(0, @intCast(col)).is_garbage);
}

test "the first ordinary 3-match never spawns garbage" {
    s.resetForTest();
    s.cellAt(5, 0).* = .{ .color = 1, .state = .normal };
    s.cellAt(5, 1).* = .{ .color = 1, .state = .normal };
    s.cellAt(5, 2).* = .{ .color = 1, .state = .normal };
    _ = sim.checkMatches(no_settled);

    for (0..c.COLS) |col| try testing.expectEqual(s.CellState.empty, s.cellAt(0, @intCast(col)).state);
}

test "a chain spawns full garbage rows scaled by the multiplier" {
    s.resetForTest();
    s.cellAt(5, 0).* = .{ .color = 1, .state = .normal };
    s.cellAt(5, 1).* = .{ .color = 1, .state = .normal };
    s.cellAt(5, 2).* = .{ .color = 1, .state = .normal };
    _ = sim.checkMatches(no_settled); // chain 0 -> 1, ordinary, no garbage

    s.cellAt(8, 3).* = .{ .color = 2, .state = .normal, .chainable = true };
    s.cellAt(8, 4).* = .{ .color = 2, .state = .normal };
    s.cellAt(8, 5).* = .{ .color = 2, .state = .normal };
    _ = sim.checkMatches(no_settled); // chain 1 -> 2 (x2): 1 full row
    try testing.expectEqual(@as(u8, 2), s.chain);
    for (0..c.COLS) |col| try testing.expect(s.cellAt(0, @intCast(col)).is_garbage);

    // Clear what the x2 event just spawned so the x3 assertion below is
    // unambiguous about what *this* event produces.
    for (0..c.COLS) |col| s.cellAt(0, @intCast(col)).* = .{};

    s.cellAt(9, 0).* = .{ .color = 3, .state = .normal, .chainable = true };
    s.cellAt(9, 1).* = .{ .color = 3, .state = .normal };
    s.cellAt(9, 2).* = .{ .color = 3, .state = .normal };
    _ = sim.checkMatches(no_settled); // chain 2 -> 3 (x3): 2 full rows
    try testing.expectEqual(@as(u8, 3), s.chain);
    for (0..2) |row| {
        for (0..c.COLS) |col| try testing.expect(s.cellAt(@intCast(row), @intCast(col)).is_garbage);
    }
}

test "a match that is both a chain and a combo spawns chain-shaped garbage, not combo-shaped" {
    s.resetForTest();
    s.cellAt(5, 0).* = .{ .color = 1, .state = .normal };
    s.cellAt(5, 1).* = .{ .color = 1, .state = .normal };
    s.cellAt(5, 2).* = .{ .color = 1, .state = .normal };
    _ = sim.checkMatches(no_settled);

    // A 4-block chainable match: both is_chain (x2) and is_combo (4 blocks)
    // are true. Chain-shaped (1 full row) should win, not combo-shaped
    // (a 3-wide row).
    s.cellAt(8, 2).* = .{ .color = 2, .state = .normal, .chainable = true };
    s.cellAt(8, 3).* = .{ .color = 2, .state = .normal };
    s.cellAt(8, 4).* = .{ .color = 2, .state = .normal };
    s.cellAt(8, 5).* = .{ .color = 2, .state = .normal };
    _ = sim.checkMatches(no_settled);
    try testing.expectEqual(@as(u8, 2), s.chain);

    for (0..c.COLS) |col| try testing.expect(s.cellAt(0, @intCast(col)).is_garbage);
}

test "garbage spawn skips cells that are already occupied, rather than overwriting them" {
    s.resetForTest();
    s.cellAt(0, 1).* = .{ .color = 2, .state = .normal }; // pre-existing, must survive
    s.cellAt(5, 0).* = .{ .color = 1, .state = .normal };
    s.cellAt(5, 1).* = .{ .color = 1, .state = .normal };
    s.cellAt(5, 2).* = .{ .color = 1, .state = .normal };
    s.cellAt(5, 3).* = .{ .color = 1, .state = .normal };
    _ = sim.checkMatches(no_settled); // combo of 4 -> width-3 garbage at cols 0-2

    try testing.expectEqual(@as(u8, 2), s.cellAt(0, 1).color);
    try testing.expect(!s.cellAt(0, 1).is_garbage);
    try testing.expect(s.cellAt(0, 0).is_garbage);
    try testing.expect(s.cellAt(0, 2).is_garbage);
}

test "propagated garbage does not count toward the combo threshold" {
    s.resetForTest();
    s.cellAt(5, 0).* = .{ .color = 1, .state = .normal };
    s.cellAt(5, 1).* = .{ .color = 1, .state = .normal };
    s.cellAt(5, 2).* = .{ .color = 1, .state = .normal };
    s.cellAt(5, 3).* = .{ .state = .normal, .is_garbage = true }; // propagates, but must not count
    _ = sim.checkMatches(no_settled);

    try testing.expectEqual(@as(u8, 1), s.chain); // first match: not a chain continuation
    // Not a combo either (only 3 REAL cells matched) -- no popup, no
    // combo-sized garbage spawn, even though the connected group (including
    // the propagated garbage) has 4 members total.
    for (s.match_popups) |p| try testing.expect(!p.active);
    for (0..c.COLS) |col| try testing.expectEqual(s.CellState.empty, s.cellAt(0, @intCast(col)).state);
}

test "combo garbage spawn sizing counts only real cells, ignoring propagated garbage" {
    s.resetForTest();
    s.cellAt(5, 0).* = .{ .color = 1, .state = .normal };
    s.cellAt(5, 1).* = .{ .color = 1, .state = .normal };
    s.cellAt(5, 2).* = .{ .color = 1, .state = .normal };
    s.cellAt(5, 3).* = .{ .color = 1, .state = .normal }; // 4 real matched cells
    s.cellAt(5, 4).* = .{ .state = .normal, .is_garbage = true }; // propagates, doesn't count
    _ = sim.checkMatches(no_settled);

    // real_count == 4 -> width-3 garbage row, NOT width-4 (which the total
    // member_count of 5, including the propagated cell, would wrongly
    // trigger if it weren't excluded).
    for (0..3) |col| try testing.expect(s.cellAt(0, @intCast(col)).is_garbage);
    try testing.expectEqual(s.CellState.empty, s.cellAt(0, 3).state);
}

test "linked garbage falls and lands as one rigid body, not per column independently" {
    s.resetForTest();
    // A 3-wide garbage row dropping onto an UNEVEN floor: col 1 has a
    // taller obstacle (row 8) than col 0/col 2 (nothing until row 10). The
    // whole group must stop the instant col 1 makes contact, landing
    // together at row 7 -- not col 0/col 2 continuing on down past it.
    s.cellAt(0, 0).* = .{ .state = .normal, .is_garbage = true };
    s.cellAt(0, 1).* = .{ .state = .normal, .is_garbage = true };
    s.cellAt(0, 2).* = .{ .state = .normal, .is_garbage = true };
    // The obstacle itself needs anchoring all the way to row 10 (the true
    // bottom of the ring buffer) or ordinary gravity treats it as
    // unsupported and lets it fall away too, silently flattening the
    // "uneven floor" this test depends on (a recurring test-fixture
    // pitfall in this project).
    s.cellAt(8, 1).* = .{ .color = 2, .state = .normal };
    s.cellAt(9, 1).* = .{ .color = 3, .state = .normal };
    s.cellAt(10, 1).* = .{ .color = 2, .state = .normal };

    for (0..100) |_| sim.simulate();

    try testing.expectEqual(s.CellState.normal, s.cellAt(7, 0).state);
    try testing.expect(s.cellAt(7, 0).is_garbage);
    try testing.expectEqual(s.CellState.normal, s.cellAt(7, 1).state);
    try testing.expect(s.cellAt(7, 1).is_garbage);
    try testing.expectEqual(s.CellState.normal, s.cellAt(7, 2).state);
    try testing.expect(s.cellAt(7, 2).is_garbage);
    // Col 0/2 did NOT continue past row 7 down toward the true floor.
    try testing.expectEqual(s.CellState.empty, s.cellAt(8, 0).state);
    try testing.expectEqual(s.CellState.empty, s.cellAt(8, 2).state);
}

test "a resting garbage group re-falls together once its support disappears" {
    s.resetForTest();
    // Note this deliberately doesn't route the support's removal through an
    // actual match/pop -- a garbage clump resting directly on a match would
    // correctly propagate into it once triggered (see the propagation tests
    // above), which is a different scenario than what this test is after:
    // pure gravity re-evaluating a resting body once whatever was under it
    // is simply gone, regardless of why.
    s.cellAt(0, 0).* = .{ .state = .normal, .is_garbage = true };
    s.cellAt(0, 1).* = .{ .state = .normal, .is_garbage = true };
    s.cellAt(0, 2).* = .{ .state = .normal, .is_garbage = true };
    s.cellAt(9, 0).* = .{ .color = 3, .state = .normal }; // temporary support
    s.cellAt(9, 1).* = .{ .color = 4, .state = .normal };
    s.cellAt(9, 2).* = .{ .color = 3, .state = .normal };
    s.cellAt(10, 0).* = .{ .color = 3, .state = .normal }; // true floor
    s.cellAt(10, 1).* = .{ .color = 4, .state = .normal };
    s.cellAt(10, 2).* = .{ .color = 3, .state = .normal };

    // The garbage falls and rests at row 8, on top of the (unrelated,
    // non-matching, never-triggered) support.
    for (0..60) |_| sim.simulate();
    try testing.expectEqual(s.CellState.normal, s.cellAt(8, 0).state);
    try testing.expect(s.cellAt(8, 0).is_garbage);

    // Remove the support and let gravity respond: the garbage group above
    // should fall as one body into the new gap and land on the true floor.
    s.cellAt(9, 0).* = s.Cell{};
    s.cellAt(9, 1).* = s.Cell{};
    s.cellAt(9, 2).* = s.Cell{};
    for (0..60) |_| sim.simulate();

    try testing.expectEqual(s.CellState.normal, s.cellAt(9, 0).state);
    try testing.expect(s.cellAt(9, 0).is_garbage);
    try testing.expectEqual(s.CellState.normal, s.cellAt(9, 1).state);
    try testing.expect(s.cellAt(9, 1).is_garbage);
    try testing.expectEqual(s.CellState.normal, s.cellAt(9, 2).state);
    try testing.expect(s.cellAt(9, 2).is_garbage);
}
