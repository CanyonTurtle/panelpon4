// Groups settled garbage cells into pieces (Cell.garbage_group) and computes
// each piece's pixel centroid -- split out from render_garbage.zig so this pure grouping logic stays unit-testable without its w4 draw-call dependency.

const std = @import("std");
const c = @import("constants.zig");
const s = @import("state.zig");

pub const PieceCenter = struct { x: i32 = 0, y: i32 = 0 };

// A generous cap, never remotely approached in practice; extras beyond it
// are silently dropped (same reasoning as Board.spawnMatchPopup's pool-full case) -- missing one mark is harmless.
const MAX_PIECES = 32;

pub const PieceCenters = struct {
    items: [MAX_PIECES]PieceCenter = undefined,
    count: usize = 0,
};

// Finds each settled garbage piece's true pixel centroid (mean of its cells,
// not bounding-box midpoint), one per Cell.garbage_group so touching-but-distinct pieces rendered as one slab still get separate marks. Scans only the visible window; `wiped` (drawBoard's closingWipedRows()) treats wiped cells as absent.
pub fn pieceCenters(b: *s.Board, wiped: u8) PieceCenters {
    var result: PieceCenters = .{};
    var visited: [c.ROWS][c.COLS]bool = std.mem.zeroes([c.ROWS][c.COLS]bool);
    var stack: [c.ROWS * c.COLS][2]u8 = undefined;

    var lr0: u8 = c.SPAWN_ROWS;
    while (lr0 < c.ROWS) : (lr0 += 1) {
        for (0..c.COLS) |c0i| {
            const col0: u8 = @intCast(c0i);
            if (visited[lr0][col0]) continue;
            if (lr0 - c.SPAWN_ROWS < wiped) {
                visited[lr0][col0] = true;
                continue;
            }
            const first = b.cellAt(lr0, col0);
            if (!first.is_garbage or first.state != .normal) {
                visited[lr0][col0] = true;
                continue;
            }
            const group = first.garbage_group;

            var stack_len: usize = 0;
            var member_count: u32 = 0;
            var sum_row: u32 = 0;
            var sum_col: u32 = 0;
            stack[0] = .{ lr0, col0 };
            stack_len = 1;
            visited[lr0][col0] = true;

            while (stack_len > 0) {
                stack_len -= 1;
                const pos = stack[stack_len];
                member_count += 1;
                sum_row += pos[0];
                sum_col += pos[1];
                const r = pos[0];
                const cl = pos[1];

                if (r > c.SPAWN_ROWS and r - 1 - c.SPAWN_ROWS >= wiped and !visited[r - 1][cl]) {
                    const n = b.cellAt(r - 1, cl);
                    visited[r - 1][cl] = true;
                    if (n.is_garbage and n.state == .normal and n.garbage_group == group) {
                        stack[stack_len] = .{ r - 1, cl };
                        stack_len += 1;
                    }
                }
                if (r + 1 < c.ROWS and !visited[r + 1][cl]) {
                    const n = b.cellAt(r + 1, cl);
                    visited[r + 1][cl] = true;
                    if (n.is_garbage and n.state == .normal and n.garbage_group == group) {
                        stack[stack_len] = .{ r + 1, cl };
                        stack_len += 1;
                    }
                }
                if (cl > 0 and !visited[r][cl - 1]) {
                    const n = b.cellAt(r, cl - 1);
                    visited[r][cl - 1] = true;
                    if (n.is_garbage and n.state == .normal and n.garbage_group == group) {
                        stack[stack_len] = .{ r, cl - 1 };
                        stack_len += 1;
                    }
                }
                if (cl + 1 < c.COLS and !visited[r][cl + 1]) {
                    const n = b.cellAt(r, cl + 1);
                    visited[r][cl + 1] = true;
                    if (n.is_garbage and n.state == .normal and n.garbage_group == group) {
                        stack[stack_len] = .{ r, cl + 1 };
                        stack_len += 1;
                    }
                }
            }

            if (result.count < MAX_PIECES) {
                const x = c.BOARD_X + @divTrunc(c.TILE, 2) +
                    @divTrunc(@as(i32, @intCast(sum_col)) * c.TILE, @as(i32, @intCast(member_count)));
                const y = c.BOARD_Y + @divTrunc(c.TILE, 2) - @as(i32, c.SPAWN_ROWS) * c.TILE -
                    @as(i32, @intCast(b.scroll_px)) +
                    @divTrunc(@as(i32, @intCast(sum_row)) * c.TILE, @as(i32, @intCast(member_count)));
                result.items[result.count] = .{ .x = x, .y = y };
                result.count += 1;
            }
        }
    }
    return result;
}

const testing = std.testing;

test "a single solid garbage piece's centroid lands on its true middle cell" {
    var b: s.Board = .{};
    // A 1x3 row, all default garbage_group (0) -- one piece. Middle cell is
    // col 1, logical row 15 -> visible row 5.
    for (0..3) |i| {
        b.cellAt(15, @intCast(i)).* = .{ .state = .normal, .is_garbage = true };
    }
    const result = pieceCenters(&b, 0);
    try testing.expectEqual(@as(usize, 1), result.count);
    try testing.expectEqual(c.BOARD_X + 1 * c.TILE + @divTrunc(c.TILE, 2), result.items[0].x);
    try testing.expectEqual(c.BOARD_Y + 5 * c.TILE + @divTrunc(c.TILE, 2), result.items[0].y);
}

test "an even-width piece's centroid lands exactly between its two middle cells, not snapped to either" {
    var b: s.Board = .{};
    // A 1x2 row (cols 0-1) -- the true center falls exactly on the seam
    // between the two cells, not inside either one.
    b.cellAt(15, 0).* = .{ .state = .normal, .is_garbage = true };
    b.cellAt(15, 1).* = .{ .state = .normal, .is_garbage = true };
    const result = pieceCenters(&b, 0);
    try testing.expectEqual(@as(usize, 1), result.count);
    // The seam between col 0 and col 1 is exactly one tile from BOARD_X.
    try testing.expectEqual(c.BOARD_X + 1 * c.TILE, result.items[0].x);
}

test "two different pieces resting against each other each get their own centroid" {
    var b: s.Board = .{};
    // Piece A: rows 14-15, cols 0-2 (group 0, the default).
    for (0..2) |dr| {
        for (0..3) |col| {
            b.cellAt(@intCast(14 + dr), @intCast(col)).* = .{ .state = .normal, .is_garbage = true, .garbage_group = 0 };
        }
    }
    // Piece B: rows 16-17, cols 0-2, touching piece A but a DIFFERENT group --
    // one seamless slab spatially, but logically two distinct pieces.
    for (0..2) |dr| {
        for (0..3) |col| {
            b.cellAt(@intCast(16 + dr), @intCast(col)).* = .{ .state = .normal, .is_garbage = true, .garbage_group = 1 };
        }
    }
    const result = pieceCenters(&b, 0);
    try testing.expectEqual(@as(usize, 2), result.count);
    try testing.expect(result.items[0].y != result.items[1].y);
}

test "an L-shaped piece's centroid is the true mean of its cells, not its bounding box's midpoint" {
    var b: s.Board = .{};
    // An L: (15,0), (15,1), (16,0) -- bbox midpoint is the empty cell (16,1),
    // but the true mean of the 3 member cells sits closer to (15,0)/(16,0).
    b.cellAt(15, 0).* = .{ .state = .normal, .is_garbage = true };
    b.cellAt(15, 1).* = .{ .state = .normal, .is_garbage = true };
    b.cellAt(16, 0).* = .{ .state = .normal, .is_garbage = true };
    const result = pieceCenters(&b, 0);
    try testing.expectEqual(@as(usize, 1), result.count);
    // Mean col = (0+1+0)/3 = 1/3 tile right of col 0's center -- left of the
    // bbox midpoint (a full half tile further right, between cols 0 and 1).
    const bbox_midpoint_x = c.BOARD_X + c.TILE; // between cols 0 and 1
    try testing.expect(result.items[0].x < bbox_midpoint_x);
    try testing.expectEqual(c.BOARD_X + @divTrunc(c.TILE, 2) + @divTrunc(c.TILE, 3), result.items[0].x);
}

test "a piece touching a real (non-garbage) block doesn't merge with it" {
    var b: s.Board = .{};
    b.cellAt(15, 0).* = .{ .state = .normal, .is_garbage = true };
    b.cellAt(15, 1).* = .{ .color = 1, .state = .normal }; // real block, not garbage
    const result = pieceCenters(&b, 0);
    try testing.expectEqual(@as(usize, 1), result.count);
    try testing.expectEqual(c.BOARD_X + @divTrunc(c.TILE, 2), result.items[0].x);
}

test "a piece's mark shrinks with the closing wipe and vanishes once the whole piece is wiped" {
    var b: s.Board = .{};
    // A 3-tall column, col 0, visible rows 0-2 (logical rows 10-12).
    b.cellAt(10, 0).* = .{ .state = .normal, .is_garbage = true };
    b.cellAt(11, 0).* = .{ .state = .normal, .is_garbage = true };
    b.cellAt(12, 0).* = .{ .state = .normal, .is_garbage = true };

    // No wipe: centroid at the true middle (visible row 1).
    const full = pieceCenters(&b, 0);
    try testing.expectEqual(@as(usize, 1), full.count);
    try testing.expectEqual(c.BOARD_Y + 1 * c.TILE + @divTrunc(c.TILE, 2), full.items[0].y);

    // Wipe row 0 -- only rows 1-2 remain, so the centroid shifts down to the
    // seam between them, same reasoning as the even-width test above.
    const partial = pieceCenters(&b, 1);
    try testing.expectEqual(@as(usize, 1), partial.count);
    try testing.expectEqual(c.BOARD_Y + 2 * c.TILE, partial.items[0].y);

    // Wipe the whole piece -- no mark left at all, not one computed from
    // the board's real (but no-longer-visible) data.
    const gone = pieceCenters(&b, 3);
    try testing.expectEqual(@as(usize, 0), gone.count);
}

test "pieces beyond MAX_PIECES are silently dropped rather than overflowing the result" {
    var b: s.Board = .{};
    // Fill the whole visible window with one single-cell piece per cell
    // (distinct garbage_group each, so none merge) -- well over MAX_PIECES.
    var group: u8 = 0;
    var r: u8 = c.SPAWN_ROWS;
    while (r < c.ROWS) : (r += 1) {
        for (0..c.COLS) |col| {
            b.cellAt(r, @intCast(col)).* = .{ .state = .normal, .is_garbage = true, .garbage_group = group };
            group +%= 1;
        }
    }
    const result = pieceCenters(&b, 0);
    try testing.expectEqual(@as(usize, MAX_PIECES), result.count);
}
