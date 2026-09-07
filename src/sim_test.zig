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
    try testing.expect(!s.cellAt(5, 0).flourish_flash);
    for (s.match_popups) |p| try testing.expect(!p.active);
}

test "a genuine chain match marks flourish_flash and spawns an 'xN chain!' popup" {
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

    try testing.expect(s.cellAt(8, 3).flourish_flash);
    try testing.expect(s.cellAt(8, 4).flourish_flash);
    try testing.expect(s.cellAt(8, 5).flourish_flash);

    try testing.expectEqualStrings("x2 chain!", activePopupLabel().?);
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
    try testing.expect(s.cellAt(5, 0).flourish_flash); // but still flourishes
    try testing.expectEqualStrings("5 combo!", activePopupLabel().?);
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

    try testing.expectEqualStrings("x2 chain!", activePopupLabel().?);
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
