// Simulation: swaps, pops, landings, gravity, and matching -- the core
// gameplay rules. This is the module most worth unit testing, since it's
// where score/chain correctness actually lives.

const std = @import("std");
const c = @import("constants.zig");
const s = @import("state.zig");
const audio = @import("audio.zig");
const garbage = @import("sim_garbage.zig");

pub fn swappable(state: s.CellState) bool {
    return state == .empty or state == .normal;
}

pub fn trySwap() void {
    const a = s.cellAt(s.cursor_row, s.cursor_col);
    const b = s.cellAt(s.cursor_row, s.cursor_col + 1);
    if (!swappable(a.state) or !swappable(b.state)) return;
    if (a.is_garbage or b.is_garbage) return; // inert -- see Cell.is_garbage
    if (a.state == .empty and b.state == .empty) return;

    const a_orig = a.*;
    const b_orig = b.*;
    a.* = b_orig;
    b.* = a_orig;

    a.state = if (b_orig.state == .empty) .empty else .swapping;
    b.state = if (a_orig.state == .empty) .empty else .swapping;

    if (a.state == .swapping) {
        a.timer = c.SWAP_FRAMES;
        a.swap_dir = 1; // slides in from the right
    }
    if (b.state == .swapping) {
        b.timer = c.SWAP_FRAMES;
        b.swap_dir = -1; // slides in from the left
    }
    // No chain reset here: chain only resets once the board is fully idle
    // (see the boardBusy() check in main.update()). Resetting it on every
    // swap would kill "skill chains" -- setting up another match while a
    // previous one is still falling/popping should extend the same chain,
    // not start a fresh one, as long as the board never actually went idle
    // in between.
}

pub fn simulate() void {
    s.tickMatchPopups();

    var settled = false;
    // Cells that completed a .swapping/.landing -> .normal transition this
    // frame. Passed to checkMatches so it only reconsiders *those* cells'
    // chainable status (see the cleanup there) -- a block marked chainable
    // below but still waiting its turn to actually start falling (see the
    // "mark the stack above" step) must not have its flag wiped out by some
    // unrelated settle event elsewhere on the board in the meantime.
    var just_settled: [c.ROWS][c.COLS]bool = std.mem.zeroes([c.ROWS][c.COLS]bool);
    // Cells that finished popping (cleared to empty) this frame.
    var just_cleared: [c.ROWS][c.COLS]bool = std.mem.zeroes([c.ROWS][c.COLS]bool);

    // Progress swap / pop / landing timers.
    for (0..c.ROWS) |lr| {
        for (0..c.COLS) |col| {
            const cell = s.cellAt(@intCast(lr), @intCast(col));
            switch (cell.state) {
                .swapping => {
                    cell.timer -= 1;
                    if (cell.timer <= 0) {
                        cell.state = .normal;
                        cell.swap_dir = 0;
                        settled = true;
                        just_settled[lr][col] = true;
                    }
                },
                .popping => {
                    cell.timer -= 1;
                    if (cell.timer == 0) {
                        audio.playPopTick();
                    }
                    cell.pop_group_end -= 1;
                    if (cell.pop_group_end <= 0) {
                        if (cell.is_garbage) {
                            // Garbage doesn't disappear -- it cracks open
                            // into a fresh, chainable block, in place, once
                            // the *whole* connected pop event (which may
                            // span several garbage cells and/or real matched
                            // cells -- see the propagation pass in
                            // checkMatches) finishes together. Its color was
                            // already picked back when the pop started (see
                            // checkMatches), so the player has been able to
                            // see it -- and plan around it -- for the whole
                            // pop, not just this final instant.
                            //
                            // Deliberately NOT marked just_settled/settled:
                            // checkMatches' "spend chainable on an unmatched
                            // settle" cleanup (for cells that inherited
                            // chainable from an earlier pop and turned out to
                            // be a dead end) would otherwise immediately wipe
                            // the chainable flag this exact reveal just
                            // granted, if a checkMatches call happened to run
                            // this same frame for an unrelated reason -- that
                            // cleanup can't distinguish "freshly granted" from
                            // "inherited and now proven dead". It'll get
                            // checked for matches the normal way once it
                            // actually falls/lands (or something else
                            // triggers a check) instead.
                            cell.state = .normal;
                            cell.is_garbage = false;
                            cell.chainable = true;
                            cell.timer = 0;
                            cell.pop_group_end = 0;
                        } else {
                            cell.* = s.Cell{};
                            just_cleared[lr][col] = true;
                        }
                    }
                },
                .landing => {
                    cell.timer -= 1;
                    if (cell.timer <= 0) {
                        cell.state = .normal;
                        settled = true;
                        just_settled[lr][col] = true;
                    }
                },
                else => {},
            }
        }
    }

    // Mark the stack of settled blocks directly above each just-cleared pop
    // as chainable, right at the moment the pop finishes -- not by tracking
    // the flag through gravity as things fall, which only invites confusion
    // from intermediate empty gaps. A later match involving one of these
    // blocks (however many frames it takes gravity to actually get to them)
    // is recognized as a genuine continuation of this break.
    for (0..c.COLS) |ci| {
        const col: u8 = @intCast(ci);
        var top_cleared: ?u8 = null;
        for (0..c.ROWS) |lr| {
            if (just_cleared[lr][col]) {
                top_cleared = @intCast(lr);
                break;
            }
        }
        const tc = top_cleared orelse continue;
        if (tc == 0) continue;
        var r: u8 = tc - 1;
        while (true) {
            const cell = s.cellAt(r, col);
            // Garbage blocks this marking pass like any other non-.normal
            // obstacle: it's inert and never inherits chainable through this
            // mechanism (only a revealed block does, explicitly, when it
            // pops -- see the .popping branch above), so it -- and anything
            // further above it -- is left untouched.
            if (cell.state != .normal or cell.is_garbage) break;
            cell.chainable = true;
            if (r == 0) break;
            r -= 1;
        }
    }

    // Gravity: scan bottom-to-top per column so falls cascade within a
    // frame. Garbage is excluded here (`!above.is_garbage` / `!cur.is_garbage`)
    // -- it falls and lands as one rigid connected body, not independently
    // per column, so it's handled separately by updateGarbageGravity below.
    for (0..c.COLS) |ci| {
        const col: u8 = @intCast(ci);
        var r: u8 = c.ROWS - 1;
        while (r >= 1) : (r -= 1) {
            const below = s.cellAt(r, col);
            const above = s.cellAt(r - 1, col);
            if (below.state == .empty and above.state == .normal and !above.is_garbage) {
                below.* = above.*;
                below.state = .falling;
                below.fall_off = c.TILE;
                above.* = s.Cell{};
            }

            const cur = s.cellAt(r, col);
            if (cur.state == .falling and !cur.is_garbage) {
                cur.fall_off -= c.FALL_SPEED;
                if (cur.fall_off <= 0) {
                    cur.fall_off = 0;
                    if (r < c.ROWS - 1 and s.cellAt(r + 1, col).state == .empty) {
                        const next = s.cellAt(r + 1, col);
                        next.* = cur.*;
                        next.fall_off = c.TILE;
                        cur.* = s.Cell{};
                    } else {
                        // Match-checking happens once the landing bounce
                        // finishes and the cell becomes .normal again (see
                        // the .landing timer branch above) since matches are
                        // only detected among settled, non-animating cells.
                        cur.state = .landing;
                        cur.timer = c.LAND_FRAMES;
                    }
                }
            }
            if (r == 0) break;
        }
    }

    garbage.updateGarbageGravity();

    if (settled) {
        _ = checkMatches(just_settled);
    }
}

pub fn checkMatches(just_settled: [c.ROWS][c.COLS]bool) bool {
    var settled_color: [c.ROWS][c.COLS]i16 = undefined;
    var settled_chainable: [c.ROWS][c.COLS]bool = undefined;
    for (0..c.ROWS) |lr| {
        for (0..c.COLS) |col| {
            const cell = s.cellAt(@intCast(lr), @intCast(col));
            // Garbage is colorless: it never seeds or joins a color run on
            // its own (only via the propagation pass below), so it's
            // excluded here exactly like an empty/animating cell would be.
            settled_color[lr][col] = if (cell.state == .normal and !cell.is_garbage) @as(i16, cell.color) else -1;
            settled_chainable[lr][col] = cell.state == .normal and cell.chainable;
        }
    }

    var matched: [c.ROWS][c.COLS]bool = std.mem.zeroes([c.ROWS][c.COLS]bool);
    var any = false;

    for (0..c.ROWS) |lr| {
        var col: usize = 0;
        while (col < c.COLS) {
            const col_ = settled_color[lr][col];
            if (col_ < 0) {
                col += 1;
                continue;
            }
            var run_len: usize = 1;
            while (col + run_len < c.COLS and settled_color[lr][col + run_len] == col_) run_len += 1;
            if (run_len >= 3) {
                for (0..run_len) |k| matched[lr][col + k] = true;
                any = true;
            }
            col += run_len;
        }
    }

    for (0..c.COLS) |col| {
        var r: usize = 0;
        while (r < c.ROWS) {
            const col_ = settled_color[r][col];
            if (col_ < 0) {
                r += 1;
                continue;
            }
            var run_len: usize = 1;
            while (r + run_len < c.ROWS and settled_color[r + run_len][col] == col_) run_len += 1;
            if (run_len >= 3) {
                for (0..run_len) |k| matched[r + k][col] = true;
                any = true;
            }
            r += run_len;
        }
    }

    if (!any) {
        // Cells that just settled (this frame) without matching have spent
        // their chain status -- a later, unrelated match involving them
        // shouldn't be credited as a chain continuation. Cells marked
        // chainable earlier but still waiting their own turn to fall are
        // untouched (see just_settled in simulate).
        for (0..c.ROWS) |lr| {
            for (0..c.COLS) |col| {
                if (just_settled[lr][col] and settled_chainable[lr][col]) {
                    s.cellAt(@intCast(lr), @intCast(col)).chainable = false;
                }
            }
        }
        return false;
    }

    // Garbage has no color of its own, so it never seeds a match -- but a
    // pop propagates into any garbage cell orthogonally touching a matched
    // cell, and from there into further garbage cells touching *that* one,
    // and so on, so a whole connected clump of garbage goes together. A
    // fixed-point sweep, since propagation can chain through several
    // garbage cells in a row within the same event.
    var propagated = true;
    while (propagated) {
        propagated = false;
        for (0..c.ROWS) |lr| {
            for (0..c.COLS) |col| {
                if (matched[lr][col]) continue;
                const cell = s.cellAt(@intCast(lr), @intCast(col));
                if (cell.state != .normal or !cell.is_garbage) continue;
                const touches_matched =
                    (lr > 0 and matched[lr - 1][col]) or
                    (lr + 1 < c.ROWS and matched[lr + 1][col]) or
                    (col > 0 and matched[lr][col - 1]) or
                    (col + 1 < c.COLS and matched[lr][col + 1]);
                if (touches_matched) {
                    matched[lr][col] = true;
                    propagated = true;
                }
            }
        }
    }

    // Matched blocks pop one after another rather than all at once (see
    // POP_STAGGER_FRAMES), but should all *disappear* together once their own
    // cascade finishes, so gravity affects a whole match at once rather than
    // reacting to each gap as it opens (see pop_group_end on Cell). Two
    // matches found in the same call can be unrelated (e.g. opposite corners
    // of the board), so they're grouped by 4-connectivity flood fill and
    // staggered/cleared independently rather than all sharing one timer.
    var visited: [c.ROWS][c.COLS]bool = std.mem.zeroes([c.ROWS][c.COLS]bool);
    var stack: [c.ROWS * c.COLS][2]u8 = undefined;
    var members: [c.ROWS * c.COLS][2]u8 = undefined;

    for (0..c.ROWS) |lr0| {
        for (0..c.COLS) |c0| {
            if (!matched[lr0][c0] or visited[lr0][c0]) continue;

            var stack_len: usize = 0;
            var member_count: usize = 0;
            stack[stack_len] = .{ @intCast(lr0), @intCast(c0) };
            stack_len += 1;
            visited[lr0][c0] = true;

            while (stack_len > 0) {
                stack_len -= 1;
                const pos = stack[stack_len];
                members[member_count] = pos;
                member_count += 1;
                const r = pos[0];
                const col = pos[1];
                if (r > 0 and matched[r - 1][col] and !visited[r - 1][col]) {
                    visited[r - 1][col] = true;
                    stack[stack_len] = .{ r - 1, col };
                    stack_len += 1;
                }
                if (r + 1 < c.ROWS and matched[r + 1][col] and !visited[r + 1][col]) {
                    visited[r + 1][col] = true;
                    stack[stack_len] = .{ r + 1, col };
                    stack_len += 1;
                }
                if (col > 0 and matched[r][col - 1] and !visited[r][col - 1]) {
                    visited[r][col - 1] = true;
                    stack[stack_len] = .{ r, col - 1 };
                    stack_len += 1;
                }
                if (col + 1 < c.COLS and matched[r][col + 1] and !visited[r][col + 1]) {
                    visited[r][col + 1] = true;
                    stack[stack_len] = .{ r, col + 1 };
                    stack_len += 1;
                }
            }

            // Flood-fill visits cells in an arbitrary (DFS) order; sort into
            // row-major order first so the stagger sweeps predictably
            // top-to-bottom, left-to-right instead of looking scattered.
            var oi: usize = 1;
            while (oi < member_count) : (oi += 1) {
                const key = members[oi];
                var oj: usize = oi;
                while (oj > 0 and (members[oj - 1][0] > key[0] or
                    (members[oj - 1][0] == key[0] and members[oj - 1][1] > key[1])))
                {
                    members[oj] = members[oj - 1];
                    oj -= 1;
                }
                members[oj] = key;
            }

            // A connected group is a genuine chain continuation if any of its
            // cells fell into place from an earlier break (chainable); a
            // match made purely of ordinary settled blocks isn't, even if
            // some unrelated cascade elsewhere is still busy right now. The
            // very first match of a fresh chain sequence (chain still 0)
            // always counts, since there's nothing to "continue" yet.
            var group_chainable = false;
            var min_row: u8 = c.ROWS - 1;
            var max_row: u8 = 0;
            var min_col: u8 = c.COLS - 1;
            var max_col: u8 = 0;
            // Garbage never counts toward a combo -- only real matched
            // color cells do, even though propagated garbage shares this
            // same group and pops alongside them (see below).
            var real_count: usize = 0;
            for (0..member_count) |i| {
                const pos = members[i];
                if (settled_chainable[pos[0]][pos[1]]) group_chainable = true;
                if (pos[0] < min_row) min_row = pos[0];
                if (pos[0] > max_row) max_row = pos[0];
                if (pos[1] < min_col) min_col = pos[1];
                if (pos[1] > max_col) max_col = pos[1];
                if (!s.cellAt(pos[0], pos[1]).is_garbage) real_count += 1;
            }
            var multiplier: u8 = 1;
            if (s.chain == 0 or group_chainable) {
                s.chain += 1;
                multiplier = s.chain;
            }
            // Two distinct, independently-triggered flourishes share the same
            // popup badge (see state.MatchPopup), but mean different things:
            // a *chain* is a genuine continuation (multiplier > 1 -- this
            // match was only possible because of an earlier break); a
            // *combo* is simply a single match bigger than the minimum 3
            // real (non-garbage) blocks, independent of chain state. A match
            // can be both -- the chain label takes priority in that case,
            // since it's the rarer feat. The very first match of a fresh
            // chain sequence at its minimum size (multiplier == 1,
            // real_count == 3) is just an ordinary pop, nothing to
            // celebrate.
            const is_chain = multiplier > 1;
            const is_combo = real_count > 3;

            const group_end: i16 = c.POP_FRAMES + @as(i16, @intCast(member_count - 1)) * c.POP_STAGGER_FRAMES;
            for (0..member_count) |i| {
                const pos = members[i];
                const cell = s.cellAt(pos[0], pos[1]);
                cell.state = .popping;
                cell.timer = c.POP_FRAMES + @as(i16, @intCast(i)) * c.POP_STAGGER_FRAMES;
                cell.pop_group_end = group_end;
                if (cell.is_garbage) {
                    // Reveal the color now, at the start of the pop, not at
                    // the end -- see render.drawPoppingCell, which renders
                    // any popping cell (garbage-sourced or not) using
                    // whatever color it already holds. Letting the player
                    // see the color for the whole pop (not just the instant
                    // it resolves) is the point: it lets them premeditate a
                    // matching lineup underneath before the reveal actually
                    // lands.
                    cell.color = @intCast(s.randRange(c.NUM_COLORS));
                }
            }
            if (is_chain or is_combo) {
                var label_buf: [16]u8 = undefined;
                const label = if (is_chain)
                    std.fmt.bufPrint(&label_buf, "x{d}", .{multiplier}) catch "x?"
                else
                    std.fmt.bufPrint(&label_buf, "{d}", .{real_count}) catch "?";
                const match_w = (@as(i32, max_col) - @as(i32, min_col) + 1) * c.TILE;
                const cx = c.BOARD_X + @as(i32, min_col) * c.TILE + @divTrunc(match_w, 2);
                // Spawn at the center of the match's topmost block (not the
                // whole bounding box's center), so it reads as belonging to
                // the match right where it's most visible. It then eases up
                // just a couple pixels (a small "catch the eye" hop, not a
                // trip anywhere) and waits there until this match's own pop
                // animation actually finishes (see group_end above), at
                // which point it flies off to the score -- see
                // render.drawMatchPopups.
                const cy = c.BOARD_Y + @as(i32, min_row) * c.TILE - @as(i32, @intCast(s.scroll_px)) + @divTrunc(c.TILE, 2);
                const edge_y = cy - s.MATCH_POPUP_RISE_PX;
                s.spawnMatchPopup(label, cx, cy, edge_y, group_end);

                // Self-inflicted garbage (v1: always the player's own doing,
                // never an opponent's): a big combo or chain drops garbage
                // onto this same board. Chain takes priority over combo
                // sizing when a match is both, mirroring the badge label
                // precedence just above -- a match doesn't spawn both kinds
                // at once.
                if (is_chain) {
                    // x2 -> 1 row, x3 -> 2 rows, ... (extrapolated linearly;
                    // only x2/x3 were specified) -- multiplier > 1 here, so
                    // this never underflows.
                    const garbage_rows: u8 = multiplier - 1;
                    garbage.spawnGarbage(garbage_rows, c.COLS, 0);
                } else if (real_count >= 6) {
                    garbage.spawnGarbage(1, c.COLS, 0);
                } else if (real_count == 5) {
                    garbage.spawnGarbage(1, 4, min_col);
                } else { // real_count == 4, the only case left under is_combo
                    garbage.spawnGarbage(1, 3, min_col);
                }
            }
            s.score += @as(u32, @intCast(member_count)) * 10 * multiplier;
            audio.playPopSound(multiplier);
        }
    }

    // Any cell that just settled (this frame) with chainable set but wasn't
    // part of a match (e.g. it fell but landed somewhere that didn't
    // complete a match) has spent its chain status now that it's back to
    // being an ordinary block. Cells marked chainable but still waiting
    // their own turn to fall are untouched.
    for (0..c.ROWS) |lr| {
        for (0..c.COLS) |col| {
            if (just_settled[lr][col] and settled_chainable[lr][col] and !matched[lr][col]) {
                s.cellAt(@intCast(lr), @intCast(col)).chainable = false;
            }
        }
    }

    return true;
}

