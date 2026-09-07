// Cross-validates cpu_engine_garbage.settle (the engine's simplified,
// instant-resolution garbage physics) against the real game's own
// frame-by-frame rigid-body gravity (sim_garbage.updateGarbageGravity, via
// sim.simulate) -- scoped deliberately to pure gravity, no matches/pops
// involved: a garbage cell that gets swept into a pop reveals a *random*
// real color in the real game, but the engine deliberately just clears it to
// empty instead (see cpu_engine.findAndClearMatches's own doc comment) --
// an intentional, pre-existing simplification unrelated to gravity, and
// comparing across it would fail for a reason that has nothing to do with
// whether the falling/landing physics itself is correct. Gravity alone has
// no such randomness, so an exact cell-for-cell comparison is meaningful
// here in a way it wouldn't be for a scenario involving a reveal.

const std = @import("std");
const testing = std.testing;
const c = @import("constants.zig");
const s = @import("state.zig");
const sim = @import("sim.zig");
const grid_mod = @import("cpu_grid.zig");
const garbage = @import("cpu_engine_garbage.zig");

const ROWS = grid_mod.ROWS;
const COLS = grid_mod.COLS;
const EMPTY = grid_mod.EMPTY;
const GARBAGE = grid_mod.GARBAGE;
const Grid = grid_mod.Grid;

const no_settled: [c.ROWS][c.COLS]bool = std.mem.zeroes([c.ROWS][c.COLS]bool);

// Runs the real board to rest: kicks off matching for any already-matching
// static setup (mirroring sim_test.zig's own convention -- sim.simulate's
// own checkMatches call is gated behind something having *just* settled
// this frame, which a hand-built static fixture never triggers on its own),
// then lets sim.simulate carry everything -- gravity, garbage's rigid-body
// physics, any resulting pops -- the rest of the way, frame by frame, until
// nothing is left animating. Capped well above anything this file's fixtures
// should ever need, purely as a safety net against a test bug hanging.
fn realSettle(b: *s.Board, opp: *s.Board) void {
    _ = sim.checkMatches(b, opp, no_settled);
    var frames: u32 = 0;
    while (frames < 300) : (frames += 1) {
        sim.simulate(b, opp);
        if (!b.boardBusy()) break;
    }
}

fn expectExactEqual(expected: Grid, actual: Grid) !void {
    for (0..ROWS) |r| {
        for (0..COLS) |col| {
            testing.expectEqual(expected.cell[r][col], actual.cell[r][col]) catch |err| {
                std.debug.print("mismatch at row {d} col {d}: expected {d}, got {d}\n", .{ r, col, expected.cell[r][col], actual.cell[r][col] });
                return err;
            };
        }
    }
}

test "a floating garbage rectangle falls straight down to the floor, exactly like the real board" {
    var b: s.Board = .{};
    var opp: s.Board = .{};
    // Floor anchor (row 12, the true ring-buffer bottom -- see this
    // project's standing test-fixture pitfall) in varied colors so it can't
    // accidentally form a match of its own.
    b.cellAt(12, 1).* = .{ .color = 0, .state = .normal };
    b.cellAt(12, 2).* = .{ .color = 1, .state = .normal };
    b.cellAt(12, 3).* = .{ .color = 2, .state = .normal };
    // A 2x3 garbage rectangle floating well above the floor.
    b.cellAt(3, 1).* = .{ .state = .normal, .is_garbage = true };
    b.cellAt(3, 2).* = .{ .state = .normal, .is_garbage = true };
    b.cellAt(3, 3).* = .{ .state = .normal, .is_garbage = true };
    b.cellAt(4, 1).* = .{ .state = .normal, .is_garbage = true };
    b.cellAt(4, 2).* = .{ .state = .normal, .is_garbage = true };
    b.cellAt(4, 3).* = .{ .state = .normal, .is_garbage = true };

    const initial = Grid.fromBoard(&b);
    realSettle(&b, &opp);
    const real_result = Grid.fromBoard(&b);

    var engine_result = initial;
    garbage.settle(&engine_result);

    // Expected to land on rows 10-11 (directly on the row-12 anchor).
    var expected: Grid = .{};
    for ([_]u8{ 1, 2, 3 }) |col| {
        expected.cell[10][col] = GARBAGE;
        expected.cell[11][col] = GARBAGE;
    }
    try expectExactEqual(expected, real_result);
    try expectExactEqual(expected, engine_result);
}

test "a garbage slab resting unevenly on towers of different heights settles as one rigid piece at the tallest tower's height" {
    var b: s.Board = .{};
    var opp: s.Board = .{};
    // Three towers of different heights, columns 1-3, each floor-anchored
    // at row 12 (all colors chosen to alternate -- no run ever repeats
    // adjacently, either vertically within a column or horizontally across
    // the shared rows -- so nothing here accidentally matches on its own).
    b.cellAt(10, 1).* = .{ .color = 0, .state = .normal };
    b.cellAt(11, 1).* = .{ .color = 1, .state = .normal };
    b.cellAt(12, 1).* = .{ .color = 0, .state = .normal };

    b.cellAt(7, 2).* = .{ .color = 0, .state = .normal };
    b.cellAt(8, 2).* = .{ .color = 1, .state = .normal };
    b.cellAt(9, 2).* = .{ .color = 0, .state = .normal };
    b.cellAt(10, 2).* = .{ .color = 1, .state = .normal };
    b.cellAt(11, 2).* = .{ .color = 0, .state = .normal };
    b.cellAt(12, 2).* = .{ .color = 1, .state = .normal };

    b.cellAt(11, 3).* = .{ .color = 0, .state = .normal };
    b.cellAt(12, 3).* = .{ .color = 1, .state = .normal };

    // A 1x3 garbage slab floating well above all three towers.
    b.cellAt(0, 1).* = .{ .state = .normal, .is_garbage = true };
    b.cellAt(0, 2).* = .{ .state = .normal, .is_garbage = true };
    b.cellAt(0, 3).* = .{ .state = .normal, .is_garbage = true };

    const initial = Grid.fromBoard(&b);
    realSettle(&b, &opp);
    const real_result = Grid.fromBoard(&b);

    var engine_result = initial;
    garbage.settle(&engine_result);

    // The slab is blocked by column 2's tower (the tallest, topped at row
    // 7) well before columns 1 or 3's much shorter towers would stop it --
    // since it's one rigid piece, ALL of it stops at row 6, leaving a gap
    // over the two shorter towers rather than sinking into it.
    var expected: Grid = .{};
    expected.cell[6][1] = GARBAGE;
    expected.cell[6][2] = GARBAGE;
    expected.cell[6][3] = GARBAGE;
    expected.cell[10][1] = 0;
    expected.cell[11][1] = 1;
    expected.cell[7][2] = 0;
    expected.cell[8][2] = 1;
    expected.cell[9][2] = 0;
    expected.cell[10][2] = 1;
    expected.cell[11][2] = 0;
    expected.cell[11][3] = 0;
    try expectExactEqual(expected, real_result);
    try expectExactEqual(expected, engine_result);
}

test "settle treats disconnected garbage bodies independently, each falling to its own support" {
    // Not cross-validated against the real board (nothing here involves a
    // pop/reveal, and a hand-built "already broken apart" grid like this
    // stands in for what a match eating through the middle of a once-larger
    // clump would leave behind -- see cpu_engine_garbage.zig's own doc
    // comment: connectivity is recomputed fresh every call, so two pieces
    // that are no longer touching are never treated as one body just
    // because they used to be).
    var grid: Grid = .{};
    // Column 0: a lone garbage cell with nothing else in the column at all
    // -- should fall all the way to the floor.
    grid.cell[2][0] = GARBAGE;
    // Column 3: a lone garbage cell with a real-block obstacle partway down
    // -- should stop well short of the floor, resting just above it. The
    // obstacle itself is anchored all the way to the true bottom (rows 8-11,
    // alternating colors so it can't match anything) -- or it would be just
    // as unsupported as the garbage cell above it and fall away too (the
    // project's standing test-fixture pitfall, just as relevant to a
    // hand-built Grid as to a real Board).
    grid.cell[2][3] = GARBAGE;
    grid.cell[8][3] = 0;
    grid.cell[9][3] = 1;
    grid.cell[10][3] = 0;
    grid.cell[11][3] = 1;

    garbage.settle(&grid);

    try testing.expectEqual(GARBAGE, grid.cell[11][0]);
    for (0..ROWS - 1) |r| try testing.expectEqual(EMPTY, grid.cell[r][0]);

    try testing.expectEqual(GARBAGE, grid.cell[7][3]);
    try testing.expectEqual(@as(i8, 0), grid.cell[8][3]);
    try testing.expectEqual(@as(i8, 1), grid.cell[9][3]);
    try testing.expectEqual(@as(i8, 0), grid.cell[10][3]);
    try testing.expectEqual(@as(i8, 1), grid.cell[11][3]);
    for (0..7) |r| try testing.expectEqual(EMPTY, grid.cell[r][3]);
}
