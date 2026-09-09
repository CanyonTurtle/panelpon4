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
// The board snapshot (Grid) lives in the companion cpu_grid.zig, and
// garbage's rigid-body gravity in cpu_engine_garbage.zig (both split out to
// keep this file under the project's ~500-line-per-file guideline, and to
// let the two depend on the shared Grid without depending on each other --
// see cpu_grid.zig's own doc comment) -- cross-checked against the real
// sim.zig/sim_garbage.zig behavior in cpu_engine_garbage_test.zig.
//
// Uses a per-color bitboard (one u128 bitmask per color, bit index
// row*COLS+col) for the structural heuristic (structuralScore below), where
// shift+AND+popCount tricks are a natural, safe fit (vertical adjacency is a
// plain row-stride shift with no wraparound risk at all; horizontal
// adjacency is guarded against wrapping into the next row by H_MASK). Match
// detection/cascade resolution (findAndClearMatches/cpu_engine_garbage.settle)
// stays plain nested-loop array logic instead, mirroring sim_matches.zig's
// own proven approach -- that logic determines whether the AI ever "sees" a
// winning move at all, so it's worth more to keep it simple and obviously
// correct than to also force it through bit tricks.

const std = @import("std");
const c = @import("constants.zig");
const grid_mod = @import("cpu_grid.zig");
const garbage = @import("cpu_engine_garbage.zig");

const ROWS = grid_mod.ROWS;
const COLS = grid_mod.COLS;

pub const EMPTY = grid_mod.EMPTY;
pub const GARBAGE = grid_mod.GARBAGE;
pub const Grid = grid_mod.Grid;

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

fn swappable(v: i8) bool {
    return v == EMPTY or v >= 0;
}

// Mirrors sim.trySwap's own guard (see input.canSwapAt too): neither side
// garbage, and not both empty (there'd be nothing to actually swap) -- plus
// one guard sim.trySwap doesn't need: identical values on both sides. A
// player swapping two same-colored blocks is harmless (just a wasted
// button press), but offering it to the *engine* as a legal candidate is
// actively dangerous: swapping two equal values leaves the grid perfectly
// unchanged, so its own immediate score is always exactly baseline -- yet
// at depth > 1 it still collects evaluateMove's full discounted lookahead
// bonus for whatever already was the board's best follow-up move, a bonus
// that was available whether or not this pointless swap was ever played.
// That free, unearned credit can let a true no-op outscore every real
// option on a quiet board, and since playing it never actually changes
// anything, the next decide tick faces the exact same board and reaches
// the exact same conclusion -- the CPU gets stuck reselecting (and
// "playing") the identical no-op swap forever. Excluding it here means it
// never enters the search at all, so it can never win by default.
fn legalSwap(grid: *const Grid, row: u8, col: u8) bool {
    const a = grid.cell[row][col];
    const b = grid.cell[row][col + 1];
    if (!swappable(a) or !swappable(b)) return false;
    if (a == b) return false;
    return true;
}

fn swap(grid: *Grid, row: u8, col: u8) void {
    const tmp = grid.cell[row][col];
    grid.cell[row][col] = grid.cell[row][col + 1];
    grid.cell[row][col + 1] = tmp;
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
            if (grid.cell[lr][col] == GARBAGE) {
                // A clump taller than one row only ever converts its
                // bottom-most (per column) row per event -- mirrors
                // sim_matches.zig's own real rule (see Cell.garbage_reveals
                // there): if there's another matched garbage cell directly
                // below, that one's closer to the bottom, so this one just
                // stays garbage instead of clearing -- it'll be swept up
                // again once gravity pulls the now-shorter clump down onto
                // whatever's left.
                const below_pops = lr + 1 < ROWS and matched[lr + 1][col] and grid.cell[lr + 1][col] == GARBAGE;
                if (below_pops) continue;
                result.garbage_count += 1;
            } else {
                result.real_count += 1;
            }
            grid.cell[lr][col] = EMPTY;
        }
    }
    return result;
}

// Repeatedly settles and clears matches until nothing more falls into place,
// mirroring the real cascade (a pop causes a fall, which may complete a new
// match, and so on -- see sim.simulate/checkMatches) but resolved instantly
// rather than frame-by-frame. Weighted so a deeper chain always scores above
// an equally-sized single pop -- and by more than a merely-quadratic margin
// (chain_depth is *cubed*, not squared): a plain combo only ever grows
// linearly with how many blocks happen to be in one pass, so without a
// steeper-than-quadratic chain curve, several small unconnected matches can
// out-score a genuine 2-3 step chain of the same total size, and the engine
// ends up greedily grabbing whatever's immediately available instead of
// setting up the chain that's actually worth more. A combo (a single pass
// popping more than the 3-block minimum) adds on top of that -- see the
// module doc comment for the full rationale.
//
// Public (not just for cpu_ai's move search) so cpu_engine_garbage_test.zig
// can also use it to resolve a static grid to its final rest state --
// mutates `grid` in place to that final state, in addition to returning its
// score, so a test can just inspect the same pointer afterward.
pub fn simulateCascade(grid: *Grid) i32 {
    var total: i32 = 0;
    var chain_depth: i32 = 0;
    while (true) {
        garbage.settle(grid);
        const result = findAndClearMatches(grid);
        if (!result.any) break;
        chain_depth += 1;
        var pass_score = @as(i32, @intCast(result.real_count)) * BASE_WEIGHT * chain_depth * chain_depth * chain_depth;
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

pub const ScoredMove = struct { move: Move, value: i32 };

// Applies the swap to a copy, resolves its full cascade, and scores the
// result: the cascade's own points dominate (multiplied well above anything
// structuralScore could contribute, so a real pop always outranks a purely
// structural improvement), plus a discounted look at the *best* follow-up
// move available afterward (see LOOKAHEAD_DISCOUNT) for depth > 1 -- the
// "BFS" that lets a setup move (one that doesn't pop anything itself but
// creates a strong follow-up) still rank above a shallow immediate pop.
// Every extra ply compounds the same discount again (a depth-4 search's 3rd
// ply counts for 1/2, its 4th for 1/4, and so on), so a long, uncertain
// string of assumed-best replies naturally matters less than what's true
// right now -- exactly the taper a deeper search needs to stay trustworthy.
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

// How many of a ply's legal candidates get expanded a further ply deep once
// beyond the very first move (see bestSwapScored, which always weighs every
// legal candidate for the actual decision this turn -- only the *lookahead*
// below it is pruned). The branching factor (every legal swap, commonly
// 20-40 of them) makes an exhaustive search at depth 3+ multiply out fast;
// a good follow-up estimate doesn't need every branch explored, just the
// handful that already look most promising, so only those get a real,
// recursive evaluateMove call -- everything else keeps just its own
// immediate (non-recursive) value. This is what makes depth 3-4 affordable
// at roughly the cost the old exhaustive depth 2 used to be.
const BEAM_WIDTH: usize = 8;
const MAX_CANDIDATES = ROWS * (COLS - 1);

// The best achievable value starting from `grid`, searching `depth` moves
// deep -- see evaluateMove, which calls this for its own lookahead only
// (never the top-level decision itself). Every legal candidate gets scored
// by its own immediate value first (cheap: one cascade sim each, no
// recursion), then -- only if there's a further ply left to search -- the
// top BEAM_WIDTH of those (by that immediate value) are expanded with a
// real recursive lookahead of their own; the rest keep just their immediate
// value. For depth <= 1 this is exactly the old exhaustive search (nothing
// ever needs expanding further), so existing depth-1/2 behavior is
// unchanged -- pruning only starts changing anything from depth 3 on.
fn bestMoveValue(grid: *const Grid, depth: u8) ?i32 {
    var candidates: [MAX_CANDIDATES]ScoredMove = undefined;
    var n: usize = 0;
    for (0..ROWS) |r| {
        for (0..COLS - 1) |cl| {
            const row: u8 = @intCast(r);
            const col: u8 = @intCast(cl);
            if (!legalSwap(grid, row, col)) continue;
            const mv = Move{ .row = row, .col = col };
            candidates[n] = .{ .move = mv, .value = evaluateMove(grid.*, mv, 1) };
            n += 1;
        }
    }
    if (n == 0) return null;

    if (depth <= 1) {
        var best = candidates[0].value;
        for (candidates[1..n]) |cm| best = @max(best, cm.value);
        return best;
    }

    // Partial selection sort: bring the top `beam` candidates (by their own
    // immediate value) to the front -- cheap at this scale (n is at most
    // MAX_CANDIDATES), and the rest never need to be in order at all.
    const beam = @min(BEAM_WIDTH, n);
    for (0..beam) |i| {
        var max_idx = i;
        for (i + 1..n) |j| {
            if (candidates[j].value > candidates[max_idx].value) max_idx = j;
        }
        if (max_idx != i) std.mem.swap(ScoredMove, &candidates[i], &candidates[max_idx]);
    }

    var best: i32 = std.math.minInt(i32);
    for (candidates[0..beam]) |cm| {
        var g = grid.*;
        swap(&g, cm.move.row, cm.move.col);
        var v = cm.value; // already this move's own immediate value
        if (bestMoveValue(&g, depth - 1)) |follow| v += @divTrunc(follow, LOOKAHEAD_DISCOUNT);
        best = @max(best, v);
    }
    return best;
}

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

// How much the best available swap or raise must beat doing nothing by to
// actually be worth acting on -- small, on the order of a single adjacency-
// weight unit, just enough to absorb near-zero structural noise. Without
// this, a board with no genuinely good options left could still have the
// engine pick whichever swap scores a hair above another purely by
// structural jitter, then next turn pick the *reverse* swap for the same
// reason (undoing its own last move), oscillating forever between two
// moves that never actually accomplish anything -- see bestAction.
const NO_OP_EPSILON: i32 = 2;

pub const Action = union(enum) { swap: Move, raise, none };

// The engine's entry point (see cpu_ai.update): the best legal swap, a
// request to raise the stack instead, or neither -- whichever scores
// highest right now, judged against doing nothing at all (see
// NO_OP_EPSILON). A real match/chain (always worth several hundred points
// -- see simulateCascade/BASE_WEIGHT) will always beat both raising and
// doing nothing by a wide margin regardless of material, so this never
// passes up an actual win; raising only wins when there's no good swap AND
// material is genuinely short (see raiseValue), and `.none` only wins when
// neither meaningfully improves on the board as it already stands.
pub fn bestAction(grid: Grid, depth: u8) Action {
    const swap_result = bestSwapScored(grid, depth);
    const swap_value = if (swap_result) |r| r.value else std.math.minInt(i32);
    const raise_value = raiseValue(grid);
    const baseline = structuralScore(&grid);
    if (@max(swap_value, raise_value) <= baseline + NO_OP_EPSILON) return .none;
    if (raise_value > swap_value) return .raise;
    return .{ .swap = swap_result.?.move };
}
