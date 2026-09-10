// Match detection, chain/combo scoring, and garbage spawning -- split out
// from sim.zig (where it's re-exported as `checkMatches`, so call sites and
// tests are unaffected) to keep that file under the project's
// ~500-line-per-file guideline. Stays tightly coupled to sim.simulate (the
// only caller) rather than being a fully standalone module.

const std = @import("std");
const c = @import("constants.zig");
const s = @import("state.zig");
const fx = @import("state_fx.zig");
const audio = @import("audio.zig");
const garbage = @import("sim_garbage.zig");
const resolve = @import("sim_matches_resolve.zig");

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

// True only while a cell is *both* actively popping/recycling *and* still in
// its group's shared pre-pop preamble (see Cell.pre_pop_timer) -- i.e. it
// hasn't actually started its own staggered reveal/pop cascade yet. The
// late-join sweep below only ever attaches to a neighbor in this window: a
// piece landing that early is plausibly part of the very same cascade
// moment, just a frame or more behind (see the sweep's own doc comment for
// why that's worth catching) -- but a piece that only arrives *after* the
// preamble, once the group is already visibly resolving, is a separate,
// later event that merely happens to touch it, and should never be swept
// into a pop it was never actually part of (a genuinely different piece
// landing on an already-recycling clump does not itself pop).
fn isLateJoinable(cell: *const s.Cell) bool {
    return (cell.state == .popping or cell.state == .recycling) and cell.pre_pop_timer > 0;
}

// The one hidden ring-buffer row rising in from below (see board.doRise) --
// not reachable by the cursor (input.zig/cpu_ai.zig both stay within
// VISIBLE_ROWS), but still a real part of the grid gravity operates on, so a
// block can rest there like anywhere else. It just isn't *matchable* yet:
// see the settled_color/settled_chainable overrides below, which keep it
// out of both seeding a run and being pulled in via propagation, until a
// rise actually promotes it into the lowest accessible row (see
// render.drawBoard's dithered overlay for the matching visual cue).
const HIDDEN_ROW = c.ROWS - 1;

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
            // Garbage is colorless: it never seeds or joins a color run on
            // its own (only via the propagation pass below), so it's
            // excluded here exactly like an empty/animating cell would be.
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

    // Groups the matched cells by 4-connectivity flood fill and resolves
    // each connected group independently -- staggered pop/recycle timers,
    // chain/combo scoring, the popup badge, and chain/combo garbage
    // queueing. See sim_matches_resolve.zig.
    resolve.resolveMatchGroups(self, opponent, &matched, &settled_color, &settled_chainable);

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
