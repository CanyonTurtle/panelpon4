// Tests for garbage spawning/queueing (combo/chain sizing, release timing)
// and rigid-body falling/landing, split from sim_garbage_test.zig.

const std = @import("std");
const testing = std.testing;
const c = @import("constants.zig");
const s = @import("state.zig");
const sim = @import("sim.zig");
const garbage = @import("sim_garbage.zig");

const no_settled: [c.ROWS][c.COLS]bool = std.mem.zeroes([c.ROWS][c.COLS]bool);

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

    // Mirrors main.zig's own per-frame driving order.
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

    // A 4-block match: both chain (x2) and combo are true.
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
    // Something already in the spawn buffer overlaps the landing spot --
    // placing around it would leave a hole, so the piece stays queued instead.
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
    // Not a combo either -- only 3 REAL cells matched, despite 4 total members.
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

    // real_count == 4 -> width-3, NOT width-4 from the total member_count of 5.
    for (0..3) |col| try testing.expect(opp.cellAt(0, @intCast(col)).is_garbage);
    try testing.expectEqual(s.CellState.empty, opp.cellAt(0, 3).state);
}

test "linked garbage falls and lands as one rigid body, not per column independently" {
    var b: s.Board = .{};
    var opp: s.Board = .{};
    // Dropping onto an uneven floor: col 1's taller obstacle stops the
    // whole group together at row 7, not col 0/2 continuing past it.
    b.cellAt(10, 0).* = .{ .state = .normal, .is_garbage = true };
    b.cellAt(10, 1).* = .{ .state = .normal, .is_garbage = true };
    b.cellAt(10, 2).* = .{ .state = .normal, .is_garbage = true };
    // Anchored to row 22 (the true bottom) or gravity drops it, flattening
    // the uneven floor this test depends on.
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
    // Deliberately doesn't route removal through a match/pop -- isolates
    // pure gravity re-evaluating a resting body once its support is gone.
    b.cellAt(10, 0).* = .{ .state = .normal, .is_garbage = true };
    b.cellAt(10, 1).* = .{ .state = .normal, .is_garbage = true };
    b.cellAt(10, 2).* = .{ .state = .normal, .is_garbage = true };
    b.cellAt(19, 0).* = .{ .color = 3, .state = .normal }; // temporary support
    b.cellAt(19, 1).* = .{ .color = 4, .state = .normal };
    b.cellAt(19, 2).* = .{ .color = 3, .state = .normal };
    // Anchored to row 22 (the true bottom) since the board is taller than
    // 21 rows -- row 20 alone would be unsupported.
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
    // Real-block and garbage gravity are independent, so two pieces landing
    // "together" rarely finish on the same frame -- .landing still matches.
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

    // A garbage cell lands next to it later (separate gravity system) -- a
    // second checkMatches call must still sweep it into the SAME active group.
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

    // A 2-tall piece lands late: only its bottom cell converts, as if
    // caught on the very first call.
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

    // Run past the shared pre-pop preamble -- genuinely mid-cascade now.
    for (0..@intCast(c.PRE_POP_TOTAL_FRAMES + 2)) |_| sim.simulate(&b, &opp);
    try testing.expectEqual(@as(i16, 0), b.cellAt(15, 0).pre_pop_timer);
    try testing.expect(b.cellAt(15, 0).pop_group_end > 0); // still active

    // A separate piece lands touching it -- too late to be part of the same
    // cascade moment (see isLateJoinable), so it must not pop.
    b.cellAt(15, 3).* = .{ .state = .normal, .is_garbage = true };
    _ = sim.checkMatches(&b, &opp, no_settled);

    try testing.expectEqual(s.CellState.normal, b.cellAt(15, 3).state);
    try testing.expect(b.cellAt(15, 3).is_garbage);
}

test "queueComboGarbage silently drops an attack once the incoming queue is completely full" {
    var opp: s.Board = .{};
    // Fill every slot in the incoming queue.
    for (0..opp.incoming_garbage.len) |i| {
        garbage.queueComboGarbage(&opp, @intCast(i + 1), 3, 0);
    }
    for (opp.incoming_garbage) |slot| try testing.expect(slot != null);

    // One more, distinctively marked, should be dropped, not overwrite anything.
    garbage.queueComboGarbage(&opp, 99, 3, 0);
    for (opp.incoming_garbage) |slot| try testing.expect(slot.?.rows != 99);
}
