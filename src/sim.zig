// Simulation: swaps, pops, landings, and gravity -- the core gameplay rules.
// Match detection/chain/combo/garbage-spawning lives in the companion
// sim_matches.zig (re-exported below as `checkMatches`, so call sites and
// tests are unaffected by the split) to keep this file under the project's
// ~500-line-per-file guideline.
//
// Every entry point takes an explicit `self: *s.Board` (see state.zig) so
// the exact same logic drives both the player's and the CPU's board.
// simulate/checkMatches additionally take `opponent: *s.Board`: a big enough
// combo or chain on `self` drops garbage onto `opponent` instead, since
// garbage is never self-inflicted in vs-CPU play (see sim_matches.zig).

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
    // cursor_row is relative to the visible window (see input.moveCursor) --
    // add SPAWN_ROWS to reach the matching absolute logical row now that the
    // board has an offscreen staging area above the ceiling (see
    // Board.physRow).
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
    // No chain reset here: chain only resets once the board is fully idle
    // (see the boardBusy() check in main.update()). Resetting it on every
    // swap would kill "skill chains" -- setting up another match while a
    // previous one is still falling/popping should extend the same chain,
    // not start a fresh one, as long as the board never actually went idle
    // in between.
}

pub fn simulate(self: *s.Board, opponent: *s.Board) void {
    fx.tickMatchPopups(self);
    fx.tickParticles(self);
    if (self.combo_display_timer > 0) self.combo_display_timer -= 1;
    if (self.garbage_punish_timer > 0) self.garbage_punish_timer -= 1;

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
                // A real match (.popping) and a garbage recycle (.recycling)
                // share this same group-timer mechanism -- see pop_group_end
                // on Cell -- so both are driven by one shared branch here;
                // they only differ in what happens once the *whole* group
                // (every member, of either kind, in this connected pop/
                // recycle event) finishes together.
                .popping, .recycling => {
                    // The shared pre-pop blink+pause preamble (see
                    // Cell.pre_pop_timer) counts down in lockstep for every
                    // member of the group first; `timer` -- which drives the
                    // ordinary staggered pop/reveal cascade below, unchanged
                    // from before this preamble existed -- is frozen until
                    // that finishes, so every member's own cascade still
                    // starts exactly where it always did, just uniformly
                    // delayed for the whole group.
                    if (cell.pre_pop_timer > 0) {
                        cell.pre_pop_timer -= 1;
                    } else {
                        cell.timer -= 1;
                        // render.drawPoppingCell's own elapsed = POP_FRAMES -
                        // timer: elapsed 0..POP_FLASH_FRAMES-1 is the initial
                        // wobble, POP_FLASH_FRAMES..POP_FRAMES is the actual
                        // shrink-to-nothing -- so timer == POP_FRAMES -
                        // POP_FLASH_FRAMES is elapsed == POP_FLASH_FRAMES,
                        // the exact instant THIS block's shrink actually
                        // begins (timer == 0 -- elapsed == POP_FRAMES -- is
                        // instead the instant it's already finished
                        // shrinking and fully vanished, too late for either
                        // cue to still land "with" the animation).
                        if (cell.timer == c.POP_FRAMES - c.POP_FLASH_FRAMES) {
                            audio.playPopTick();
                            // A little impact feedback right as THIS block
                            // starts shrinking away -- one burst per block,
                            // each timed to its own staggered pop (see
                            // POP_STAGGER_FRAMES), not one burst for the
                            // whole match at once, so it reads as each block
                            // transforming and popping in turn. Garbage
                            // cracks open in place instead of shrinking away
                            // (see the pop_group_end branch below), so it
                            // gets no burst of its own here -- see below
                            // instead, on its own different timing.
                            if (!cell.is_garbage) {
                                const px = c.BOARD_X + @as(i32, @intCast(col)) * c.TILE + @divTrunc(c.TILE, 2);
                                const py = c.BOARD_Y + (@as(i32, @intCast(lr)) - @as(i32, c.SPAWN_ROWS)) * c.TILE - @as(i32, @intCast(self.scroll_px)) + @divTrunc(c.TILE, 2);
                                fx.spawnPopParticles(self, px, py, cell.color);
                            }
                        }
                        // A garbage cell's own "turn" reads completely
                        // differently from a real block's (see
                        // render.drawRecyclingCell): a converting cell hard-
                        // cuts straight to looking like a plain normal
                        // block the instant elapsed == 0 (timer ==
                        // POP_FRAMES), no flash-then-shrink first, and a
                        // non-converting cell starts its own oscillating
                        // flash at that exact same instant instead -- so
                        // that's the moment a burst belongs, for both,
                        // since it's what actually reads as "this piece's
                        // turn has come" even for a cell that stays garbage
                        // afterward.
                        if (cell.is_garbage and cell.timer == c.POP_FRAMES) {
                            const px = c.BOARD_X + @as(i32, @intCast(col)) * c.TILE + @divTrunc(c.TILE, 2);
                            const py = c.BOARD_Y + (@as(i32, @intCast(lr)) - @as(i32, c.SPAWN_ROWS)) * c.TILE - @as(i32, @intCast(self.scroll_px)) + @divTrunc(c.TILE, 2);
                            // A converting cell (Cell.garbage_reveals) bursts
                            // in the color it's about to become (already
                            // picked -- see sim_matches.checkMatches -- by
                            // the time this fires); a flash-only cell never
                            // gets a real color assigned at all, so it
                            // bursts in garbage's own muted teal instead
                            // (color value 1 -- see
                            // render_garbage.GARBAGE_HUE).
                            const particle_color: u8 = if (cell.garbage_reveals) cell.color else 1;
                            fx.spawnPopParticles(self, px, py, particle_color);
                        }
                    }
                    cell.pop_group_end -= 1;
                    if (cell.pop_group_end <= 0) {
                        if (cell.is_garbage) {
                            // A converting cell (see Cell.garbage_reveals --
                            // set once per event in checkMatches: only a
                            // clump's bottom-most row per column ever
                            // converts) doesn't disappear -- it cracks open
                            // into a fresh, chainable block, in place, once
                            // the *whole* connected recycle event (which may
                            // span several garbage cells and/or real matched
                            // cells -- see the propagation pass in
                            // checkMatches) finishes together. It already
                            // looks like a plain normal block by now -- see
                            // render.drawRecyclingCell, which reveals it (no
                            // animation) the instant its own staggered turn
                            // arrives, well before the group as a whole
                            // resolves -- this is just the moment it actually
                            // becomes interactive (swappable, matchable,
                            // able to fall).
                            //
                            // A non-converting cell (the rest of a taller
                            // clump) just played the same flash/pause
                            // preamble as everything else in the group, then
                            // reverts to plain, inert, still-garbage --
                            // exactly its pre-event state, ready to be swept
                            // into some future recycle event (most likely
                            // once whatever converted out from under it
                            // leaves this now-shorter clump unsupported and
                            // gravity pulls it down to be touched again).
                            //
                            // Deliberately NOT marked just_settled/settled
                            // even when it does convert: checkMatches' "spend
                            // chainable on an unmatched settle" cleanup (for
                            // cells that inherited chainable from an earlier
                            // pop and turned out to be a dead end) would
                            // otherwise immediately wipe the chainable flag
                            // this exact reveal just granted, if a
                            // checkMatches call happened to run this same
                            // frame for an unrelated reason -- that cleanup
                            // can't distinguish "freshly granted" from
                            // "inherited and now proven dead". It'll get
                            // checked for matches the normal way once it
                            // actually falls/lands (or something else
                            // triggers a check) instead.
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
            const cell = self.cellAt(r, col);
            // Garbage blocks this marking pass like any other non-.normal
            // obstacle: it's inert and never inherits chainable through this
            // mechanism (only a revealed block does, explicitly, when it's
            // recycled -- see the .popping/.recycling branch above), so it --
            // and anything further above it -- is left untouched.
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

    garbage.updateGarbageGravity(self);

    if (settled) {
        _ = checkMatches(self, opponent, just_settled);
    }
}

