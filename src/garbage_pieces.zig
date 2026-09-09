// Groups settled garbage cells into their individual pieces (see
// Cell.garbage_group) and computes each piece's own true pixel-space
// centroid -- split out from render_garbage.zig, which only wants to draw a
// mark there, specifically so this pure grouping logic can be unit tested
// without pulling in render_garbage.zig's own w4 draw-call dependency (see
// tests.zig's own doc comment on why render.zig/render_garbage.zig can't be
// tested directly).

const std = @import("std");
const c = @import("constants.zig");
const s = @import("state.zig");

pub const PieceCenter = struct { x: i32 = 0, y: i32 = 0 };

// A generous cap -- board cells are the hard upper bound on how many
// distinct pieces could conceivably coexist, but that's never remotely
// approached in practice. Extra pieces beyond this are silently dropped
// (same reasoning as Board.spawnMatchPopup's identical pool-full case):
// missing one mark is harmless.
const MAX_PIECES = 32;

pub const PieceCenters = struct {
    items: [MAX_PIECES]PieceCenter = undefined,
    count: usize = 0,
};

// Finds the true pixel-space centroid (the mean position of every one of
// its own cells, not just its bounding box's midpoint -- see below) of each
// currently-settled garbage piece -- one per piece, even when several
// different pieces happen to be resting against each other and rendering as
// one seamless slab (see render_garbage.drawLinked/isAttached, which merge
// on pure spatial adjacency, not piece identity) with no visible seam
// between them. Two pieces merged into one slab would otherwise be
// indistinguishable from a single, larger piece -- this is what lets
// render_garbage.zig still mark them as separate blocks.
//
// A "piece" here is a maximal 4-connected run of settled (`.normal`) garbage
// cells sharing the same Cell.garbage_group -- deliberately narrower than
// isAttached's own notion of "attached" (which also counts falling/landing/
// early-recycling cells): those are already visually in motion or mid-event
// and don't need a center mark of their own. Garbage_group wraps (see its
// own doc comment on Cell), so a piece spawned 256+ events ago could in
// theory collide with a same-numbered piece elsewhere -- an accepted,
// extremely rare approximation already relied on elsewhere (see
// sim_matches.checkMatches' own "below_same_piece" checks), not something
// this needs to solve any more robustly than the rest of the codebase
// already does.
//
// The centroid is the *mean* of every member cell's own pixel center, not
// its bounding box's midpoint -- identical for a solid rectangle (the
// common case: spawnGarbage always places one), but meaningfully different
// for a piece that's been eaten into an irregular shape. For an even-sized
// piece this deliberately lands between two cells rather than snapping to
// whichever one happens to be closest, so the mark sits at the piece's
// actual center regardless of its shape or size.
//
// Only scans the visible window (SPAWN_ROWS..ROWS), matching drawBoard's own
// range -- nothing in the offscreen spawn buffer is ever drawn, so it needs
// no mark either. `wiped` is drawBoard's own closingWipedRows() count (rows
// already "popped" by the closing wipe, from the ceiling down, once a match
// concludes -- 0 during ordinary play): a cell in a wiped row is treated
// exactly like it isn't there at all, the same as drawBoard's own per-row
// skip, so a piece's mark shrinks/recenters in sync with the wipe as it
// eats into it, and vanishes outright once the whole piece (or the whole
// board, once the match is fully over) has been wiped -- rather than a
// mark computed from the board's *real* underlying data hanging in the air
// over a wipe that's already visually cleared the piece it belonged to.
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
    // Piece B: rows 16-17, cols 0-2, directly below and touching piece A --
    // a DIFFERENT group, so spatially it's one seamless slab (see
    // render_garbage.drawLinked/isAttached, which don't care about group at
    // all) but logically two distinct pieces.
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
    // An L: (15,0), (15,1), (16,0) -- bounding box is 2x2 (cols 0-1, rows
    // 15-16), whose midpoint would be the (empty) cell (16,1), but the true
    // mean of the 3 actual member cells sits closer to (15,0)/(16,0).
    b.cellAt(15, 0).* = .{ .state = .normal, .is_garbage = true };
    b.cellAt(15, 1).* = .{ .state = .normal, .is_garbage = true };
    b.cellAt(16, 0).* = .{ .state = .normal, .is_garbage = true };
    const result = pieceCenters(&b, 0);
    try testing.expectEqual(@as(usize, 1), result.count);
    // Mean col = (0+1+0)/3 = 1/3 of a tile right of col 0's own center --
    // left of the bounding box's midpoint (which would fall a full half
    // tile further right, between cols 0 and 1).
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

    // Wipe row 0 (the ceiling-most) -- only rows 1-2 remain, so the
    // centroid shifts down to the seam between them, same reasoning as the
    // even-width test above.
    const partial = pieceCenters(&b, 1);
    try testing.expectEqual(@as(usize, 1), partial.count);
    try testing.expectEqual(c.BOARD_Y + 2 * c.TILE, partial.items[0].y);

    // Wipe the whole piece -- no mark left at all, not one computed from
    // the board's real (but no-longer-visible) data.
    const gone = pieceCenters(&b, 3);
    try testing.expectEqual(@as(usize, 0), gone.count);
}
