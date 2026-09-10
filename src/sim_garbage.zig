// Garbage-specific simulation: spawning and the rigid-body group gravity that
// makes a connected clump fall and land as one piece, split out of sim.zig to keep it under the project's ~500-line guideline. Every entry point takes an explicit `*s.Board` so the same logic drives both boards.

const std = @import("std");
const c = @import("constants.zig");
const s = @import("state.zig");

// Drops `rows` garbage rows (each `width` cols wide, anchored at `anchor_col`,
// clamped to fit) into `target`'s offscreen spawn buffer. All-or-nothing: if any cell is already taken, the whole piece is skipped (a partial placement could deadlock against a free-standing block) -- returns whether it placed anything, so a caller can leave a failed attack queued and retry. All cells share one fresh Cell.garbage_group id, so later recycling always pulls in the whole piece.
pub fn spawnGarbage(target: *s.Board, rows: u8, width: u8, anchor_col: u8) bool {
    const clamped_rows = @min(rows, c.SPAWN_ROWS);
    const start_col = if (anchor_col + width > c.COLS) c.COLS - width else anchor_col;

    var r: u8 = 0;
    while (r < clamped_rows) : (r += 1) {
        var col = start_col;
        while (col < start_col + width) : (col += 1) {
            if (target.cellAt(r, col).state != .empty) return false;
        }
    }

    const group = target.next_garbage_group;
    target.next_garbage_group +%= 1;
    r = 0;
    while (r < clamped_rows) : (r += 1) {
        var col = start_col;
        while (col < start_col + width) : (col += 1) {
            target.cellAt(r, col).* = s.Cell{ .state = .normal, .is_garbage = true, .garbage_group = group };
        }
    }
    return true;
}

// Overwrites whatever an earlier step in the SAME chain recorded -- a x4
// chain hands over one block sized by x4 alone once it concludes, not the sum of what x2/x3/x4 would each have sent. See resolveChainEnd for where this gets sent.
pub fn queueChainGarbage(self: *s.Board, rows: u8, width: u8, anchor_col: u8) void {
    self.chain_pending_garbage = .{ .rows = rows, .width = width, .anchor_col = anchor_col };
}

// Queues a single, already-complete attack into `target`'s incoming queue,
// to land once `target` goes idle -- see releaseIncomingGarbage. Silently dropped if the queue is already full; missing one attack beats crashing or blocking every other attack behind it.
pub fn queueComboGarbage(target: *s.Board, rows: u8, width: u8, anchor_col: u8) void {
    for (&target.incoming_garbage) |*slot| {
        if (slot.* == null) {
            slot.* = .{ .rows = rows, .width = width, .anchor_col = anchor_col };
            return;
        }
    }
}

// Called once per frame per board -- seals and hands off `self`'s pending
// chain garbage to `opponent` once `self` goes idle (chain genuinely concluded). Rule 1 (garbage never falls mid-match/chain) is enforced on the receiving side instead, by releaseIncomingGarbage below.
pub fn resolveChainEnd(self: *s.Board, opponent: *s.Board) void {
    if (self.boardBusy()) return;
    if (self.chain_pending_garbage) |p| {
        queueComboGarbage(opponent, p.rows, p.width, p.anchor_col);
        self.chain_pending_garbage = null;
    }
    self.chain = 0;
}

// Called once per frame per board -- drains `self`'s incoming queue via
// spawnGarbage, but only once `self` is idle (rule 1: receiving side enforces garbage never falls mid-match/chain).
pub fn releaseIncomingGarbage(self: *s.Board) void {
    if (self.boardBusy()) return;
    for (&self.incoming_garbage) |*slot| {
        if (slot.*) |p| {
            // Stays queued (retried next frame) if the buffer has no room --
            // see spawnGarbage's all-or-nothing placement.
            if (spawnGarbage(self, p.rows, p.width, p.anchor_col)) {
                slot.* = null;
                // Drives the character portrait's "punish" reaction (see
                // state.Board.garbage_punish_timer/render_character.zig).
                self.garbage_punish_timer = c.GARBAGE_PUNISH_DISPLAY_FRAMES;
            }
        }
    }
}

fn isComponentMember(members: []const [2]u8, r: u8, col: u8) bool {
    for (members) |pos| {
        if (pos[0] == r and pos[1] == col) return true;
    }
    return false;
}

// True unless every member has room to advance one row (internal support from
// another member is ignored) -- false the instant any member is blocked, since the whole rigid body moves together.
fn garbageComponentBlocked(self: *s.Board, members: []const [2]u8) bool {
    for (members) |pos| {
        const r = pos[0];
        const col = pos[1];
        if (r + 1 >= c.ROWS) return true;
        if (isComponentMember(members, r + 1, col)) continue;
        if (self.cellAt(r + 1, col).state != .empty) return true;
    }
    return false;
}

// Garbage falls and lands as one rigid connected body, not independently per
// column -- connectivity is recomputed fresh every frame (not tracked via a persisted group id) so it stays correct as pieces pop away or clumps merge.
pub fn updateGarbageGravity(self: *s.Board) void {
    var visited: [c.ROWS][c.COLS]bool = std.mem.zeroes([c.ROWS][c.COLS]bool);
    var stack: [c.ROWS * c.COLS][2]u8 = undefined;
    var members: [c.ROWS * c.COLS][2]u8 = undefined;

    for (0..c.ROWS) |lr0| {
        for (0..c.COLS) |col0| {
            if (visited[lr0][col0]) continue;
            visited[lr0][col0] = true;
            const seed = self.cellAt(@intCast(lr0), @intCast(col0));
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
                    const n = self.cellAt(r - 1, col);
                    if (n.is_garbage and (n.state == .normal or n.state == .falling)) {
                        stack[stack_len] = .{ r - 1, col };
                        stack_len += 1;
                    }
                }
                if (r + 1 < c.ROWS and !visited[r + 1][col]) {
                    visited[r + 1][col] = true;
                    const n = self.cellAt(r + 1, col);
                    if (n.is_garbage and (n.state == .normal or n.state == .falling)) {
                        stack[stack_len] = .{ r + 1, col };
                        stack_len += 1;
                    }
                }
                if (col > 0 and !visited[r][col - 1]) {
                    visited[r][col - 1] = true;
                    const n = self.cellAt(r, col - 1);
                    if (n.is_garbage and (n.state == .normal or n.state == .falling)) {
                        stack[stack_len] = .{ r, col - 1 };
                        stack_len += 1;
                    }
                }
                if (col + 1 < c.COLS and !visited[r][col + 1]) {
                    visited[r][col + 1] = true;
                    const n = self.cellAt(r, col + 1);
                    if (n.is_garbage and (n.state == .normal or n.state == .falling)) {
                        stack[stack_len] = .{ r, col + 1 };
                        stack_len += 1;
                    }
                }
            }
            const body = members[0..member_count];

            var is_falling = false;
            for (body) |pos| {
                if (self.cellAt(pos[0], pos[1]).state == .falling) {
                    is_falling = true;
                    break;
                }
            }

            if (!is_falling) {
                // At rest: only starts moving if a gap has actually opened
                // up underneath it (e.g. something below it popped away).
                if (garbageComponentBlocked(self, body)) continue;
                for (body) |pos| {
                    const cell = self.cellAt(pos[0], pos[1]);
                    cell.state = .falling;
                    cell.fall_off = c.TILE;
                }
                continue;
            }

            // Already falling: advance the shared fall_off in lockstep -- every
            // member is guaranteed to already agree on it, since the body only ever moves together.
            const new_fall_off = self.cellAt(body[0][0], body[0][1]).fall_off - c.FALL_SPEED;
            if (new_fall_off > 0) {
                for (body) |pos| self.cellAt(pos[0], pos[1]).fall_off = new_fall_off;
                continue;
            }

            // Completed a hop: either touch down together right here, or
            // shift every member down one more row together.
            if (garbageComponentBlocked(self, body)) {
                for (body) |pos| {
                    const cell = self.cellAt(pos[0], pos[1]);
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
                const cur = self.cellAt(pos[0], pos[1]);
                const next = self.cellAt(pos[0] + 1, pos[1]);
                next.* = cur.*;
                next.state = .falling;
                next.fall_off = c.TILE;
                cur.* = s.Cell{};
            }
        }
    }
}
