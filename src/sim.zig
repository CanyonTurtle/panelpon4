// Simulation: swaps, pops, landings, and gravity -- the core gameplay rules. Match/chain/combo/garbage logic lives in the companion
// sim_matches.zig (re-exported below as `checkMatches`) to keep this file under the ~500-line guideline; both take `opponent: *s.Board` since a combo/chain on `self` drops garbage onto `opponent` instead (never self-inflicted in vs-CPU play).

const std = @import("std");
const c = @import("constants.zig");
const s = @import("state.zig");
const fx = @import("state_fx.zig");
const audio = @import("audio.zig");
const garbage = @import("sim_garbage.zig");

pub const checkMatches = @import("sim_matches.zig").checkMatches;

pub fn swappable(state: s.CellState) bool {
    return state == .empty or state == .normal;
}

pub fn trySwap(self: *s.Board) void {
    // cursor_row is relative to the visible window (see input.moveCursor) -- add SPAWN_ROWS to reach the matching
    // absolute logical row, since the board has an offscreen staging area above the ceiling (see Board.physRow).
    const row = self.cursor_row + c.SPAWN_ROWS;
    const a = self.cellAt(row, self.cursor_col);
    const b = self.cellAt(row, self.cursor_col + 1);
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
    // No chain reset here: chain only resets once the board is fully idle (see the boardBusy() check in main.update()),
    // so a "skill chain" -- another match set up while a previous one is still falling/popping -- extends it instead.
}

pub fn simulate(self: *s.Board, opponent: *s.Board) void {
    fx.tickMatchPopups(self);
    fx.tickParticles(self);
    if (self.combo_display_timer > 0) self.combo_display_timer -= 1;
    if (self.garbage_punish_timer > 0) self.garbage_punish_timer -= 1;

    var settled = false;
    // Cells that completed a .swapping/.landing -> .normal transition this frame. Passed to checkMatches so it only
    // reconsiders those cells' chainable status, leaving one still waiting its turn to fall untouched by this cleanup.
    var just_settled: [c.ROWS][c.COLS]bool = std.mem.zeroes([c.ROWS][c.COLS]bool);
    // Cells that finished popping (cleared to empty) this frame.
    var just_cleared: [c.ROWS][c.COLS]bool = std.mem.zeroes([c.ROWS][c.COLS]bool);

    // Progress swap / pop / landing timers.
    for (0..c.ROWS) |lr| {
        for (0..c.COLS) |col| {
            const cell = self.cellAt(@intCast(lr), @intCast(col));
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
                // A real match (.popping) and a garbage recycle (.recycling) share this group-timer mechanism (pop_group_end
                // on Cell), driven by one shared branch here; they only differ in what happens once the whole group finishes.
                .popping, .recycling => {
                    // The shared pre-pop preamble (Cell.pre_pop_timer) counts down first; `timer` is frozen until that
                    // finishes, so every member's cascade starts exactly where it always did, just uniformly delayed.
                    if (cell.pre_pop_timer > 0) {
                        cell.pre_pop_timer -= 1;
                    } else {
                        cell.timer -= 1;
                        // render.drawPoppingCell's elapsed = POP_FRAMES - timer: elapsed POP_FLASH_FRAMES is the exact instant
                        // the shrink begins, so this timer value is when the tick/burst cue should land with the animation.
                        if (cell.timer == c.POP_FRAMES - c.POP_FLASH_FRAMES) {
                            audio.playPopTick();
                            // One particle burst per block, timed to its own staggered pop (POP_STAGGER_FRAMES), so it reads
                            // as each block popping in turn. Garbage cracks open instead of shrinking, so it bursts below.
                            if (!cell.is_garbage) {
                                const px = c.BOARD_X + @as(i32, @intCast(col)) * c.TILE + @divTrunc(c.TILE, 2);
                                const py = c.BOARD_Y + (@as(i32, @intCast(lr)) - @as(i32, c.SPAWN_ROWS)) * c.TILE - @as(i32, @intCast(self.scroll_px)) + @divTrunc(c.TILE, 2);
                                fx.spawnPopParticles(self, px, py, cell.color);
                            }
                        }
                        // A garbage cell's own "turn" reads differently from a real block's (render.drawRecyclingCell): it
                        // hard-cuts to looking normal (converting) or starts oscillating (not) at elapsed == 0, so that's when its burst belongs.
                        if (cell.is_garbage and cell.timer == c.POP_FRAMES) {
                            const px = c.BOARD_X + @as(i32, @intCast(col)) * c.TILE + @divTrunc(c.TILE, 2);
                            const py = c.BOARD_Y + (@as(i32, @intCast(lr)) - @as(i32, c.SPAWN_ROWS)) * c.TILE - @as(i32, @intCast(self.scroll_px)) + @divTrunc(c.TILE, 2);
                            // A converting cell (Cell.garbage_reveals) bursts in its already-picked reveal color; a flash-only
                            // cell never gets a real color, so it bursts in garbage's muted teal instead (render_garbage.GARBAGE_HUE).
                            const particle_color: u8 = if (cell.garbage_reveals) cell.color else 1;
                            fx.spawnPopParticles(self, px, py, particle_color);
                        }
                    }
                    cell.pop_group_end -= 1;
                    if (cell.pop_group_end <= 0) {
                        if (cell.is_garbage) {
                            // A converting cell cracks open into a fresh, chainable block in place; a non-converting cell just reverts to plain, inert garbage.
                            // Deliberately NOT marked just_settled/settled even when it converts, so an unrelated checkMatches call this same frame can't wipe this reveal's fresh chainable flag (see checkMatches' unmatched-settle cleanup).
                            if (cell.garbage_reveals) {
                                cell.is_garbage = false;
                                cell.chainable = true;
                            }
                            cell.state = .normal;
                            cell.timer = 0;
                            cell.pre_pop_timer = 0;
                            cell.pop_group_end = 0;
                            cell.garbage_reveals = false;
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

    // Mark the stack of settled blocks directly above each just-cleared pop as chainable right when the pop finishes,
    // rather than tracking the flag through gravity as things fall -- a later match involving one is a chain continuation.
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
            const cell = self.cellAt(r, col);
            // Garbage blocks this marking pass like any other non-.normal obstacle -- it never inherits chainable this way
            // (only an explicit reveal does, see the .popping/.recycling branch above), so it and anything above stay untouched.
            if (cell.state != .normal or cell.is_garbage) break;
            cell.chainable = true;
            if (r == 0) break;
            r -= 1;
        }
    }

    // Gravity scans bottom-to-top per column; garbage is excluded here since
    // it falls as one rigid body, handled separately below.
    for (0..c.COLS) |ci| {
        const col: u8 = @intCast(ci);
        var r: u8 = c.ROWS - 1;
        while (r >= 1) : (r -= 1) {
            const below = self.cellAt(r, col);
            const above = self.cellAt(r - 1, col);
            if (below.state == .empty and above.state == .normal and !above.is_garbage) {
                below.* = above.*;
                below.state = .falling;
                below.fall_off = c.TILE;
                above.* = s.Cell{};
            }

            const cur = self.cellAt(r, col);
            if (cur.state == .falling and !cur.is_garbage) {
                cur.fall_off -= c.FALL_SPEED;
                if (cur.fall_off <= 0) {
                    cur.fall_off = 0;
                    if (r < c.ROWS - 1 and self.cellAt(r + 1, col).state == .empty) {
                        const next = self.cellAt(r + 1, col);
                        next.* = cur.*;
                        next.fall_off = c.TILE;
                        cur.* = s.Cell{};
                    } else {
                        // Matches are only checked among settled cells, once
                        // the landing bounce finishes (see .landing below).
                        cur.state = .landing;
                        cur.timer = c.LAND_FRAMES;
                    }
                }
            }
            if (r == 0) break;
        }
    }

    garbage.updateGarbageGravity(self);

    if (settled) {
        _ = checkMatches(self, opponent, just_settled);
    }
}

