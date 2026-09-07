// Tests for sim.zig, kept in a separate file so sim.zig itself stays under
// the project's ~500-line-per-file guideline.

const std = @import("std");
const testing = std.testing;
const c = @import("constants.zig");
const s = @import("state.zig");
const sim = @import("sim.zig");

const no_settled: [c.ROWS][c.COLS]bool = std.mem.zeroes([c.ROWS][c.COLS]bool);

test "swappable allows only empty and normal cells" {
    try testing.expect(sim.swappable(.empty));
    try testing.expect(sim.swappable(.normal));
    try testing.expect(!sim.swappable(.falling));
    try testing.expect(!sim.swappable(.popping));
    try testing.expect(!sim.swappable(.landing));
    try testing.expect(!sim.swappable(.swapping));
}

test "trySwap exchanges two normal cells and starts their slide animation" {
    s.resetForTest();
    s.cellAt(s.cursor_row, s.cursor_col).* = .{ .color = 1, .state = .normal };
    s.cellAt(s.cursor_row, s.cursor_col + 1).* = .{ .color = 2, .state = .normal };
    sim.trySwap();
    const a = s.cellAt(s.cursor_row, s.cursor_col);
    const b = s.cellAt(s.cursor_row, s.cursor_col + 1);
    try testing.expectEqual(@as(u8, 2), a.color);
    try testing.expectEqual(@as(u8, 1), b.color);
    try testing.expectEqual(s.CellState.swapping, a.state);
    try testing.expectEqual(s.CellState.swapping, b.state);
    try testing.expectEqual(@as(i8, 1), a.swap_dir);
    try testing.expectEqual(@as(i8, -1), b.swap_dir);
}

test "trySwap refuses to grab a cell mid-animation" {
    s.resetForTest();
    s.cellAt(s.cursor_row, s.cursor_col).* = .{ .color = 1, .state = .falling };
    s.cellAt(s.cursor_row, s.cursor_col + 1).* = .{ .color = 2, .state = .normal };
    sim.trySwap();
    // Nothing should have moved: a falling cell is not swappable.
    try testing.expectEqual(@as(u8, 1), s.cellAt(s.cursor_row, s.cursor_col).color);
    try testing.expectEqual(s.CellState.falling, s.cellAt(s.cursor_row, s.cursor_col).state);
}

test "trySwap is a no-op when both cells are empty" {
    s.resetForTest();
    sim.trySwap();
    try testing.expectEqual(s.CellState.empty, s.cellAt(s.cursor_row, s.cursor_col).state);
}

test "checkMatches pops a horizontal run of 3+" {
    s.resetForTest();
    s.cellAt(5, 0).* = .{ .color = 1, .state = .normal };
    s.cellAt(5, 1).* = .{ .color = 1, .state = .normal };
    s.cellAt(5, 2).* = .{ .color = 1, .state = .normal };
    const found = sim.checkMatches(no_settled);
    try testing.expect(found);
    try testing.expectEqual(s.CellState.popping, s.cellAt(5, 0).state);
    try testing.expectEqual(s.CellState.popping, s.cellAt(5, 1).state);
    try testing.expectEqual(s.CellState.popping, s.cellAt(5, 2).state);
}

test "checkMatches pops a vertical run of 3+" {
    s.resetForTest();
    s.cellAt(3, 0).* = .{ .color = 2, .state = .normal };
    s.cellAt(4, 0).* = .{ .color = 2, .state = .normal };
    s.cellAt(5, 0).* = .{ .color = 2, .state = .normal };
    try testing.expect(sim.checkMatches(no_settled));
}

test "checkMatches ignores runs shorter than 3" {
    s.resetForTest();
    s.cellAt(5, 0).* = .{ .color = 1, .state = .normal };
    s.cellAt(5, 1).* = .{ .color = 1, .state = .normal };
    s.cellAt(5, 2).* = .{ .color = 3, .state = .normal };
    try testing.expect(!sim.checkMatches(no_settled));
    try testing.expectEqual(s.CellState.normal, s.cellAt(5, 0).state);
}

test "the very first match of a fresh combo always counts as chain 1" {
    s.resetForTest();
    try testing.expectEqual(@as(u8, 0), s.chain);
    s.cellAt(5, 0).* = .{ .color = 1, .state = .normal };
    s.cellAt(5, 1).* = .{ .color = 1, .state = .normal };
    s.cellAt(5, 2).* = .{ .color = 1, .state = .normal };
    _ = sim.checkMatches(no_settled);
    try testing.expectEqual(@as(u8, 1), s.chain);
}

test "an unrelated simultaneous match does not inflate the chain" {
    s.resetForTest();
    // A chainable match at chain 0 first, to advance chain to 1.
    s.cellAt(5, 0).* = .{ .color = 1, .state = .normal };
    s.cellAt(5, 1).* = .{ .color = 1, .state = .normal };
    s.cellAt(5, 2).* = .{ .color = 1, .state = .normal };
    _ = sim.checkMatches(no_settled);
    try testing.expectEqual(@as(u8, 1), s.chain);

    // A second, unrelated match elsewhere on the board, none of whose cells
    // are chainable: should NOT bump chain further.
    s.cellAt(8, 3).* = .{ .color = 2, .state = .normal };
    s.cellAt(8, 4).* = .{ .color = 2, .state = .normal };
    s.cellAt(8, 5).* = .{ .color = 2, .state = .normal };
    _ = sim.checkMatches(no_settled);
    try testing.expectEqual(@as(u8, 1), s.chain);
}

test "a chainable match while chain > 0 does inflate the chain" {
    s.resetForTest();
    s.cellAt(5, 0).* = .{ .color = 1, .state = .normal };
    s.cellAt(5, 1).* = .{ .color = 1, .state = .normal };
    s.cellAt(5, 2).* = .{ .color = 1, .state = .normal };
    _ = sim.checkMatches(no_settled);
    try testing.expectEqual(@as(u8, 1), s.chain);

    s.cellAt(8, 3).* = .{ .color = 2, .state = .normal, .chainable = true };
    s.cellAt(8, 4).* = .{ .color = 2, .state = .normal };
    s.cellAt(8, 5).* = .{ .color = 2, .state = .normal };
    _ = sim.checkMatches(no_settled);
    try testing.expectEqual(@as(u8, 2), s.chain);
}

fn activePopupLabel() ?[]const u8 {
    for (&s.match_popups) |*p| {
        if (p.active) return p.label[0..p.label_len];
    }
    return null;
}

test "the first ordinary 3-match of a fresh chain does not spawn a popup" {
    s.resetForTest();
    s.cellAt(5, 0).* = .{ .color = 1, .state = .normal };
    s.cellAt(5, 1).* = .{ .color = 1, .state = .normal };
    s.cellAt(5, 2).* = .{ .color = 1, .state = .normal };
    _ = sim.checkMatches(no_settled);
    try testing.expectEqual(@as(u8, 1), s.chain);
    for (s.match_popups) |p| try testing.expect(!p.active);
}

test "a genuine chain match spawns an 'xN' popup" {
    s.resetForTest();
    s.cellAt(5, 0).* = .{ .color = 1, .state = .normal };
    s.cellAt(5, 1).* = .{ .color = 1, .state = .normal };
    s.cellAt(5, 2).* = .{ .color = 1, .state = .normal };
    _ = sim.checkMatches(no_settled);

    s.cellAt(8, 3).* = .{ .color = 2, .state = .normal, .chainable = true };
    s.cellAt(8, 4).* = .{ .color = 2, .state = .normal };
    s.cellAt(8, 5).* = .{ .color = 2, .state = .normal };
    _ = sim.checkMatches(no_settled);
    try testing.expectEqual(@as(u8, 2), s.chain);

    try testing.expectEqualStrings("x2", activePopupLabel().?);
}

test "a match bigger than 3 blocks is a combo even at chain 1" {
    s.resetForTest();
    s.cellAt(5, 0).* = .{ .color = 1, .state = .normal };
    s.cellAt(5, 1).* = .{ .color = 1, .state = .normal };
    s.cellAt(5, 2).* = .{ .color = 1, .state = .normal };
    s.cellAt(5, 3).* = .{ .color = 1, .state = .normal };
    s.cellAt(5, 4).* = .{ .color = 1, .state = .normal };
    _ = sim.checkMatches(no_settled);

    try testing.expectEqual(@as(u8, 1), s.chain); // not a chain continuation
    try testing.expectEqualStrings("5", activePopupLabel().?);
}

test "a match that is both a chain and a combo shows the chain label" {
    s.resetForTest();
    s.cellAt(5, 0).* = .{ .color = 1, .state = .normal };
    s.cellAt(5, 1).* = .{ .color = 1, .state = .normal };
    s.cellAt(5, 2).* = .{ .color = 1, .state = .normal };
    _ = sim.checkMatches(no_settled);

    // A 4-block chainable match: both is_chain (multiplier 2) and is_combo
    // (member_count 4) are true here.
    s.cellAt(8, 2).* = .{ .color = 2, .state = .normal, .chainable = true };
    s.cellAt(8, 3).* = .{ .color = 2, .state = .normal };
    s.cellAt(8, 4).* = .{ .color = 2, .state = .normal };
    s.cellAt(8, 5).* = .{ .color = 2, .state = .normal };
    _ = sim.checkMatches(no_settled);
    try testing.expectEqual(@as(u8, 2), s.chain);

    try testing.expectEqualStrings("x2", activePopupLabel().?);
}

test "simulate marks the whole settled stack above a cleared pop as chainable" {
    s.resetForTest();
    // A column of 3 identical blocks about to pop, with 3 more ordinary
    // settled blocks stacked directly above.
    s.cellAt(4, 0).* = .{ .color = 3, .state = .normal };
    s.cellAt(5, 0).* = .{ .color = 4, .state = .normal };
    s.cellAt(6, 0).* = .{ .color = 2, .state = .normal };
    s.cellAt(7, 0).* = .{ .color = 1, .state = .normal };
    s.cellAt(8, 0).* = .{ .color = 1, .state = .normal };
    s.cellAt(9, 0).* = .{ .color = 1, .state = .normal };
    s.cellAt(10, 0).* = .{ .color = 3, .state = .normal };

    _ = sim.checkMatches(no_settled); // starts the pop at rows 7-9
    // Run enough frames for the whole staggered pop cascade to finish
    // clearing (group_end = POP_FRAMES + (3-1)*POP_STAGGER_FRAMES). The
    // very same frame the pop clears also runs this frame's gravity step,
    // which cascades the stack above down by exactly one row (each cell
    // marked chainable rides along with its own data via a plain struct
    // copy), so the three originally-chainable cells now sit one row lower
    // than where they started (rows 5-7, not 4-6).
    const group_end = c.POP_FRAMES + 2 * c.POP_STAGGER_FRAMES;
    for (0..@intCast(group_end)) |_| sim.simulate();

    try testing.expect(s.cellAt(7, 0).chainable);
    try testing.expect(s.cellAt(6, 0).chainable);
    try testing.expect(s.cellAt(5, 0).chainable);
}

test "a gap stops chainable marking from reaching blocks above it" {
    s.resetForTest();
    s.cellAt(7, 1).* = .{ .color = 1, .state = .normal };
    s.cellAt(8, 1).* = .{ .color = 1, .state = .normal };
    s.cellAt(9, 1).* = .{ .color = 1, .state = .normal };
    s.cellAt(10, 1).* = .{ .color = 3, .state = .normal };
    // Column 2 is untouched/unrelated -- should never become chainable.
    s.cellAt(9, 2).* = .{ .color = 2, .state = .normal };
    s.cellAt(10, 2).* = .{ .color = 4, .state = .normal };

    _ = sim.checkMatches(no_settled);
    const group_end = c.POP_FRAMES + 2 * c.POP_STAGGER_FRAMES;
    for (0..@intCast(group_end)) |_| sim.simulate();

    try testing.expect(!s.cellAt(9, 2).chainable);
}

// ---------------------------------------------------------------------
// Garbage
// ---------------------------------------------------------------------

test "a garbage cell is never swappable" {
    s.resetForTest();
    s.cellAt(s.cursor_row, s.cursor_col).* = .{ .state = .normal, .is_garbage = true };
    s.cellAt(s.cursor_row, s.cursor_col + 1).* = .{ .color = 1, .state = .normal };
    sim.trySwap();
    try testing.expect(s.cellAt(s.cursor_row, s.cursor_col).is_garbage);
    try testing.expectEqual(@as(u8, 1), s.cellAt(s.cursor_row, s.cursor_col + 1).color);
}

test "a pop propagates into an orthogonally adjacent garbage cell" {
    s.resetForTest();
    s.cellAt(5, 0).* = .{ .color = 1, .state = .normal };
    s.cellAt(5, 1).* = .{ .color = 1, .state = .normal };
    s.cellAt(5, 2).* = .{ .color = 1, .state = .normal };
    s.cellAt(5, 3).* = .{ .state = .normal, .is_garbage = true }; // touches col 2
    _ = sim.checkMatches(no_settled);

    try testing.expectEqual(s.CellState.popping, s.cellAt(5, 3).state);
}

test "garbage propagation chains transitively through multiple garbage cells" {
    s.resetForTest();
    s.cellAt(5, 0).* = .{ .color = 1, .state = .normal };
    s.cellAt(5, 1).* = .{ .color = 1, .state = .normal };
    s.cellAt(5, 2).* = .{ .color = 1, .state = .normal };
    s.cellAt(6, 2).* = .{ .state = .normal, .is_garbage = true }; // touches the match
    s.cellAt(7, 2).* = .{ .state = .normal, .is_garbage = true }; // only touches the garbage above it
    _ = sim.checkMatches(no_settled);

    try testing.expectEqual(s.CellState.popping, s.cellAt(6, 2).state);
    try testing.expectEqual(s.CellState.popping, s.cellAt(7, 2).state);
}

test "an unrelated garbage cell elsewhere does not pop" {
    s.resetForTest();
    s.cellAt(5, 0).* = .{ .color = 1, .state = .normal };
    s.cellAt(5, 1).* = .{ .color = 1, .state = .normal };
    s.cellAt(5, 2).* = .{ .color = 1, .state = .normal };
    s.cellAt(9, 5).* = .{ .state = .normal, .is_garbage = true }; // far away, untouched
    _ = sim.checkMatches(no_settled);

    try testing.expectEqual(s.CellState.normal, s.cellAt(9, 5).state);
    try testing.expect(s.cellAt(9, 5).is_garbage);
}

test "a popped garbage cell reveals a fresh chainable block only once its whole group finishes" {
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

    for (0..@intCast(group_end - 1)) |_| sim.simulate();
    try testing.expectEqual(s.CellState.popping, s.cellAt(5, 3).state);
    try testing.expect(s.cellAt(5, 3).is_garbage);

    sim.simulate(); // the final frame: the whole group resolves together
    try testing.expectEqual(s.CellState.normal, s.cellAt(5, 3).state);
    try testing.expect(!s.cellAt(5, 3).is_garbage);
    try testing.expect(s.cellAt(5, 3).chainable);
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
