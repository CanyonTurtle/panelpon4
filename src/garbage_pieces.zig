// Groups settled garbage cells into their individual pieces (see
// Cell.garbage_group) and picks one cell near each piece's own geometric
// center -- split out from render_garbage.zig, which only wants to draw a
// mark there, specifically so this pure grouping logic can be unit tested
// without pulling in render_garbage.zig's own w4 draw-call dependency (see
// tests.zig's own doc comment on why render.zig/render_garbage.zig can't be
// tested directly).

const std = @import("std");
const c = @import("constants.zig");
const s = @import("state.zig");

// Finds one cell near the geometric center of each currently-settled garbage
// piece -- one per piece, even when several different pieces happen to be
// resting against each other and rendering as one seamless slab (see
// render_garbage.drawLinked/isAttached, which merge on pure spatial
// adjacency, not piece identity) with no visible seam between them. Two
// pieces merged into one slab would otherwise be indistinguishable from a
// single, larger piece -- this is what lets render_garbage.zig still mark
// them as separate blocks.
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
// Only scans the visible window (SPAWN_ROWS..ROWS), matching drawBoard's own
// range -- nothing in the offscreen spawn buffer is ever drawn, so it needs
// no mark either.
pub fn markCenters(b: *s.Board) [c.ROWS][c.COLS]bool {
    var is_center: [c.ROWS][c.COLS]bool = std.mem.zeroes([c.ROWS][c.COLS]bool);
    var visited: [c.ROWS][c.COLS]bool = std.mem.zeroes([c.ROWS][c.COLS]bool);
    var stack: [c.ROWS * c.COLS][2]u8 = undefined;
    var members: [c.ROWS * c.COLS][2]u8 = undefined;

    var lr0: u8 = c.SPAWN_ROWS;
    while (lr0 < c.ROWS) : (lr0 += 1) {
        for (0..c.COLS) |c0i| {
            const col0: u8 = @intCast(c0i);
            if (visited[lr0][col0]) continue;
            const first = b.cellAt(lr0, col0);
            if (!first.is_garbage or first.state != .normal) {
                visited[lr0][col0] = true;
                continue;
            }
            const group = first.garbage_group;

            var stack_len: usize = 0;
            var member_count: usize = 0;
            var min_row: u8 = lr0;
            var max_row: u8 = lr0;
            var min_col: u8 = col0;
            var max_col: u8 = col0;
            stack[0] = .{ lr0, col0 };
            stack_len = 1;
            visited[lr0][col0] = true;

            while (stack_len > 0) {
                stack_len -= 1;
                const pos = stack[stack_len];
                members[member_count] = pos;
                member_count += 1;
                min_row = @min(min_row, pos[0]);
                max_row = @max(max_row, pos[0]);
                min_col = @min(min_col, pos[1]);
                max_col = @max(max_col, pos[1]);
                const r = pos[0];
                const cl = pos[1];

                if (r > c.SPAWN_ROWS and !visited[r - 1][cl]) {
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

            // The piece's bounding-box center -- exact for the common case
            // (spawnGarbage always places a solid rectangle), just not
            // necessarily an actual member once a piece has been partially
            // eaten into an irregular shape -- so fall back to whichever
            // real member sits closest to it.
            const center_row = @divTrunc(@as(u16, min_row) + max_row, 2);
            const center_col = @divTrunc(@as(u16, min_col) + max_col, 2);
            var best_i: usize = 0;
            var best_dist: i32 = std.math.maxInt(i32);
            for (0..member_count) |i| {
                const dr = @as(i32, members[i][0]) - @as(i32, center_row);
                const dc = @as(i32, members[i][1]) - @as(i32, center_col);
                const dist = dr * dr + dc * dc;
                if (dist < best_dist) {
                    best_dist = dist;
                    best_i = i;
                }
            }
            is_center[members[best_i][0]][members[best_i][1]] = true;
        }
    }
    return is_center;
}

const testing = std.testing;

test "a single solid garbage piece gets exactly one center mark, at its true middle" {
    var b: s.Board = .{};
    // A 1x3 row, all default garbage_group (0) -- one piece.
    for (0..3) |i| {
        b.cellAt(15, @intCast(i)).* = .{ .state = .normal, .is_garbage = true };
    }
    const centers = markCenters(&b);
    try testing.expect(centers[15][1]); // the middle cell of 0,1,2
    try testing.expect(!centers[15][0]);
    try testing.expect(!centers[15][2]);
    var total: usize = 0;
    for (0..c.ROWS) |r| for (0..c.COLS) |col| {
        if (centers[r][col]) total += 1;
    };
    try testing.expectEqual(@as(usize, 1), total);
}

test "two different pieces resting against each other each get their own center mark" {
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
    const centers = markCenters(&b);
    var total: usize = 0;
    for (0..c.ROWS) |r| for (0..c.COLS) |col| {
        if (centers[r][col]) total += 1;
    };
    try testing.expectEqual(@as(usize, 2), total);
    // Piece A's own center: rows 14-15, cols 0-2 -> (14 or 15, 1).
    try testing.expect(centers[14][1] or centers[15][1]);
    // Piece B's own center: rows 16-17, cols 0-2 -> (16 or 17, 1).
    try testing.expect(centers[16][1] or centers[17][1]);
    // Never a mark inside either piece's non-center columns.
    for (0..c.ROWS) |r| {
        try testing.expect(!centers[r][0]);
        try testing.expect(!centers[r][2]);
    }
}

test "a piece touching a real (non-garbage) block doesn't merge with it" {
    var b: s.Board = .{};
    b.cellAt(15, 0).* = .{ .state = .normal, .is_garbage = true };
    b.cellAt(15, 1).* = .{ .color = 1, .state = .normal }; // real block, not garbage
    const centers = markCenters(&b);
    try testing.expect(centers[15][0]); // the single-cell piece is its own center
    try testing.expect(!centers[15][1]);
}
