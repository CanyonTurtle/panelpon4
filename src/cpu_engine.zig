// The "actual engine" behind the CPU's higher difficulty levels (see
// cpu_ai.zig, which picks a random move instead at the lower levels and
// falls back to this when it wants a genuinely good one). Deliberately
// modeled as a small, self-contained board simulator rather than reusing
// sim.zig/sim_matches.zig directly: those drive real gameplay frame-by-frame
// (animation timers, staggered pops, the rising floor) and this only needs
// the *logical* end state a candidate swap would settle into, computed all
// at once, to score it -- reusing the animated version would mean either
// running it for dozens of frames per candidate or duplicating its state
// machine anyway.
//
// Only reasons about the currently-interactable VISIBLE_ROWS x COLS window
// (matching the cursor's own legal range -- see input.moveCursor) -- the
// hidden extra ring-buffer row still rising in is deliberately out of scope,
// same as it is for the player's own cursor.
//
// Uses a per-color bitboard (one u128 bitmask per color, bit index
// row*COLS+col) for the structural heuristic (structuralScore below), where
// shift+AND+popCount tricks are a natural, safe fit (vertical adjacency is a
// plain row-stride shift with no wraparound risk at all; horizontal
// adjacency is guarded against wrapping into the next row by H_MASK). Match
// detection/cascade resolution (findAndClearMatches/applyGravity) stays
// plain nested-loop array logic instead, mirroring sim_matches.zig's own
// proven approach -- that logic determines whether the AI ever "sees" a
// winning move at all, so it's worth more to keep it simple and obviously
// correct than to also force it through bit tricks.

const std = @import("std");
const c = @import("constants.zig");
const s = @import("state.zig");

const ROWS: u8 = c.VISIBLE_ROWS;
const COLS: u8 = c.COLS;

pub const EMPTY: i8 = -1;
pub const GARBAGE: i8 = -2;

// How much deeper each of a candidate move's own cascade/structural score is
// discounted when credited to the move that led into it -- see
// evaluateMove's lookahead. A follow-up chain is real value, but the move
// that actually pops it should still rank above the setup move when both are
// available this turn.
const LOOKAHEAD_DISCOUNT: i32 = 2;

// Weights for simulateCascade's score -- chosen so a deeper chain always
// outweighs an equivalent-sized single pop (chain_depth is squared, per the
// user's ask to specifically value chain-building), a combo bigger than the
// 3-block minimum adds on top of that, and clearing garbage (freeing the
// board, denying the opponent nothing since it's already been sent) counts
// for a little less than an equivalent real pop.
const BASE_WEIGHT: i32 = 10;
const GARBAGE_WEIGHT: i32 = 6;
const COMBO_WEIGHT: i32 = 8;

// Structural heuristic weights (see structuralScore) -- small relative to
// BASE_WEIGHT so an actual pop this turn always beats a purely structural
// improvement, but still enough to meaningfully rank moves that don't pop
// anything yet.
const ADJACENCY_WEIGHT: i32 = 3;
const HEIGHT_WEIGHT: i32 = 2;

pub const Move = struct { row: u8, col: u8 };

pub const Grid = struct {
    cell: [ROWS][COLS]i8 = [_][COLS]i8{[_]i8{EMPTY} ** COLS} ** ROWS,

    // Snapshots the currently-interactable window of a real board. Only
    // meaningful while the board is idle (see Board.boardBusy) -- every
    // occupied cell is then guaranteed to be `.normal`, so there's no
    // mid-animation state to reason about.
    pub fn fromBoard(b: *s.Board) Grid {
        var g: Grid = .{};
        for (0..ROWS) |lr| {
            for (0..COLS) |col| {
                const cell = b.cellAt(@intCast(lr), @intCast(col));
                g.cell[lr][col] = if (cell.state != .normal)
                    EMPTY
                else if (cell.is_garbage)
                    GARBAGE
                else
                    @intCast(cell.color);
            }
        }
        return g;
    }
};

fn swappable(v: i8) bool {
    return v == EMPTY or v >= 0;
}

// Mirrors sim.trySwap's own guard (see input.canSwapAt too): neither side
// garbage, and not both empty (there'd be nothing to actually swap).
fn legalSwap(grid: *const Grid, row: u8, col: u8) bool {
    const a = grid.cell[row][col];
    const b = grid.cell[row][col + 1];
    if (!swappable(a) or !swappable(b)) return false;
    if (a == EMPTY and b == EMPTY) return false;
    return true;
}

fn swap(grid: *Grid, row: u8, col: u8) void {
    const tmp = grid.cell[row][col];
    grid.cell[row][col] = grid.cell[row][col + 1];
    grid.cell[row][col + 1] = tmp;
}

// Column-independent gravity: every occupied cell (real or garbage) falls
// straight down to fill empties below it, preserving relative vertical
// order within the column. Unlike the real game, garbage here falls as
// individual cells rather than a rigid connected clump -- a deliberate
// simplification; the AI only needs a plausible logical end state to score,
// not pixel-perfect physics.
fn applyGravity(grid: *Grid) void {
    for (0..COLS) |col| {
        var vals: [ROWS]i8 = undefined;
        var n: usize = 0;
        for (0..ROWS) |row| {
            const v = grid.cell[row][col];
            if (v != EMPTY) {
                vals[n] = v;
                n += 1;
            }
        }
        for (0..ROWS - n) |row| grid.cell[row][col] = EMPTY;
        for (0..n) |i| grid.cell[ROWS - n + i][col] = vals[i];
    }
}

const MatchResult = struct { real_count: u32 = 0, garbage_count: u32 = 0, any: bool = false };

// One settle-and-clear pass: finds every run of 3+ same-color cells (row or
// column), propagates into any orthogonally-touching garbage cell exactly
// like sim_matches.checkMatches does, then clears every matched cell to
// EMPTY (garbage included -- unlike the real game, a recycled garbage cell
// here doesn't become a fresh colored block; the AI only cares that the
// space is freed, not what it might become).
fn findAndClearMatches(grid: *Grid) MatchResult {
    var matched: [ROWS][COLS]bool = std.mem.zeroes([ROWS][COLS]bool);
    var any = false;

    for (0..ROWS) |lr| {
        var col: usize = 0;
        while (col < COLS) {
            const v = grid.cell[lr][col];
            if (v < 0) {
                col += 1;
                continue;
            }
            var run_len: usize = 1;
            while (col + run_len < COLS and grid.cell[lr][col + run_len] == v) run_len += 1;
            if (run_len >= 3) {
                for (0..run_len) |k| matched[lr][col + k] = true;
                any = true;
            }
            col += run_len;
        }
    }
    for (0..COLS) |col| {
        var r: usize = 0;
        while (r < ROWS) {
            const v = grid.cell[r][col];
            if (v < 0) {
                r += 1;
                continue;
            }
            var run_len: usize = 1;
            while (r + run_len < ROWS and grid.cell[r + run_len][col] == v) run_len += 1;
            if (run_len >= 3) {
                for (0..run_len) |k| matched[r + k][col] = true;
                any = true;
            }
            r += run_len;
        }
    }
    if (!any) return .{};

    var propagated = true;
    while (propagated) {
        propagated = false;
        for (0..ROWS) |lr| {
            for (0..COLS) |col| {
                if (matched[lr][col] or grid.cell[lr][col] != GARBAGE) continue;
                const touches =
                    (lr > 0 and matched[lr - 1][col]) or
                    (lr + 1 < ROWS and matched[lr + 1][col]) or
                    (col > 0 and matched[lr][col - 1]) or
                    (col + 1 < COLS and matched[lr][col + 1]);
                if (touches) {
                    matched[lr][col] = true;
                    propagated = true;
                }
            }
        }
    }

    var result = MatchResult{ .any = true };
    for (0..ROWS) |lr| {
        for (0..COLS) |col| {
            if (!matched[lr][col]) continue;
            if (grid.cell[lr][col] == GARBAGE) result.garbage_count += 1 else result.real_count += 1;
            grid.cell[lr][col] = EMPTY;
        }
    }
    return result;
}

// Repeatedly settles and clears matches until nothing more falls into place,
// mirroring the real cascade (a pop causes a fall, which may complete a new
// match, and so on -- see sim.simulate/checkMatches) but resolved instantly
// rather than frame-by-frame. Weighted so a deeper chain always scores above
// an equally-sized single pop (chain_depth is squared), and a combo (a
// single pass popping more than the 3-block minimum) adds on top of that --
// see the module doc comment for the full rationale.
fn simulateCascade(grid: *Grid) i32 {
    var total: i32 = 0;
    var chain_depth: i32 = 0;
    while (true) {
        applyGravity(grid);
        const result = findAndClearMatches(grid);
        if (!result.any) break;
        chain_depth += 1;
        var pass_score = @as(i32, @intCast(result.real_count)) * BASE_WEIGHT * chain_depth * chain_depth;
        pass_score += @as(i32, @intCast(result.garbage_count)) * GARBAGE_WEIGHT;
        if (result.real_count > 3) pass_score += @as(i32, @intCast(result.real_count - 3)) * COMBO_WEIGHT;
        total += pass_score;
    }
    return total;
}

// Bits set at every position where col != COLS-1 -- guards horizontal
// adjacency checks (see structuralScore) against wrapping from a row's last
// column into the next row's first, since a plain `m & (m >> 1)` alone can't
// tell "same row" from "just the next bit".
const H_MASK: u128 = blk: {
    var m: u128 = 0;
    for (0..ROWS) |row| {
        for (0..COLS - 1) |col| m |= @as(u128, 1) << @intCast(row * COLS + col);
    }
    break :blk m;
};

// A fast, bitboard-driven tiebreaker/guide for moves that don't pop anything
// immediately: rewards same-color cells sitting next to each other (row-wise
// via H_MASK-guarded `m & (m >> 1)`, column-wise via a plain row-stride
// shift -- safe with no masking needed, since shifting by exactly COLS bits
// always maps a cell to the one directly above/below it, never sideways),
// and penalizes tall stacks (each column's height alone, not relative to its
// neighbors -- simple and enough to discourage building dangerously high).
// A column's height in rows -- 0 if it's empty, up to ROWS if it's occupied
// all the way to the very top. Shared by structuralScore's own mild, linear
// per-column penalty (below) and heightDangerPenalty's much sharper one,
// which only kicks in once the *tallest* column gets genuinely close to
// topping out (see raiseValue).
fn columnHeight(grid: *const Grid, col: u8) i32 {
    for (0..ROWS) |row| {
        if (grid.cell[row][col] != EMPTY) return @as(i32, ROWS) - @as(i32, @intCast(row));
    }
    return 0;
}

fn maxColumnHeight(grid: *const Grid) i32 {
    var max_h: i32 = 0;
    for (0..COLS) |col| max_h = @max(max_h, columnHeight(grid, @intCast(col)));
    return max_h;
}

// Once the tallest column gets within DANGER_MARGIN rows of the top, every
// row closer than that counts steeply against whatever pushed it there --
// on top of (not instead of) structuralScore's own mild per-column height
// penalty above, which alone was too weak to ever outweigh a low-material
// board's incentive to raise (see raiseValue's own doc comment for why this
// matters: a board can be real-cell-poor and still have a dangerously tall,
// skinny pillar of blocks, and raising always pushes every column up by one
// more row, so the two need to be weighed against each other, not just
// material shortage against nothing).
const DANGER_MARGIN: i32 = 3; // rows of headroom below which danger starts counting
// Deliberately much steeper than every other weight in this file: topping
// out ends the game outright, a cost no ordinary structural or material
// consideration comes close to, so once a column is genuinely this close to
// the top, nothing else should be able to outweigh backing off from it --
// see raiseValue's own doc comment for the scenario (a skinny, materially-
// poor pillar) that a gentler penalty failed to actually stop.
const DANGER_WEIGHT: i32 = 200; // per row closer than that

fn heightDangerPenalty(height: i32) i32 {
    const danger = height - (ROWS - DANGER_MARGIN);
    if (danger <= 0) return 0;
    return danger * DANGER_WEIGHT;
}

fn structuralScore(grid: *const Grid) i32 {
    var masks: [c.NUM_COLORS]u128 = [_]u128{0} ** c.NUM_COLORS;
    for (0..ROWS) |row| {
        for (0..COLS) |col| {
            const v = grid.cell[row][col];
            if (v >= 0) masks[@intCast(v)] |= @as(u128, 1) << @intCast(row * COLS + col);
        }
    }
    var score: i32 = 0;
    for (masks) |m| {
        score += @as(i32, @popCount(m & (m >> 1) & H_MASK)) * ADJACENCY_WEIGHT;
        score += @as(i32, @popCount(m & (m >> COLS))) * ADJACENCY_WEIGHT;
    }
    var tallest: i32 = 0;
    for (0..COLS) |col| {
        const height = columnHeight(grid, @intCast(col));
        score -= height * HEIGHT_WEIGHT;
        tallest = @max(tallest, height);
    }
    score -= heightDangerPenalty(tallest);
    return score;
}

// Applies the swap to a copy, resolves its full cascade, and scores the
// result: the cascade's own points dominate (multiplied well above anything
// structuralScore could contribute, so a real pop always outranks a purely
// structural improvement), plus a discounted look at the *best* follow-up
// move available afterward (see LOOKAHEAD_DISCOUNT) for depth > 1 -- the
// "BFS" that lets a setup move (one that doesn't pop anything itself but
// creates a strong follow-up) still rank above a shallow immediate pop.
fn evaluateMove(grid: Grid, mv: Move, depth: u8) i32 {
    var g = grid;
    swap(&g, mv.row, mv.col);
    const cascade_score = simulateCascade(&g);
    var value = cascade_score * BASE_WEIGHT + structuralScore(&g);
    if (depth > 1) {
        if (bestMoveValue(&g, depth - 1)) |follow| value += @divTrunc(follow, LOOKAHEAD_DISCOUNT);
    }
    return value;
}

fn bestMoveValue(grid: *const Grid, depth: u8) ?i32 {
    var best: ?i32 = null;
    for (0..ROWS) |r| {
        for (0..COLS - 1) |cl| {
            const row: u8 = @intCast(r);
            const col: u8 = @intCast(cl);
            if (!legalSwap(grid, row, col)) continue;
            const v = evaluateMove(grid.*, .{ .row = row, .col = col }, depth);
            if (best == null or v > best.?) best = v;
        }
    }
    return best;
}

pub const ScoredMove = struct { move: Move, value: i32 };

// The best-scoring legal swap in the current grid, searching `depth` moves
// deep (1 = just this swap's own result; 2 adds a discounted look at the
// best follow-up -- see evaluateMove), together with its own score -- see
// bestAction, which weighs that score against raiseValue below. Null only if
// there's genuinely no legal swap on the board at all (e.g. it's entirely
// garbage or entirely empty).
pub fn bestSwapScored(grid: Grid, depth: u8) ?ScoredMove {
    var best: ?ScoredMove = null;
    for (0..ROWS) |r| {
        for (0..COLS - 1) |cl| {
            const row: u8 = @intCast(r);
            const col: u8 = @intCast(cl);
            if (!legalSwap(&grid, row, col)) continue;
            const v = evaluateMove(grid, .{ .row = row, .col = col }, depth);
            if (best == null or v > best.?.value) best = .{ .move = .{ .row = row, .col = col }, .value = v };
        }
    }
    return best;
}

// The engine's original entry point -- just the swap, discarding its score.
// Kept for callers (and tests) that only care about which swap, not whether
// it's actually worth playing over raising -- see bestAction for that.
pub fn bestMove(grid: Grid, depth: u8) ?Move {
    return if (bestSwapScored(grid, depth)) |r| r.move else null;
}

// How many real (non-garbage, non-empty) cells are on the board -- the
// engine's notion of how much "ammunition" it has to work with. Garbage
// doesn't count: it's not swappable or matchable on its own, so a board
// that's mostly garbage is just as short on real material as one that's
// mostly empty.
fn realCellCount(grid: *const Grid) i32 {
    var n: i32 = 0;
    for (0..ROWS) |row| {
        for (0..COLS) |col| {
            if (grid.cell[row][col] >= 0) n += 1;
        }
    }
    return n;
}

// Below this many real cells, the board doesn't have enough material left to
// reliably set up its own matches -- five rows' worth (COLS * 5).
const LOW_MATERIAL_THRESHOLD: i32 = @as(i32, COLS) * 5;
const LOW_MATERIAL_WEIGHT: i32 = 4; // per real cell short of the threshold

// The value of raising the stack right now instead of playing a swap.
// Scales up as real material runs short (rewarding a raise precisely when
// the board needs more to work with), and goes negative once material is
// plentiful -- equivalently, a swap is worth relatively less while material
// is scarce, since it's spending down cells the engine doesn't have much of
// to begin with. Deliberately never a flat bonus: comparing this directly
// against a swap's own (unpenalized) score means raising only ever wins
// because material is actually low, never just because every available swap
// happens to be mediocre with material to spare -- see bestAction.
//
// Also weighs the *danger* of raising: a raise always pushes every column up
// by exactly one row (see board.doRise), so it's judged against the height
// that would result, not the current one -- a board can be desperately short
// on real material (rewarding a raise by the reasoning above) while also
// having a tall, skinny pillar of blocks in one column (from garbage, an
// awkward stack, or just bad luck), and pushing that pillar even closer to
// the top is exactly how naively chasing material gets the CPU killed.
// heightDangerPenalty grows steeply enough once that pillar is genuinely
// close to the top to overrule any amount of material shortage.
pub fn raiseValue(grid: Grid) i32 {
    const shortfall = LOW_MATERIAL_THRESHOLD - realCellCount(&grid);
    const value = shortfall * LOW_MATERIAL_WEIGHT;
    return value - heightDangerPenalty(maxColumnHeight(&grid) + 1);
}

pub const Action = union(enum) { swap: Move, raise };

// The engine's entry point (see cpu_ai.update): either the best legal swap,
// or a request to raise the stack instead, whichever scores higher right
// now. A real match/chain (always worth several hundred points -- see
// simulateCascade/BASE_WEIGHT) will always beat raising by a wide margin
// regardless of material, so this never passes up an actual win; raising
// only wins when there's no good swap AND material is genuinely short (see
// raiseValue), or when there's no legal swap at all.
pub fn bestAction(grid: Grid, depth: u8) Action {
    const swap_result = bestSwapScored(grid, depth);
    const swap_value = if (swap_result) |r| r.value else std.math.minInt(i32);
    if (raiseValue(grid) > swap_value) return .raise;
    return .{ .swap = swap_result.?.move };
}
