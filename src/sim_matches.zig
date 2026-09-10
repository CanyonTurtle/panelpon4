// Match detection, chain/combo scoring, and garbage spawning -- split out
// from sim.zig (re-exported there as `checkMatches`).

const std = @import("std");
const c = @import("constants.zig");
const s = @import("state.zig");
const fx = @import("state_fx.zig");
const audio = @import("audio.zig");
const garbage = @import("sim_garbage.zig");
const resolve = @import("sim_matches_resolve.zig");

// `.landing` is already final-colored, just still bouncing -- treating it as
// eligible lets near-simultaneous landings still resolve as one match.
fn matchEligible(state: s.CellState) bool {
    return state == .normal or state == .landing;
}

// True only while still in the group's shared pre-pop preamble -- the
// late-join sweep only attaches within this window, never to an already-resolving group.
fn isLateJoinable(cell: *const s.Cell) bool {
    return (cell.state == .popping or cell.state == .recycling) and cell.pre_pop_timer > 0;
}

// The one hidden row rising in from below -- real for gravity, but not
// matchable until a rise promotes it into the lowest accessible row.
const HIDDEN_ROW = c.ROWS - 1;

fn colorAt(grid: *const [c.ROWS][c.COLS]i16, row: i32, col: i32) i16 {
    if (row < 0 or row >= c.ROWS or col < 0 or col >= c.COLS) return -1;
    return grid[@intCast(row)][@intCast(col)];
}

// True if placing `chosen` at (row, col) would complete a 3+ run with its
// neighbors, checked both directions on each axis. An undecided neighbor reads as -1.
pub fn wouldCompleteRun(grid: *const [c.ROWS][c.COLS]i16, row: u8, col: u8, chosen: i16) bool {
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
            // Garbage is colorless: excluded here like an empty cell (see
            // the propagation pass below for how it joins a match).
            settled_color[lr][col] = if (matchEligible(cell.state) and !cell.is_garbage) @as(i16, cell.color) else -1;
            settled_chainable[lr][col] = matchEligible(cell.state) and cell.chainable;
        }
    }
    // The hidden row never seeds or joins a match -- see HIDDEN_ROW's own
    // doc comment.
    for (0..c.COLS) |col| {
        settled_color[HIDDEN_ROW][col] = -1;
        settled_chainable[HIDDEN_ROW][col] = false;
    }

    // Sweeps a garbage cell that just became eligible into an ALREADY-ACTIVE
    // group, inheriting its timers -- ordinary propagation can't reach it.
    var late_joined = true;
    while (late_joined) {
        late_joined = false;
        for (0..c.ROWS) |lr| {
            for (0..c.COLS) |col| {
                if (lr == HIDDEN_ROW) continue;
                const cell = self.cellAt(@intCast(lr), @intCast(col));
                if (!cell.is_garbage or !matchEligible(cell.state)) continue;

                var anchor: ?*s.Cell = null;
                if (lr > 0) {
                    const n = self.cellAt(@intCast(lr - 1), @intCast(col));
                    if (isLateJoinable(n)) anchor = n;
                }
                if (anchor == null and lr + 1 < c.ROWS) {
                    const n = self.cellAt(@intCast(lr + 1), @intCast(col));
                    if (isLateJoinable(n)) anchor = n;
                }
                if (anchor == null and col > 0) {
                    const n = self.cellAt(@intCast(lr), @intCast(col - 1));
                    if (isLateJoinable(n)) anchor = n;
                }
                if (anchor == null and col + 1 < c.COLS) {
                    const n = self.cellAt(@intCast(lr), @intCast(col + 1));
                    if (isLateJoinable(n)) anchor = n;
                }
                const a = anchor orelse continue;

                cell.pop_group_end = a.pop_group_end;
                cell.timer = a.timer;
                cell.pre_pop_timer = a.pre_pop_timer;
                cell.state = .recycling;
                // Same per-piece bottom-row rule as an ordinary recycle,
                // keyed off this cell's own garbage_group.
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
        // Cells that just settled without matching have spent their chain
        // status -- a later, unrelated match shouldn't credit them as a continuation.
        for (0..c.ROWS) |lr| {
            for (0..c.COLS) |col| {
                if (just_settled[lr][col] and settled_chainable[lr][col]) {
                    self.cellAt(@intCast(lr), @intCast(col)).chainable = false;
                }
            }
        }
        return false;
    }

    // Garbage never seeds a match, but a pop propagates into any touching
    // cell and beyond -- a whole connected clump goes together.
    var propagated = true;
    while (propagated) {
        propagated = false;
        for (0..c.ROWS) |lr| {
            for (0..c.COLS) |col| {
                if (matched[lr][col] or lr == HIDDEN_ROW) continue;
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

    // Groups matched cells by flood fill and resolves each group's timers,
    // scoring, and garbage queueing. See sim_matches_resolve.zig.
    resolve.resolveMatchGroups(self, opponent, &matched, &settled_color, &settled_chainable);

    // A just-settled cell with chainable set that wasn't part of a match has
    // spent its chain status -- back to being an ordinary block.
    for (0..c.ROWS) |lr| {
        for (0..c.COLS) |col| {
            if (just_settled[lr][col] and settled_chainable[lr][col] and !matched[lr][col]) {
                self.cellAt(@intCast(lr), @intCast(col)).chainable = false;
            }
        }
    }

    return true;
}
