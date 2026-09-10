// Cross-validates cpu_engine_garbage.settle against real gravity; scoped to
// pure gravity only, since a real pop's random color reveal isn't modeled.

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

// Kicks off matching for a static fixture, then lets simulate carry gravity/
// pops to rest. Frame cap is a safety net against a test bug hanging.
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
    // Floor anchor (row 12, the true ring-buffer bottom) in varied colors
    // so it can't accidentally form a match of its own.
    b.cellAt(22, 1).* = .{ .color = 0, .state = .normal };
    b.cellAt(22, 2).* = .{ .color = 1, .state = .normal };
    b.cellAt(22, 3).* = .{ .color = 2, .state = .normal };
    // A 2x3 garbage rectangle floating well above the floor.
    b.cellAt(13, 1).* = .{ .state = .normal, .is_garbage = true };
    b.cellAt(13, 2).* = .{ .state = .normal, .is_garbage = true };
    b.cellAt(13, 3).* = .{ .state = .normal, .is_garbage = true };
    b.cellAt(14, 1).* = .{ .state = .normal, .is_garbage = true };
    b.cellAt(14, 2).* = .{ .state = .normal, .is_garbage = true };
    b.cellAt(14, 3).* = .{ .state = .normal, .is_garbage = true };

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
    // Three towers (cols 1-3), floor-anchored at row 12, colors alternated
    // so nothing here accidentally matches on its own.
    b.cellAt(20, 1).* = .{ .color = 0, .state = .normal };
    b.cellAt(21, 1).* = .{ .color = 1, .state = .normal };
    b.cellAt(22, 1).* = .{ .color = 0, .state = .normal };

    b.cellAt(17, 2).* = .{ .color = 0, .state = .normal };
    b.cellAt(18, 2).* = .{ .color = 1, .state = .normal };
    b.cellAt(19, 2).* = .{ .color = 0, .state = .normal };
    b.cellAt(20, 2).* = .{ .color = 1, .state = .normal };
    b.cellAt(21, 2).* = .{ .color = 0, .state = .normal };
    b.cellAt(22, 2).* = .{ .color = 1, .state = .normal };

    b.cellAt(21, 3).* = .{ .color = 0, .state = .normal };
    b.cellAt(22, 3).* = .{ .color = 1, .state = .normal };

    // A 1x3 garbage slab floating well above all three towers.
    b.cellAt(10, 1).* = .{ .state = .normal, .is_garbage = true };
    b.cellAt(10, 2).* = .{ .state = .normal, .is_garbage = true };
    b.cellAt(10, 3).* = .{ .state = .normal, .is_garbage = true };

    const initial = Grid.fromBoard(&b);
    realSettle(&b, &opp);
    const real_result = Grid.fromBoard(&b);

    var engine_result = initial;
    garbage.settle(&engine_result);

    // Blocked by column 2's tower (tallest, topped at row 7); since it's one
    // rigid piece, ALL of it stops at row 6, leaving a gap over the rest.
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
    // Not cross-validated: a hand-built "already broken apart" grid stands
    // in for what a match eating through a clump's middle would leave.
    var grid: Grid = .{};
    // Column 0: a lone cell with nothing else in the column -- falls to the floor.
    grid.cell[2][0] = GARBAGE;
    // Column 3: a lone cell above a real-block obstacle (rows 8-11, anchored
    // to the true bottom so it isn't itself unsupported) -- rests just above it.
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
