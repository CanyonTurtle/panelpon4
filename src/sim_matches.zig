// Match detection, chain/combo scoring, and garbage spawning -- split out
// from sim.zig (where it's re-exported as `checkMatches`, so call sites and
// tests are unaffected) to keep that file under the project's
// ~500-line-per-file guideline. Stays tightly coupled to sim.simulate (the
// only caller) rather than being a fully standalone module.

const std = @import("std");
const c = @import("constants.zig");
const s = @import("state.zig");
const audio = @import("audio.zig");
const garbage = @import("sim_garbage.zig");

// `.landing` is the short cosmetic bounce right after a cell's own gravity
// stops it -- its color/position/is_garbage are already final, only the
// bounce's own timer is still counting down before it flips to `.normal`.
// Treating it as match-eligible here (not just `.normal`) is what lets a
// real block and an adjacent garbage cell that land one frame apart (real-
// block gravity and garbage's rigid-body gravity are independent systems,
// so even a "simultaneous" landing rarely finishes on the exact same tick)
// still resolve as one match instead of the earlier one popping alone while
// the later one is still bouncing, and by the time *it* finishes, the match
// that would have pulled it in has already cleared. Whichever cell(s) get
// pulled into a match this way simply have their bounce cut short and go
// straight into the pop/recycle animation instead -- see checkMatches below,
// which unconditionally overwrites `state`/`timer` for every matched member
// regardless of what it was doing before.
fn matchEligible(state: s.CellState) bool {
    return state == .normal or state == .landing;
}

fn isActivePop(state: s.CellState) bool {
    return state == .popping or state == .recycling;
}

fn colorAt(grid: *const [c.ROWS][c.COLS]i16, row: i32, col: i32) i16 {
    if (row < 0 or row >= c.ROWS or col < 0 or col >= c.COLS) return -1;
    return grid[@intCast(row)][@intCast(col)];
}

// True if placing `chosen` at (row, col) would complete a run of 3+ with
// whatever colors are already known at its neighbors -- checked both ways
// (two-before, straddling, two-after) in each axis so it catches a run
// forming on either side, not just behind a fixed scan direction. A neighbor
// still undecided (an as-yet-unprocessed recycling cell, or plain garbage/
// empty) reads as -1 here and never blocks anything -- see the caller for
// why processing in a fixed scan order still makes this fully reliable.
fn wouldCompleteRun(grid: *const [c.ROWS][c.COLS]i16, row: u8, col: u8, chosen: i16) bool {
    const r: i32 = row;
    const cl: i32 = col;
    if (colorAt(grid, r, cl - 1) == chosen and colorAt(grid, r, cl - 2) == chosen) return true;
    if (colorAt(grid, r, cl - 1) == chosen and colorAt(grid, r, cl + 1) == chosen) return true;
    if (colorAt(grid, r, cl + 1) == chosen and colorAt(grid, r, cl + 2) == chosen) return true;
    if (colorAt(grid, r - 1, cl) == chosen and colorAt(grid, r - 2, cl) == chosen) return true;
    if (colorAt(grid, r - 1, cl) == chosen and colorAt(grid, r + 1, cl) == chosen) return true;
    if (colorAt(grid, r + 1, cl) == chosen and colorAt(grid, r + 2, cl) == chosen) return true;
    return false;
}

pub fn checkMatches(self: *s.Board, opponent: *s.Board, just_settled: [c.ROWS][c.COLS]bool) bool {
    var settled_color: [c.ROWS][c.COLS]i16 = undefined;
    var settled_chainable: [c.ROWS][c.COLS]bool = undefined;
    for (0..c.ROWS) |lr| {
        for (0..c.COLS) |col| {
            const cell = self.cellAt(@intCast(lr), @intCast(col));
            // Garbage is colorless: it never seeds or joins a color run on
            // its own (only via the propagation pass below), so it's
            // excluded here exactly like an empty/animating cell would be.
            settled_color[lr][col] = if (matchEligible(cell.state) and !cell.is_garbage) @as(i16, cell.color) else -1;
            settled_chainable[lr][col] = matchEligible(cell.state) and cell.chainable;
        }
    }

    // Sweeps a garbage cell that only *just* became match-eligible (it
    // finished its own landing bounce, or just settled, this frame) into an
    // ALREADY-ACTIVE pop/recycle group from an earlier call this same
    // cascade -- distinct from the propagation pass further below, which
    // only pulls a garbage cell into a match *newly* detected THIS call.
    // Real-block gravity and garbage's own rigid-body gravity are
    // independent systems, so even two pieces that "land together" from the
    // player's perspective rarely finish on the exact same frame: without
    // this, whichever one settles first pops alone, and by the time the
    // other one finishes falling, the match that should have caught it has
    // already moved on to `.popping`/`.recycling` -- no longer color-
    // matchable, so ordinary propagation (which only looks at *this* call's
    // freshly-matched cells) can never reach it either. A late joiner simply
    // inherits whatever's left of the group it touches (same shared
    // pop_group_end, same current timer/pre_pop_timer) rather than tacking
    // its own fresh preamble onto an already-progressed countdown, so it
    // resolves in lockstep with the rest. A fixed-point sweep, same idea as
    // the propagation pass below, since a whole newly-landed clump can chain
    // into the active group one cell at a time.
    var late_joined = true;
    while (late_joined) {
        late_joined = false;
        for (0..c.ROWS) |lr| {
            for (0..c.COLS) |col| {
                const cell = self.cellAt(@intCast(lr), @intCast(col));
                if (!cell.is_garbage or !matchEligible(cell.state)) continue;

                var anchor: ?*s.Cell = null;
                if (lr > 0) {
                    const n = self.cellAt(@intCast(lr - 1), @intCast(col));
                    if (isActivePop(n.state)) anchor = n;
                }
                if (anchor == null and lr + 1 < c.ROWS) {
                    const n = self.cellAt(@intCast(lr + 1), @intCast(col));
                    if (isActivePop(n.state)) anchor = n;
                }
                if (anchor == null and col > 0) {
                    const n = self.cellAt(@intCast(lr), @intCast(col - 1));
                    if (isActivePop(n.state)) anchor = n;
                }
                if (anchor == null and col + 1 < c.COLS) {
                    const n = self.cellAt(@intCast(lr), @intCast(col + 1));
                    if (isActivePop(n.state)) anchor = n;
                }
                const a = anchor orelse continue;

                cell.pop_group_end = a.pop_group_end;
                cell.timer = a.timer;
                cell.pre_pop_timer = a.pre_pop_timer;
                cell.state = .recycling;
                // Same per-piece bottom-row rule as an ordinary recycle
                // event (see the main pass below) -- keyed off this cell's
                // own garbage_group, independent of whichever group it's
                // visually joining.
                const below_same_piece = lr + 1 < c.ROWS and
                    self.cellAt(@intCast(lr + 1), @intCast(col)).is_garbage and
                    self.cellAt(@intCast(lr + 1), @intCast(col)).garbage_group == cell.garbage_group;
                cell.garbage_reveals = !below_same_piece;
                if (cell.garbage_reveals) {
                    var chosen: i16 = 0;
                    var tries: u8 = 0;
                    while (true) {
                        chosen = @intCast(self.randRange(c.NUM_COLORS));
                        tries += 1;
                        if (!wouldCompleteRun(&settled_color, @intCast(lr), @intCast(col), chosen) or tries > 20) break;
                    }
                    cell.color = @intCast(chosen);
                    settled_color[lr][col] = chosen;
                }
                late_joined = true;
            }
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
                    self.cellAt(@intCast(lr), @intCast(col)).chainable = false;
                }
            }
        }
        return false;
    }

    // Garbage has no color of its own, so it never seeds a match -- but a
    // pop propagates into any garbage cell orthogonally touching a matched
    // cell, and from there into further garbage cells touching *that* one,
    // and so on -- a whole physically-connected clump goes together, same as
    // it always has, including a *different* garbage piece it merely happens
    // to be resting against (see Cell.garbage_group and garbage_reveals
    // below for the part that genuinely does need to stay per-piece: how
    // much of each individual piece actually converts, once everything
    // touching has been pulled in here). A fixed-point sweep, since
    // propagation can chain through several garbage cells in a row within
    // the same event.
    var propagated = true;
    while (propagated) {
        propagated = false;
        for (0..c.ROWS) |lr| {
            for (0..c.COLS) |col| {
                if (matched[lr][col]) continue;
                const cell = self.cellAt(@intCast(lr), @intCast(col));
                if (!matchEligible(cell.state) or !cell.is_garbage) continue;
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

            // Flood-fill visits cells in an arbitrary (DFS) order; sort so
            // the stagger sweeps predictably bottom-right to top-left, rows
            // first, instead of looking scattered -- this is what a garbage
            // clump recycles in too (see the garbage_reveals pass below),
            // so the row about to become playable is always the one nearest
            // the player's own active area, read first rather than last.
            var oi: usize = 1;
            while (oi < member_count) : (oi += 1) {
                const key = members[oi];
                var oj: usize = oi;
                while (oj > 0 and (members[oj - 1][0] < key[0] or
                    (members[oj - 1][0] == key[0] and members[oj - 1][1] < key[1])))
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
                if (!self.cellAt(pos[0], pos[1]).is_garbage) real_count += 1;
            }
            var multiplier: u8 = 1;
            if (self.chain == 0 or group_chainable) {
                self.chain += 1;
                multiplier = self.chain;
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

            // A combo (unlike a chain) has no ongoing Board state of its own
            // to read back later -- it's a single instantaneous event -- so
            // give the panel something to display for a little while after
            // the fact (see render.drawPanel), the same way `chain` itself
            // just naturally persists on Board for chain's own display.
            if (is_combo) {
                self.combo_display = @intCast(real_count);
                self.combo_display_timer = c.COMBO_DISPLAY_FRAMES;
            }

            // The whole group's resolution timer includes the shared pre-pop
            // blink+pause preamble (PRE_POP_TOTAL_FRAMES) on top of the
            // ordinary staggered pop duration, so the group doesn't resolve
            // before the preamble even finishes playing.
            const group_end: i16 = c.PRE_POP_TOTAL_FRAMES + c.POP_FRAMES + @as(i16, @intCast(member_count - 1)) * c.POP_STAGGER_FRAMES;
            for (0..member_count) |i| {
                const pos = members[i];
                const cell = self.cellAt(pos[0], pos[1]);
                // A real matched cell pops (.popping); a garbage cell pulled
                // in via propagation recycles (.recycling) instead -- see
                // CellState and render.drawRecyclingCell. Both share the same
                // per-member stagger (timer) and the same whole-group
                // resolution timer (pop_group_end).
                cell.state = if (cell.is_garbage) .recycling else .popping;
                cell.timer = c.POP_FRAMES + @as(i16, @intCast(i)) * c.POP_STAGGER_FRAMES;
                // Identical for every member (no i offset) -- see
                // Cell.pre_pop_timer -- so the whole group blinks/pauses in
                // lockstep; `timer` above doesn't start counting down until
                // this reaches 0 (see sim.simulate).
                cell.pre_pop_timer = c.PRE_POP_TOTAL_FRAMES;
                cell.pop_group_end = group_end;
                if (cell.is_garbage) {
                    // A piece taller than one row only ever converts its
                    // bottom-most (per column) row per event -- decided per
                    // PIECE (Cell.garbage_group), not by whatever this
                    // event's overall touching shape looks like: if there's
                    // another cell of THIS SAME piece directly below (on the
                    // board right now, not merely "also matched"), that
                    // one's closer to the bottom, so this cell just flashes
                    // along with the rest of its piece and reverts to plain
                    // garbage once the group resolves (see sim.simulate)
                    // rather than actually converting. A different piece
                    // resting below (or on top) doesn't count, even if it's
                    // being pulled into this same event for its own reasons.
                    const below_same_piece = pos[0] + 1 < c.ROWS and
                        self.cellAt(pos[0] + 1, pos[1]).is_garbage and
                        self.cellAt(pos[0] + 1, pos[1]).garbage_group == cell.garbage_group;
                    cell.garbage_reveals = !below_same_piece;
                }
            }

            // Pick reveal colors now, at the moment the whole recycle event
            // is detected, not once each cell's own turn arrives or the
            // group finishes -- it doesn't matter when it's *picked*, only
            // when it's *shown* (see render.drawRecyclingCell, which
            // withholds it from rendering until this cell's own staggered
            // turn in the group comes up). Only cells that will actually
            // convert (garbage_reveals) need one at all -- a flash-only cell
            // never shows a color. Scanned top-to-bottom, left-to-right
            // here regardless of the group's own bottom-right-to-top-left
            // stagger order above (unrelated concerns): picking each color
            // to avoid completing a run of 3 with whatever's already
            // decided to its left/above (already-settled real blocks, or an
            // earlier cell in this same pass) is only reliable if every
            // decision is made in a fixed, consistent scan order -- exactly
            // mirroring board.pickRowColors' own reasoning for a
            // freshly-generated row.
            for (0..c.ROWS) |lr| {
                for (0..c.COLS) |col| {
                    if (!matched[lr][col]) continue;
                    const cell = self.cellAt(@intCast(lr), @intCast(col));
                    if (!cell.is_garbage or !cell.garbage_reveals) continue;
                    var chosen: i16 = 0;
                    var tries: u8 = 0;
                    while (true) {
                        chosen = @intCast(self.randRange(c.NUM_COLORS));
                        tries += 1;
                        if (!wouldCompleteRun(&settled_color, @intCast(lr), @intCast(col), chosen) or tries > 20) break;
                    }
                    cell.color = @intCast(chosen);
                    // So a later cell in this same pass (or the vertical
                    // check on a cell below it) sees this as already
                    // decided, the same way settled_color already reflects
                    // pre-existing real blocks.
                    settled_color[lr][col] = chosen;
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
                //
                // Always computed at the player's own board position, even
                // when `self` is the CPU -- the CPU's popups are never
                // rendered (its board is drawn at a simplified micro scale
                // with no room for a badge), so this is harmless dead data
                // in that case rather than something worth threading a
                // second coordinate system through checkMatches for.
                // min_row is an absolute logical row -- SPAWN_ROWS of those
                // are the offscreen garbage staging area above the ceiling
                // (see constants.SPAWN_ROWS), not part of the visible board's
                // own Y=0 origin, so it has to come out before converting to
                // screen space (mirrors render.drawBoard's identical offset).
                const cy = c.BOARD_Y + (@as(i32, min_row) - @as(i32, c.SPAWN_ROWS)) * c.TILE - @as(i32, @intCast(self.scroll_px)) + @divTrunc(c.TILE, 2);
                const edge_y = cy - s.MATCH_POPUP_RISE_PX;
                self.spawnMatchPopup(label, cx, cy, edge_y, group_end);

                // A big enough combo or chain queues garbage onto the
                // *opponent's* board -- never self-inflicted in vs-CPU play
                // -- rather than spawning it immediately (see
                // sim_garbage.zig's queueing lifecycle, driven once per
                // frame from main.zig): a still-ongoing chain on `self`
                // keeps overwriting its own pending attack here as it grows,
                // only handing the FINAL size over once the whole chain
                // concludes, while a combo's already-complete attack goes
                // straight into the opponent's own incoming queue to await
                // their board going idle. Chain takes priority over combo
                // sizing when a match is both, mirroring the badge label
                // precedence just above -- a match doesn't queue both kinds
                // at once.
                if (is_chain) {
                    // x2 -> 1 row, x3 -> 2 rows, ... (extrapolated linearly;
                    // only x2/x3 were specified) -- multiplier > 1 here, so
                    // this never underflows.
                    const garbage_rows: u8 = multiplier - 1;
                    garbage.queueChainGarbage(self, garbage_rows, c.COLS, 0);
                } else if (real_count >= 6) {
                    garbage.queueComboGarbage(opponent, 1, c.COLS, 0);
                } else if (real_count == 5) {
                    garbage.queueComboGarbage(opponent, 1, 4, min_col);
                } else { // real_count == 4, the only case left under is_combo
                    garbage.queueComboGarbage(opponent, 1, 3, min_col);
                }
            }
            self.score += @as(u32, @intCast(member_count)) * 10 * multiplier;
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
                self.cellAt(@intCast(lr), @intCast(col)).chainable = false;
            }
        }
    }

    return true;
}
