// Tests for garbage recycling/propagation and staggered reveal timing.
// Spawn/queueing/falling tests live in sim_garbage_spawn_test.zig.

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
    // Both cells share the SAME garbage_group -- (7,2) comes along because
    // it's part of the same piece, not spatial touching (contrast sim_recycle_test.zig).
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

    // Bottom-right-to-top-left ordering: (7,2) gets an earlier own-turn
    // timer than (6,2) above it, a fixed POP_STAGGER_FRAMES apart.
    const earlier = b.cellAt(7, 2).timer;
    const later = b.cellAt(6, 2).timer;
    try testing.expectEqual(earlier + c.POP_STAGGER_FRAMES, later);
    // Both share the same group resolution timer, which here happens to
    // equal the real cells' own -- a coincidence of this layout, not a rule.
    try testing.expectEqual(b.cellAt(5, 0).pop_group_end, b.cellAt(6, 2).pop_group_end);
    try testing.expectEqual(b.cellAt(6, 2).pop_group_end, b.cellAt(7, 2).pop_group_end);
}

test "a real match's own cells free up for gravity as soon as their own pop finishes, not held hostage by a slower-finishing garbage clump in the same group" {
    var b: s.Board = .{};
    var opp: s.Board = .{};
    // Real match on row 6; garbage at row 5 sorts after it, finishing
    // POP_STAGGER_FRAMES later than the real cells.
    b.cellAt(6, 0).* = .{ .color = 1, .state = .normal };
    b.cellAt(6, 1).* = .{ .color = 1, .state = .normal };
    b.cellAt(6, 2).* = .{ .color = 1, .state = .normal };
    b.cellAt(5, 2).* = .{ .state = .normal, .is_garbage = true };
    // Unsupported above a matched cell -- proves the freed space is
    // immediately usable, not just visually cleared.
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
    try testing.expectEqual(s.CellState.falling, b.cellAt(6, 1).state);
    // Garbage is a wholly separate piece -- inert, unaffected by the real
    // match resolving around it.
    try testing.expectEqual(s.CellState.recycling, b.cellAt(5, 2).state);
    try testing.expect(b.cellAt(5, 2).is_garbage);

    for (0..@intCast(full_group_end - real_group_end)) |_| sim.simulate(&b, &opp);
    // The garbage cell now converts (this piece's only cell) and falls
    // into (6,2), which the real match freed earlier.
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
    // Floor anchored to row 22 (the true ring-buffer bottom), or gravity
    // would drop it and leave the revealed block nothing to rest on.
    b.cellAt(16, 3).* = .{ .color = 3, .state = .normal };
    b.cellAt(17, 3).* = .{ .color = 4, .state = .normal };
    b.cellAt(18, 3).* = .{ .color = 3, .state = .normal };
    b.cellAt(19, 3).* = .{ .color = 4, .state = .normal };
    b.cellAt(20, 3).* = .{ .color = 3, .state = .normal };
    b.cellAt(21, 3).* = .{ .color = 4, .state = .normal };
    b.cellAt(22, 3).* = .{ .color = 3, .state = .normal };
    _ = sim.checkMatches(&b, &opp, no_settled);
    // This match also crosses the combo threshold and spawns combo garbage
    // on opp -- expected, not something this test needs to isolate against.

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

    // Still garbage=true, but already has a real color ready for its own
    // staggered turn -- not the zero-valued default.
    try testing.expectEqual(s.CellState.recycling, b.cellAt(5, 3).state);
    try testing.expect(b.cellAt(5, 3).is_garbage);
    try testing.expect(b.cellAt(5, 3).color < c.NUM_COLORS);
}

