// Garbage-specific simulation: spawning and the rigid-body group gravity
// that makes a connected clump fall and land as one piece -- split out from
// sim.zig to keep that file under the project's ~500-line-per-file
// guideline. See Cell.is_garbage for the broader design (propagation into a
// pop, reveal on clear, etc., which stay in sim.zig/checkMatches since
// they're tightly coupled to match detection).
//
// Every entry point takes an explicit `*s.Board` (see state.zig) so the same
// logic drives both the player's and the CPU's board.

const std = @import("std");
const c = @import("constants.zig");
const s = @import("state.zig");

// Drops `rows` garbage rows (each `width` columns wide, anchored at
// `anchor_col` -- clamped to fit the board, so callers can pass a match's
// own min_col without worrying about overflow) onto `target`, placed
// entirely within the offscreen spawn buffer (logical rows 0..SPAWN_ROWS-1 --
// see constants.SPAWN_ROWS/Board.physRow), never directly onto the visible
// board: garbage is never self-inflicted in vs-CPU play, so this is always
// called with the *other* board than the one whose combo/chain triggered it
// (see the call site in sim.checkMatches).
//
// All-or-nothing: if any cell the piece would occupy is already taken (most
// likely by an earlier piece still waiting in the buffer to fall clear), the
// whole piece is skipped rather than placed with holes around whatever's in
// the way -- a partially-placed piece could snag on a free-standing block
// and deadlock (unable to fall itself, while also blocking that block from
// falling). Returns whether it actually placed anything, so a caller queuing
// this can leave it queued and retry once the buffer has room (see
// releaseIncomingGarbage below) instead of losing the attack outright.
//
// A placed piece starts out connected (a solid rectangle), so
// updateGarbageGravity picks it up as a single rigid body from the very next
// frame -- falling out of the buffer into view the same way any other
// garbage falls -- and all its cells share one fresh Cell.garbage_group id
// (this is the *only* place a new one is handed out), so a match recycling
// any part of this piece later always pulls in the whole thing, and never
// bleeds into some other piece it merely happens to be touching by then.
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

// Garbage queueing: rather than spawning the instant a combo/chain is
// detected (which used to let it fall mid-cascade, and let a multi-step
// chain dribble out several separate blocks as it grew), every attack now
// waits in a queue and only actually lands via spawnGarbage once the
// relevant board is idle -- see sim.checkMatches (the only caller of
// queueChainGarbage/queueComboGarbage) and main.zig (which drives
// resolveChainEnd/releaseIncomingGarbage once per frame for both boards).

// Records what a still-ongoing chain on `self` would currently send,
// overwriting whatever an earlier step in the SAME chain recorded -- a x4
// chain should hand over one block sized by x4 alone once it concludes, not
// the sum of what x2/x3/x4 would each have sent on their own. See
// resolveChainEnd for where this actually gets sent.
pub fn queueChainGarbage(self: *s.Board, rows: u8, width: u8, anchor_col: u8) void {
    self.chain_pending_garbage = .{ .rows = rows, .width = width, .anchor_col = anchor_col };
}

// Queues a single, already-complete attack (a combo, or a chain's final
// sealed attack from resolveChainEnd below) into `target`'s own incoming
// queue, to actually land once `target` itself goes idle -- see
// releaseIncomingGarbage. Silently dropped if the queue is somehow already
// full (as generous as it is, that would take many simultaneous attacks
// piling up while target's board stays busy the whole time) -- missing one
// attack under such an extreme pile-up is far less disruptive than crashing
// or blocking every other attack behind it.
pub fn queueComboGarbage(target: *s.Board, rows: u8, width: u8, anchor_col: u8) void {
    for (&target.incoming_garbage) |*slot| {
        if (slot.* == null) {
            slot.* = .{ .rows = rows, .width = width, .anchor_col = anchor_col };
            return;
        }
    }
}

// Called once per frame per board (see main.zig) -- seals and hands off
// `self`'s currently-pending chain garbage (if any) to `opponent` the
// instant `self` goes idle, i.e. its chain has genuinely concluded (mirrors
// the chain-reset check this replaces: chain only resets once the board is
// fully idle, so a chain still cascading through further steps never gets
// cut short here). Rule 1 (garbage never falls mid-match/chain) is enforced
// on the *receiving* side instead, by releaseIncomingGarbage below -- sealing
// it here only decides the final size and hands it off, it doesn't spawn
// anything on `opponent` directly.
pub fn resolveChainEnd(self: *s.Board, opponent: *s.Board) void {
    if (self.boardBusy()) return;
    if (self.chain_pending_garbage) |p| {
        queueComboGarbage(opponent, p.rows, p.width, p.anchor_col);
        self.chain_pending_garbage = null;
    }
    self.chain = 0;
}

// Called once per frame per board (see main.zig) -- drains `self`'s own
// incoming queue into the board via spawnGarbage, but only once `self` is
// idle: rule 1 (garbage never falls mid-match/chain), enforced from the
// receiving side so a big attack landing while the recipient is still deep
// in their own cascade never interrupts it.
pub fn releaseIncomingGarbage(self: *s.Board) void {
    if (self.boardBusy()) return;
    for (&self.incoming_garbage) |*slot| {
        if (slot.*) |p| {
            // Stays queued (retried next frame) if the spawn buffer doesn't
            // have room for the whole piece yet -- see spawnGarbage's
            // all-or-nothing placement.
            if (spawnGarbage(self, p.rows, p.width, p.anchor_col)) slot.* = null;
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
// column like a real block -- see Cell.is_garbage -- so a piece touching
// down anywhere in the group stops the whole group at once. Connectivity is
// recomputed fresh every frame (rather than tracked via a persisted group
// id) so it stays correct as pieces pop away via propagation or a
// newly-landed clump merges with a neighboring one.
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

            // Already falling: advance the shared fall_off in lockstep --
            // every member is guaranteed to already agree on it, since the
            // whole body only ever moves together.
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
