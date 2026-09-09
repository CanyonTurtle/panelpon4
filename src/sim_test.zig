// Tests for sim.zig, kept in a separate file so sim.zig itself stays under
// the project's ~500-line-per-file guideline.

const std = @import("std");
const testing = std.testing;
const c = @import("constants.zig");
const s = @import("state.zig");
const sim = @import("sim.zig");
const garbage = @import("sim_garbage.zig");

const no_settled: [c.ROWS][c.COLS]bool = std.mem.zeroes([c.ROWS][c.COLS]bool);

fn activePopupLabel(b: *const s.Board) ?[]const u8 {
    for (&b.match_popups) |*p| {
        if (p.active) return p.label[0..p.label_len];
    }
    return null;
}

test "swappable allows only empty and normal cells" {
    try testing.expect(sim.swappable(.empty));
    try testing.expect(sim.swappable(.normal));
    try testing.expect(!sim.swappable(.falling));
    try testing.expect(!sim.swappable(.popping));
    try testing.expect(!sim.swappable(.landing));
    try testing.expect(!sim.swappable(.swapping));
}

test "trySwap exchanges two normal cells and starts their slide animation" {
    var b: s.Board = .{};
    const row = b.cursor_row + c.SPAWN_ROWS;
    b.cellAt(row, b.cursor_col).* = .{ .color = 1, .state = .normal };
    b.cellAt(row, b.cursor_col + 1).* = .{ .color = 2, .state = .normal };
    sim.trySwap(&b);
    const a = b.cellAt(row, b.cursor_col);
    const bb = b.cellAt(row, b.cursor_col + 1);
    try testing.expectEqual(@as(u8, 2), a.color);
    try testing.expectEqual(@as(u8, 1), bb.color);
    try testing.expectEqual(s.CellState.swapping, a.state);
    try testing.expectEqual(s.CellState.swapping, bb.state);
    try testing.expectEqual(@as(i8, 1), a.swap_dir);
    try testing.expectEqual(@as(i8, -1), bb.swap_dir);
}

test "trySwap refuses to grab a cell mid-animation" {
    var b: s.Board = .{};
    const row = b.cursor_row + c.SPAWN_ROWS;
    b.cellAt(row, b.cursor_col).* = .{ .color = 1, .state = .falling };
    b.cellAt(row, b.cursor_col + 1).* = .{ .color = 2, .state = .normal };
    sim.trySwap(&b);
    // Nothing should have moved: a falling cell is not swappable.
    try testing.expectEqual(@as(u8, 1), b.cellAt(row, b.cursor_col).color);
    try testing.expectEqual(s.CellState.falling, b.cellAt(row, b.cursor_col).state);
}

test "trySwap is a no-op when both cells are empty" {
    var b: s.Board = .{};
    sim.trySwap(&b);
    try testing.expectEqual(s.CellState.empty, b.cellAt(b.cursor_row + c.SPAWN_ROWS, b.cursor_col).state);
}

test "checkMatches pops a horizontal run of 3+" {
    var b: s.Board = .{};
    var opp: s.Board = .{};
    b.cellAt(5, 0).* = .{ .color = 1, .state = .normal };
    b.cellAt(5, 1).* = .{ .color = 1, .state = .normal };
    b.cellAt(5, 2).* = .{ .color = 1, .state = .normal };
    const found = sim.checkMatches(&b, &opp, no_settled);
    try testing.expect(found);
    try testing.expectEqual(s.CellState.popping, b.cellAt(5, 0).state);
    try testing.expectEqual(s.CellState.popping, b.cellAt(5, 1).state);
    try testing.expectEqual(s.CellState.popping, b.cellAt(5, 2).state);
}

test "checkMatches pops a vertical run of 3+" {
    var b: s.Board = .{};
    var opp: s.Board = .{};
    b.cellAt(3, 0).* = .{ .color = 2, .state = .normal };
    b.cellAt(4, 0).* = .{ .color = 2, .state = .normal };
    b.cellAt(5, 0).* = .{ .color = 2, .state = .normal };
    try testing.expect(sim.checkMatches(&b, &opp, no_settled));
}

test "checkMatches ignores runs shorter than 3" {
    var b: s.Board = .{};
    var opp: s.Board = .{};
    b.cellAt(5, 0).* = .{ .color = 1, .state = .normal };
    b.cellAt(5, 1).* = .{ .color = 1, .state = .normal };
    b.cellAt(5, 2).* = .{ .color = 3, .state = .normal };
    try testing.expect(!sim.checkMatches(&b, &opp, no_settled));
    try testing.expectEqual(s.CellState.normal, b.cellAt(5, 0).state);
}

test "the very first match of a fresh combo always counts as chain 1" {
    var b: s.Board = .{};
    var opp: s.Board = .{};
    try testing.expectEqual(@as(u8, 0), b.chain);
    b.cellAt(5, 0).* = .{ .color = 1, .state = .normal };
    b.cellAt(5, 1).* = .{ .color = 1, .state = .normal };
    b.cellAt(5, 2).* = .{ .color = 1, .state = .normal };
    _ = sim.checkMatches(&b, &opp, no_settled);
    try testing.expectEqual(@as(u8, 1), b.chain);
}

test "an unrelated simultaneous match does not inflate the chain" {
    var b: s.Board = .{};
    var opp: s.Board = .{};
    // A chainable match at chain 0 first, to advance chain to 1.
    b.cellAt(5, 0).* = .{ .color = 1, .state = .normal };
    b.cellAt(5, 1).* = .{ .color = 1, .state = .normal };
    b.cellAt(5, 2).* = .{ .color = 1, .state = .normal };
    _ = sim.checkMatches(&b, &opp, no_settled);
    try testing.expectEqual(@as(u8, 1), b.chain);

    // A second, unrelated match elsewhere on the board, none of whose cells
    // are chainable: should NOT bump chain further.
    b.cellAt(8, 3).* = .{ .color = 2, .state = .normal };
    b.cellAt(8, 4).* = .{ .color = 2, .state = .normal };
    b.cellAt(8, 5).* = .{ .color = 2, .state = .normal };
    _ = sim.checkMatches(&b, &opp, no_settled);
    try testing.expectEqual(@as(u8, 1), b.chain);
}

test "a chainable match while chain > 0 does inflate the chain" {
    var b: s.Board = .{};
    var opp: s.Board = .{};
    b.cellAt(5, 0).* = .{ .color = 1, .state = .normal };
    b.cellAt(5, 1).* = .{ .color = 1, .state = .normal };
    b.cellAt(5, 2).* = .{ .color = 1, .state = .normal };
    _ = sim.checkMatches(&b, &opp, no_settled);
    try testing.expectEqual(@as(u8, 1), b.chain);

    b.cellAt(8, 3).* = .{ .color = 2, .state = .normal, .chainable = true };
    b.cellAt(8, 4).* = .{ .color = 2, .state = .normal };
    b.cellAt(8, 5).* = .{ .color = 2, .state = .normal };
    _ = sim.checkMatches(&b, &opp, no_settled);
    try testing.expectEqual(@as(u8, 2), b.chain);
}

test "the first ordinary 3-match of a fresh chain does not spawn a popup" {
    var b: s.Board = .{};
    var opp: s.Board = .{};
    b.cellAt(5, 0).* = .{ .color = 1, .state = .normal };
    b.cellAt(5, 1).* = .{ .color = 1, .state = .normal };
    b.cellAt(5, 2).* = .{ .color = 1, .state = .normal };
    _ = sim.checkMatches(&b, &opp, no_settled);
    try testing.expectEqual(@as(u8, 1), b.chain);
    for (b.match_popups) |p| try testing.expect(!p.active);
}

test "a genuine chain match spawns an 'xN' popup" {
    var b: s.Board = .{};
    var opp: s.Board = .{};
    b.cellAt(5, 0).* = .{ .color = 1, .state = .normal };
    b.cellAt(5, 1).* = .{ .color = 1, .state = .normal };
    b.cellAt(5, 2).* = .{ .color = 1, .state = .normal };
    _ = sim.checkMatches(&b, &opp, no_settled);

    b.cellAt(8, 3).* = .{ .color = 2, .state = .normal, .chainable = true };
    b.cellAt(8, 4).* = .{ .color = 2, .state = .normal };
    b.cellAt(8, 5).* = .{ .color = 2, .state = .normal };
    _ = sim.checkMatches(&b, &opp, no_settled);
    try testing.expectEqual(@as(u8, 2), b.chain);

    try testing.expectEqualStrings("x2", activePopupLabel(&b).?);
}

test "a match bigger than 3 blocks is a combo even at chain 1" {
    var b: s.Board = .{};
    var opp: s.Board = .{};
    b.cellAt(5, 0).* = .{ .color = 1, .state = .normal };
    b.cellAt(5, 1).* = .{ .color = 1, .state = .normal };
    b.cellAt(5, 2).* = .{ .color = 1, .state = .normal };
    b.cellAt(5, 3).* = .{ .color = 1, .state = .normal };
    b.cellAt(5, 4).* = .{ .color = 1, .state = .normal };
    _ = sim.checkMatches(&b, &opp, no_settled);

    try testing.expectEqual(@as(u8, 1), b.chain); // not a chain continuation
    try testing.expectEqualStrings("5", activePopupLabel(&b).?);
}

test "a match that is both a chain and a combo shows the chain label" {
    var b: s.Board = .{};
    var opp: s.Board = .{};
    b.cellAt(5, 0).* = .{ .color = 1, .state = .normal };
    b.cellAt(5, 1).* = .{ .color = 1, .state = .normal };
    b.cellAt(5, 2).* = .{ .color = 1, .state = .normal };
    _ = sim.checkMatches(&b, &opp, no_settled);

    // A 4-block chainable match: both is_chain (multiplier 2) and is_combo
    // (member_count 4) are true here.
    b.cellAt(8, 2).* = .{ .color = 2, .state = .normal, .chainable = true };
    b.cellAt(8, 3).* = .{ .color = 2, .state = .normal };
    b.cellAt(8, 4).* = .{ .color = 2, .state = .normal };
    b.cellAt(8, 5).* = .{ .color = 2, .state = .normal };
    _ = sim.checkMatches(&b, &opp, no_settled);
    try testing.expectEqual(@as(u8, 2), b.chain);

    try testing.expectEqualStrings("x2", activePopupLabel(&b).?);
}

test "a CPU-side match spawns its popup in the micro board's own coordinate system, not the player's" {
    // checkMatches picks the popup's spawn coordinates based on `self`
    // pointer identity against the process-wide `s.cpu` singleton (see its
    // own doc comment) -- unlike every other test in this file, this one
    // has to actually use that global rather than a local `s.Board{}`, since
    // a local board's address is never `&s.cpu` and would silently fall
    // through to the player's own (much larger-scale) coordinate system.
    s.cpu = s.Board{ .rng_state = s.CPU_RNG_SEED };
    var opp: s.Board = .{};
    // A real visible row (>= SPAWN_ROWS), not one of the offscreen staging
    // rows other tests in this file use for convenience -- this test
    // actually checks the popup's Y, which is meaningless (and can go
    // negative relative to CPU_BOARD_Y) for a "match" that's really sitting
    // in the never-rendered staging area above the ceiling.
    const row = c.SPAWN_ROWS + 2;
    s.cpu.cellAt(row, 0).* = .{ .color = 1, .state = .normal };
    s.cpu.cellAt(row, 1).* = .{ .color = 1, .state = .normal };
    s.cpu.cellAt(row, 2).* = .{ .color = 1, .state = .normal };
    s.cpu.cellAt(row, 3).* = .{ .color = 1, .state = .normal };
    _ = sim.checkMatches(&s.cpu, &opp, no_settled);

    try testing.expectEqualStrings("4", activePopupLabel(&s.cpu).?);
    var popup: s.MatchPopup = undefined;
    for (s.cpu.match_popups) |p| {
        if (p.active) {
            popup = p;
            break;
        }
    }
    // The micro board (render_cpu.zig) sits in a completely different,
    // much narrower horizontal band (constants.PANEL_X sized in
    // CPU_MICRO_TILE units) than the full-scale player board (constants.
    // BOARD_X sized in TILE units) -- if the is_cpu branch in checkMatches
    // ever regresses back to always using the player's own coordinate
    // system, this popup would land far to the left of where the CPU's
    // micro board is actually drawn instead of inside it.
    try testing.expect(popup.x >= c.PANEL_X);
    try testing.expect(popup.x < c.PANEL_X + @as(i32, c.COLS) * c.CPU_MICRO_TILE);
    try testing.expect(popup.y >= c.CPU_BOARD_Y);

    s.cpu = s.Board{ .rng_state = s.CPU_RNG_SEED }; // leave the global clean for any test after this one
}

test "simulate marks the whole settled stack above a cleared pop as chainable" {
    var b: s.Board = .{};
    var opp: s.Board = .{};
    // A column of 3 identical blocks about to pop, with 3 more ordinary
    // settled blocks stacked directly above.
    b.cellAt(4, 0).* = .{ .color = 3, .state = .normal };
    b.cellAt(5, 0).* = .{ .color = 4, .state = .normal };
    b.cellAt(6, 0).* = .{ .color = 2, .state = .normal };
    b.cellAt(7, 0).* = .{ .color = 1, .state = .normal };
    b.cellAt(8, 0).* = .{ .color = 1, .state = .normal };
    b.cellAt(9, 0).* = .{ .color = 1, .state = .normal };
    // Anchored all the way to row 12 (the true bottom of the ring buffer)
    // or gravity would treat row 10 itself as unsupported and let it fall
    // away (the project's standing test-fixture pitfall).
    b.cellAt(10, 0).* = .{ .color = 3, .state = .normal };
    b.cellAt(11, 0).* = .{ .color = 4, .state = .normal };
    b.cellAt(12, 0).* = .{ .color = 2, .state = .normal };

    _ = sim.checkMatches(&b, &opp, no_settled); // starts the pop at rows 7-9
    // Run enough frames for the whole staggered pop cascade to finish
    // clearing (group_end = PRE_POP_TOTAL_FRAMES + POP_FRAMES +
    // (3-1)*POP_STAGGER_FRAMES). The very same frame the pop clears also
    // runs this frame's gravity step, which cascades the stack above down by
    // exactly one row (each cell marked chainable rides along with its own
    // data via a plain struct copy), so the three originally-chainable cells
    // now sit one row lower than where they started (rows 5-7, not 4-6).
    const group_end = c.PRE_POP_TOTAL_FRAMES + c.POP_FRAMES + 2 * c.POP_STAGGER_FRAMES;
    for (0..@intCast(group_end)) |_| sim.simulate(&b, &opp);

    try testing.expect(b.cellAt(7, 0).chainable);
    try testing.expect(b.cellAt(6, 0).chainable);
    try testing.expect(b.cellAt(5, 0).chainable);
}

test "a gap stops chainable marking from reaching blocks above it" {
    var b: s.Board = .{};
    var opp: s.Board = .{};
    // Anchored all the way to row 12 (the true bottom) -- see the previous
    // test's comment on why.
    b.cellAt(7, 1).* = .{ .color = 1, .state = .normal };
    b.cellAt(8, 1).* = .{ .color = 1, .state = .normal };
    b.cellAt(9, 1).* = .{ .color = 1, .state = .normal };
    b.cellAt(10, 1).* = .{ .color = 3, .state = .normal };
    b.cellAt(11, 1).* = .{ .color = 4, .state = .normal };
    b.cellAt(12, 1).* = .{ .color = 2, .state = .normal };
    // Column 2 is untouched/unrelated -- should never become chainable.
    b.cellAt(9, 2).* = .{ .color = 2, .state = .normal };
    b.cellAt(10, 2).* = .{ .color = 4, .state = .normal };
    b.cellAt(11, 2).* = .{ .color = 2, .state = .normal };
    b.cellAt(12, 2).* = .{ .color = 4, .state = .normal };

    _ = sim.checkMatches(&b, &opp, no_settled);
    const group_end = c.PRE_POP_TOTAL_FRAMES + c.POP_FRAMES + 2 * c.POP_STAGGER_FRAMES;
    for (0..@intCast(group_end)) |_| sim.simulate(&b, &opp);

    try testing.expect(!b.cellAt(9, 2).chainable);
}

test "a big combo drops garbage on the opponent's board, never the triggering board itself" {
    var b: s.Board = .{};
    var opp: s.Board = .{};
    // A combo of 4 -> spawns a 3-wide garbage row.
    b.cellAt(5, 0).* = .{ .color = 1, .state = .normal };
    b.cellAt(5, 1).* = .{ .color = 1, .state = .normal };
    b.cellAt(5, 2).* = .{ .color = 1, .state = .normal };
    b.cellAt(5, 3).* = .{ .color = 1, .state = .normal };
    _ = sim.checkMatches(&b, &opp, no_settled);

    // Queued on the opponent, not yet spawned -- see sim_garbage.zig's
    // queueing lifecycle (garbage no longer lands the instant a combo is
    // detected; it waits for the receiving board to go idle).
    for (0..c.COLS) |col| try testing.expectEqual(s.CellState.empty, opp.cellAt(0, @intCast(col)).state);
    garbage.releaseIncomingGarbage(&opp); // opp is idle by default -- releases immediately
    for (0..3) |col| try testing.expect(opp.cellAt(0, @intCast(col)).is_garbage);
    for (0..c.COLS) |col| try testing.expectEqual(s.CellState.empty, b.cellAt(0, @intCast(col)).state);
}

test "the hidden ring-buffer row never seeds a match on its own" {
    var b: s.Board = .{};
    var opp: s.Board = .{};
    // A vertical run of 3, with the bottom cell sitting in the one hidden
    // row (c.ROWS-1, rising in from below -- see board.doRise) -- not yet
    // promoted into the lowest *accessible* row, so this must not match.
    b.cellAt(c.ROWS - 3, 0).* = .{ .color = 1, .state = .normal };
    b.cellAt(c.ROWS - 2, 0).* = .{ .color = 1, .state = .normal };
    b.cellAt(c.ROWS - 1, 0).* = .{ .color = 1, .state = .normal };
    try testing.expect(!sim.checkMatches(&b, &opp, no_settled));
    try testing.expectEqual(s.CellState.normal, b.cellAt(c.ROWS - 1, 0).state);
}

test "the same run one row higher, fully within accessible rows, does match" {
    var b: s.Board = .{};
    var opp: s.Board = .{};
    b.cellAt(c.ROWS - 4, 0).* = .{ .color = 1, .state = .normal };
    b.cellAt(c.ROWS - 3, 0).* = .{ .color = 1, .state = .normal };
    b.cellAt(c.ROWS - 2, 0).* = .{ .color = 1, .state = .normal };
    try testing.expect(sim.checkMatches(&b, &opp, no_settled));
}

test "propagation does not pull the hidden row's garbage into an adjacent match" {
    var b: s.Board = .{};
    var opp: s.Board = .{};
    b.cellAt(c.ROWS - 2, 0).* = .{ .color = 1, .state = .normal };
    b.cellAt(c.ROWS - 2, 1).* = .{ .color = 1, .state = .normal };
    b.cellAt(c.ROWS - 2, 2).* = .{ .color = 1, .state = .normal };
    // Touches the match from directly below, but sits in the hidden row.
    b.cellAt(c.ROWS - 1, 0).* = .{ .state = .normal, .is_garbage = true };

    try testing.expect(sim.checkMatches(&b, &opp, no_settled)); // the real match itself still pops
    try testing.expectEqual(s.CellState.normal, b.cellAt(c.ROWS - 1, 0).state); // the hidden garbage isn't pulled in
    try testing.expect(b.cellAt(c.ROWS - 1, 0).is_garbage);
}
