// The back half of sim_matches.checkMatches: once a call has settled on
// which cells are `matched` (seeded color runs plus anything garbage
// propagation pulled in), this groups them by 4-connectivity flood fill and
// resolves each connected group independently -- staggered pop/recycle
// timers, chain/combo scoring, the popup badge, and chain/combo garbage
// queueing. Split out of sim_matches.zig (checkMatches calls
// resolveMatchGroups as its last step) to keep that file under the
// project's ~500-line-per-file guideline; stays just as tightly coupled to
// checkMatches (the only caller) as sim_matches.zig itself is to
// sim.simulate.

const std = @import("std");
const c = @import("constants.zig");
const s = @import("state.zig");
const fx = @import("state_fx.zig");
const audio = @import("audio.zig");
const garbage = @import("sim_garbage.zig");
const matches = @import("sim_matches.zig");

// `settled_color` is read (to keep picking reveal colors consistent with
// wouldCompleteRun, same as the caller's own earlier passes) and further
// written to as each converting garbage cell's color is picked here;
// `settled_chainable` and `matched` are only ever read.
pub fn resolveMatchGroups(
    self: *s.Board,
    opponent: *s.Board,
    matched: *const [c.ROWS][c.COLS]bool,
    settled_color: *[c.ROWS][c.COLS]i16,
    settled_chainable: *const [c.ROWS][c.COLS]bool,
) void {
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
            // popup badge (see state_fx.MatchPopup), but mean different
            // things: a *chain* is a genuine continuation (multiplier > 1 --
            // this match was only possible because of an earlier break); a
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
            // Real matched cells vanish together once their *own* longest
            // stagger finishes -- not the mixed group's as a whole. They
            // still need a shared resolution moment among themselves (see
            // group_end's own doc comment: gravity should react to a whole
            // match clearing at once, not to each gap opening one at a
            // time), but a slower-finishing garbage clump pulled into the
            // same event has no business holding that moment hostage: real
            // cells are genuinely gone once their pop animation ends, and
            // the match's own space should free up for gravity/new blocks
            // right then, while any garbage that happens to still be mid-
            // recycle simply keeps sitting there inert, resolving on its own
            // schedule (see below), exactly as it always does on its own.
            var real_last_i: ?usize = null;
            for (0..member_count) |i| {
                if (!self.cellAt(members[i][0], members[i][1]).is_garbage) real_last_i = i;
            }
            const real_group_end: i16 = if (real_last_i) |ri|
                c.PRE_POP_TOTAL_FRAMES + c.POP_FRAMES + @as(i16, @intCast(ri)) * c.POP_STAGGER_FRAMES
            else
                group_end; // unreachable in practice: a group with no real members never formed from a color match
            for (0..member_count) |i| {
                const pos = members[i];
                const cell = self.cellAt(pos[0], pos[1]);
                // A real matched cell pops (.popping); a garbage cell pulled
                // in via propagation recycles (.recycling) instead -- see
                // CellState and render.drawRecyclingCell. Both share the same
                // per-member stagger (timer), but resolve (pop_group_end)
                // on their own separate schedules -- see real_group_end
                // above.
                cell.state = if (cell.is_garbage) .recycling else .popping;
                cell.timer = c.POP_FRAMES + @as(i16, @intCast(i)) * c.POP_STAGGER_FRAMES;
                // Identical for every member (no i offset) -- see
                // Cell.pre_pop_timer -- so the whole group blinks/pauses in
                // lockstep; `timer` above doesn't start counting down until
                // this reaches 0 (see sim.simulate).
                cell.pre_pop_timer = c.PRE_POP_TOTAL_FRAMES;
                cell.pop_group_end = if (cell.is_garbage) group_end else real_group_end;
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
                        if (!matches.wouldCompleteRun(settled_color, @intCast(lr), @intCast(col), chosen) or tries > 20) break;
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
                // Spawn at the center of the match's topmost block (not the
                // whole bounding box's center), so it reads as belonging to
                // the match right where it's most visible. It then eases up
                // just a couple pixels (a small "catch the eye" hop, not a
                // trip anywhere) and waits there until this match's own pop
                // animation actually finishes (see group_end above), at
                // which point it flies off to the score -- see
                // render.drawMatchPopups.
                //
                // The CPU's own board renders at a different scale/position
                // (render_cpu.zig's simplified micro board, see
                // constants.CPU_MICRO_TILE/CPU_BOARD_Y) than the player's
                // full-detail one (constants.BOARD_X/BOARD_Y/TILE), so which
                // coordinate system to use depends on which board actually
                // matched -- `self`/`&s.cpu` pointer identity is enough to
                // tell (the two Boards are process-wide singletons, see
                // state.player/state.cpu), no extra parameter needed.
                // min_row is an absolute logical row -- SPAWN_ROWS of those
                // are the offscreen garbage staging area above the ceiling
                // (see constants.SPAWN_ROWS), not part of the visible board's
                // own Y=0 origin, so it has to come out before converting to
                // screen space (mirrors render.drawBoard's identical offset).
                const is_cpu = self == &s.cpu;
                const tile: i32 = if (is_cpu) c.CPU_MICRO_TILE else c.TILE;
                const origin_x: i32 = if (is_cpu) c.PANEL_X else c.BOARD_X;
                const origin_y: i32 = if (is_cpu) c.CPU_BOARD_Y else c.BOARD_Y;
                const match_w = (@as(i32, max_col) - @as(i32, min_col) + 1) * tile;
                const cx = origin_x + @as(i32, min_col) * tile + @divTrunc(match_w, 2);
                // scroll_px is always counted in the player's own full-scale
                // TILE units (see Board.scroll_px), so it's rescaled to the
                // micro board's own tile size for the CPU case -- mirrors
                // render_cpu.drawMicroBoard's identical `micro_scroll` rescale.
                const scroll = if (is_cpu)
                    @divTrunc(@as(i32, @intCast(self.scroll_px)) * c.CPU_MICRO_TILE, c.TILE)
                else
                    @as(i32, @intCast(self.scroll_px));
                const cy = origin_y + (@as(i32, min_row) - @as(i32, c.SPAWN_ROWS)) * tile - scroll + @divTrunc(tile, 2);
                const edge_y = cy - fx.MATCH_POPUP_RISE_PX;
                fx.spawnMatchPopup(self, label, cx, cy, edge_y, group_end);

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
}
