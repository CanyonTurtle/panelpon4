// Back half of sim_matches.checkMatches: flood-fills `matched` cells into groups and resolves each (pop/recycle, chain/combo, popup, garbage queueing).
// Split out only for file-size; as tightly coupled to checkMatches (its only caller) as sim_matches.zig itself is to sim.simulate.

const std = @import("std");
const c = @import("constants.zig");
const s = @import("state.zig");
const fx = @import("state_fx.zig");
const audio = @import("audio.zig");
const garbage = @import("sim_garbage.zig");
const matches = @import("sim_matches.zig");
const board = @import("board.zig");

// `settled_color` is read by wouldCompleteRun and also written here as each converting garbage cell's color is picked;
// `settled_chainable` and `matched` are only ever read.
pub fn resolveMatchGroups(
    self: *s.Board,
    opponent: *s.Board,
    matched: *const [c.ROWS][c.COLS]bool,
    settled_color: *[c.ROWS][c.COLS]i16,
    settled_chainable: *const [c.ROWS][c.COLS]bool,
) void {
    // Two matches in the same call can be unrelated (opposite corners of the board), so they're grouped by 4-connectivity flood fill
    // and staggered/cleared independently, each group disappearing together once its own cascade finishes (see pop_group_end on Cell).
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

            // Flood-fill visits cells in arbitrary (DFS) order; sort bottom-right to top-left so the stagger sweeps predictably
            // instead of looking scattered -- the row nearest the player's active area resolves first, same order garbage recycles in.
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

            // A group is a genuine chain continuation if any member cell is chainable (fell from an earlier break); the first match
            // of a fresh chain sequence (chain still 0) always counts too, since there's nothing to "continue" yet.
            var group_chainable = false;
            var min_row: u8 = c.ROWS - 1;
            var max_row: u8 = 0;
            var min_col: u8 = c.COLS - 1;
            var max_col: u8 = 0;
            // Garbage never counts toward a combo -- only real matched color cells do, even though propagated garbage
            // shares this same group and pops alongside them (see below).
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
            // A *chain* (multiplier > 1) and a *combo* (more than the minimum 3 real blocks) share the same popup badge
            // (state_fx.MatchPopup) but are independent conditions; when a match is both, the rarer chain label wins.
            const is_chain = multiplier > 1;
            const is_combo = real_count > 3;

            // A combo has no ongoing Board state like `chain` does, so stash it here for the panel to display briefly (render.drawPanel).
            if (is_combo) {
                self.combo_display = @intCast(real_count);
                self.combo_display_timer = c.COMBO_DISPLAY_FRAMES;
            }

            // The group's resolution timer includes the shared pre-pop blink+pause preamble (PRE_POP_TOTAL_FRAMES) on top
            // of the ordinary staggered pop duration, so the group doesn't resolve before the preamble finishes playing.
            const group_end: i16 = c.PRE_POP_TOTAL_FRAMES + c.POP_FRAMES + @as(i16, @intCast(member_count - 1)) * c.POP_STAGGER_FRAMES;
            // Real matched cells vanish together once their own longest stagger finishes, not the mixed group's as a whole --
            // a slower-finishing garbage clump pulled into the same event shouldn't hold up freeing that space for gravity.
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
                // A real matched cell pops (.popping); a propagated garbage cell recycles (.recycling) instead -- see CellState.
                // Both share the same per-member stagger (timer) but resolve (pop_group_end) on separate schedules, see above.
                cell.state = if (cell.is_garbage) .recycling else .popping;
                cell.timer = c.POP_FRAMES + @as(i16, @intCast(i)) * c.POP_STAGGER_FRAMES;
                // Identical for every member (no i offset) so the whole group blinks/pauses in lockstep -- `timer` above
                // doesn't start counting down until this reaches 0 (see sim.simulate).
                cell.pre_pop_timer = c.PRE_POP_TOTAL_FRAMES;
                cell.pop_group_end = if (cell.is_garbage) group_end else real_group_end;
                if (cell.is_garbage) {
                    // Only a piece's (Cell.garbage_group) bottom-most row per column converts per event; a cell with
                    // another cell of the SAME piece directly below it just flashes and reverts to plain garbage instead.
                    const below_same_piece = pos[0] + 1 < c.ROWS and
                        self.cellAt(pos[0] + 1, pos[1]).is_garbage and
                        self.cellAt(pos[0] + 1, pos[1]).garbage_group == cell.garbage_group;
                    cell.garbage_reveals = !below_same_piece;
                }
            }

            // Reveal colors (garbage_reveals cells only) are picked now, not at display time -- render.drawRecyclingCell withholds
            // rendering until the cell's turn. Scanned in a fixed top-to-bottom/left-to-right order so each pick avoiding a run of 3 sees this pass's earlier picks, mirroring board.pickRowColors.
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
                    // So a later cell in this pass (or a vertical check below it) sees this as already decided, like
                    // settled_color already reflects pre-existing real blocks.
                    settled_color[lr][col] = chosen;
                }
            }
            if (is_chain or is_combo) {
                var label_buf: [16]u8 = undefined;
                const label = if (is_chain)
                    std.fmt.bufPrint(&label_buf, "x{d}", .{multiplier}) catch "x?"
                else
                    std.fmt.bufPrint(&label_buf, "{d}", .{real_count}) catch "?";
                // Spawns at the center of the match's topmost block (not the whole bounding box), easing up until group_end
                // (render.drawMatchPopups). Picks player vs CPU-micro-board coords via `self`/`&s.cpu` identity; min_row needs SPAWN_ROWS subtracted first, same as render.drawBoard.
                const is_cpu = self == &s.cpu;
                const tile: i32 = if (is_cpu) c.CPU_MICRO_TILE else c.TILE;
                const origin_x: i32 = if (is_cpu) c.PANEL_X else c.BOARD_X;
                const origin_y: i32 = if (is_cpu) c.CPU_BOARD_Y else c.BOARD_Y;
                const match_w = (@as(i32, max_col) - @as(i32, min_col) + 1) * tile;
                const cx = origin_x + @as(i32, min_col) * tile + @divTrunc(match_w, 2);
                // scroll_px is always in the player's full-scale TILE units (Board.scroll_px), so it's rescaled to the micro
                // tile size for the CPU case -- mirrors render_cpu.drawMicroBoard's `micro_scroll` rescale.
                const scroll = if (is_cpu)
                    @divTrunc(@as(i32, @intCast(self.scroll_px)) * c.CPU_MICRO_TILE, c.TILE)
                else
                    @as(i32, @intCast(self.scroll_px));
                const cy = origin_y + (@as(i32, min_row) - @as(i32, c.SPAWN_ROWS)) * tile - scroll + @divTrunc(tile, 2);
                const edge_y = cy - fx.MATCH_POPUP_RISE_PX;
                fx.spawnMatchPopup(self, label, cx, cy, edge_y, group_end);

                // A big enough combo or chain queues garbage onto the opponent via sim_garbage.zig's queueing lifecycle
                // (a growing chain overwrites its pending size until it concludes); marathon has no opponent, so it banks rise-freeze time on `self` instead (board.freezeFramesForMatch).
                if (s.game_mode == .marathon) {
                    self.rise_freeze = @min(self.rise_freeze + board.freezeFramesForMatch(is_chain, multiplier, real_count), board.MARATHON_MAX_RISE_FREEZE);
                } else if (is_chain) {
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
