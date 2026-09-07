// Garbage-specific simulation: spawning and the rigid-body group gravity
// that makes a connected clump fall and land as one piece -- split out from
// sim.zig to keep that file under the project's ~500-line-per-file
// guideline. See Cell.is_garbage for the broader design (propagation into a
// pop, reveal on clear, etc., which stay in sim.zig/checkMatches since
// they're tightly coupled to match detection).

const std = @import("std");
const c = @import("constants.zig");
const s = @import("state.zig");

// Drops `rows` garbage rows (each `width` columns wide, anchored at
// `anchor_col` -- clamped to fit the board, so callers can pass a match's
// own min_col without worrying about overflow) onto the board: self-inflicted
// punishment for a big combo/chain (see the call site in sim.checkMatches).
// Cells are placed at logical rows 0..rows-1, skipping any that are already
// occupied rather than overwriting the player's existing blocks. They start
// out connected (a solid rectangle), so updateGarbageGravity below picks
// them up as a single rigid body from the very next frame.
pub fn spawnGarbage(rows: u8, width: u8, anchor_col: u8) void {
    const clamped_rows = @min(rows, c.ROWS);
    const start_col = if (anchor_col + width > c.COLS) c.COLS - width else anchor_col;
    var r: u8 = 0;
    while (r < clamped_rows) : (r += 1) {
        var col = start_col;
        while (col < start_col + width) : (col += 1) {
            const cell = s.cellAt(r, col);
            if (cell.state == .empty) {
                cell.* = s.Cell{ .state = .normal, .is_garbage = true };
            }
        }
    }
}

// True if (r, col) is one of the given component's own members -- used to
// tell "internal support" (another cell of the same rigid body sitting
// directly below) apart from a genuine obstacle or empty space.
fn isComponentMember(members: []const [2]u8, r: u8, col: u8) bool {
    for (members) |pos| {
        if (pos[0] == r and pos[1] == col) return true;
    }
    return false;
}

// True if every member's cell directly below it is either another member of
// this same component (internal support -- ignored) or genuinely empty; i.e.
// the whole body has room to advance one more row. False the instant *any*
// member is blocked (by the board's edge or an occupied cell outside the
// component), since the body moves as one rigid piece.
fn garbageComponentBlocked(members: []const [2]u8) bool {
    for (members) |pos| {
        const r = pos[0];
        const col = pos[1];
        if (r + 1 >= c.ROWS) return true;
        if (isComponentMember(members, r + 1, col)) continue;
        if (s.cellAt(r + 1, col).state != .empty) return true;
    }
    return false;
}

// Garbage falls and lands as one rigid connected body, not independently per
// column like a real block -- see Cell.is_garbage -- so a piece touching
// down anywhere in the group stops the whole group at once. Connectivity is
// recomputed fresh every frame (rather than tracked via a persisted group
// id) so it stays correct as pieces pop away via propagation or a
// newly-landed clump merges with a neighboring one.
pub fn updateGarbageGravity() void {
    var visited: [c.ROWS][c.COLS]bool = std.mem.zeroes([c.ROWS][c.COLS]bool);
    var stack: [c.ROWS * c.COLS][2]u8 = undefined;
    var members: [c.ROWS * c.COLS][2]u8 = undefined;

    for (0..c.ROWS) |lr0| {
        for (0..c.COLS) |col0| {
            if (visited[lr0][col0]) continue;
            visited[lr0][col0] = true;
            const seed = s.cellAt(@intCast(lr0), @intCast(col0));
            if (!seed.is_garbage or (seed.state != .normal and seed.state != .falling)) continue;

            // Flood-fill this connected garbage body (4-connectivity),
            // same technique as checkMatches' match grouping.
            var stack_len: usize = 1;
            stack[0] = .{ @intCast(lr0), @intCast(col0) };
            var member_count: usize = 0;
            while (stack_len > 0) {
                stack_len -= 1;
                const pos = stack[stack_len];
                members[member_count] = pos;
                member_count += 1;
                const r = pos[0];
                const col = pos[1];

                if (r > 0 and !visited[r - 1][col]) {
                    visited[r - 1][col] = true;
                    const n = s.cellAt(r - 1, col);
                    if (n.is_garbage and (n.state == .normal or n.state == .falling)) {
                        stack[stack_len] = .{ r - 1, col };
                        stack_len += 1;
                    }
                }
                if (r + 1 < c.ROWS and !visited[r + 1][col]) {
                    visited[r + 1][col] = true;
                    const n = s.cellAt(r + 1, col);
                    if (n.is_garbage and (n.state == .normal or n.state == .falling)) {
                        stack[stack_len] = .{ r + 1, col };
                        stack_len += 1;
                    }
                }
                if (col > 0 and !visited[r][col - 1]) {
                    visited[r][col - 1] = true;
                    const n = s.cellAt(r, col - 1);
                    if (n.is_garbage and (n.state == .normal or n.state == .falling)) {
                        stack[stack_len] = .{ r, col - 1 };
                        stack_len += 1;
                    }
                }
                if (col + 1 < c.COLS and !visited[r][col + 1]) {
                    visited[r][col + 1] = true;
                    const n = s.cellAt(r, col + 1);
                    if (n.is_garbage and (n.state == .normal or n.state == .falling)) {
                        stack[stack_len] = .{ r, col + 1 };
                        stack_len += 1;
                    }
                }
            }
            const body = members[0..member_count];

            var is_falling = false;
            for (body) |pos| {
                if (s.cellAt(pos[0], pos[1]).state == .falling) {
                    is_falling = true;
                    break;
                }
            }

            if (!is_falling) {
                // At rest: only starts moving if a gap has actually opened
                // up underneath it (e.g. something below it popped away).
                if (garbageComponentBlocked(body)) continue;
                for (body) |pos| {
                    const cell = s.cellAt(pos[0], pos[1]);
                    cell.state = .falling;
                    cell.fall_off = c.TILE;
                }
                continue;
            }

            // Already falling: advance the shared fall_off in lockstep --
            // every member is guaranteed to already agree on it, since the
            // whole body only ever moves together.
            const new_fall_off = s.cellAt(body[0][0], body[0][1]).fall_off - c.FALL_SPEED;
            if (new_fall_off > 0) {
                for (body) |pos| s.cellAt(pos[0], pos[1]).fall_off = new_fall_off;
                continue;
            }

            // Completed a hop: either touch down together right here, or
            // shift every member down one more row together.
            if (garbageComponentBlocked(body)) {
                for (body) |pos| {
                    const cell = s.cellAt(pos[0], pos[1]);
                    cell.state = .landing;
                    cell.timer = c.LAND_FRAMES;
                    cell.fall_off = 0;
                }
                continue;
            }
            // Bottom-most rows first, so a shift never overwrites another
            // not-yet-moved member of the same body.
            var oi: usize = 1;
            while (oi < member_count) : (oi += 1) {
                const key = members[oi];
                var oj: usize = oi;
                while (oj > 0 and members[oj - 1][0] < key[0]) {
                    members[oj] = members[oj - 1];
                    oj -= 1;
                }
                members[oj] = key;
            }
            for (body) |pos| {
                const cur = s.cellAt(pos[0], pos[1]);
                const next = s.cellAt(pos[0] + 1, pos[1]);
                next.* = cur.*;
                next.state = .falling;
                next.fall_off = c.TILE;
                cur.* = s.Cell{};
            }
        }
    }
}
