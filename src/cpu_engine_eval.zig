// Move scoring and search for cpu_engine.zig: the structural heuristic, the
// beam-pruned lookahead search, and the raise-vs-swap-vs-none decision. Split
// out of cpu_engine.zig (which keeps grid ops and cascade resolution --
// legalSwap/swap/simulateCascade) to keep that file under the project's
// ~500-line-per-file guideline. Imports cpu_engine.zig back for
// Grid/legalSwap/swap/simulateCascade/chain_weight/raise_bias, so cpu_ai.zig
// and the test files keep reaching everything here through cpu_engine.zig's own
// re-exports (`engine.bestMove`, `engine.Action`, etc.) rather than needing
// to know about this split at all.

const std = @import("std");
const c = @import("constants.zig");
const grid_mod = @import("cpu_grid.zig");
const engine = @import("cpu_engine.zig");

const ROWS = grid_mod.ROWS;
const COLS = grid_mod.COLS;
const EMPTY = grid_mod.EMPTY;
const Grid = grid_mod.Grid;

// How much deeper each of a candidate move's own cascade/structural score is
// discounted when credited to the move that led into it -- see
// evaluateMove's lookahead. A follow-up chain is real value, but the move
// that actually pops it should still rank above the setup move when both are
// available this turn.
const LOOKAHEAD_DISCOUNT: i32 = 2;

// Structural heuristic weights (see structuralScore) -- small relative to
// cpu_engine.BASE_WEIGHT so an actual pop this turn always beats a purely
// structural improvement, but still enough to meaningfully rank moves that
// don't pop anything yet.
const ADJACENCY_WEIGHT: i32 = 3;
const HEIGHT_WEIGHT: i32 = 2;

pub const Move = struct { row: u8, col: u8 };

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
    engine.swap(&g, mv.row, mv.col);
    const cascade_score = engine.simulateCascade(&g);
    var value = cascade_score * engine.BASE_WEIGHT + structuralScore(&g);
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
            if (!engine.legalSwap(grid, row, col)) continue;
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
        engine.swap(&g, cm.move.row, cm.move.col);
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
            if (!engine.legalSwap(&grid, row, col)) continue;
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
//
// A raise's post-raise height needs at least this many more rows of
// headroom than heightDangerPenalty's own DANGER_MARGIN requires before
// raise_bias (see the module var's own doc comment) applies at all -- a
// noticeably stricter, safer gate than "not dangerous yet", so a CPU with a
// nonzero raise_bias only ever gets nudged toward raising while it's
// genuinely spacious, never anywhere near the point that penalty would
// otherwise start pulling it back down. Nothing here can ever let
// raise_bias itself push a raise into dangerous territory -- it simply
// stops applying well before that.
const PLENTY_OF_ROOM_MARGIN: i32 = DANGER_MARGIN + 2;

pub fn raiseValue(grid: Grid) i32 {
    const shortfall = LOW_MATERIAL_THRESHOLD - realCellCount(&grid);
    var value = shortfall * LOW_MATERIAL_WEIGHT;
    const post_raise_height = maxColumnHeight(&grid) + 1;
    if (post_raise_height <= ROWS - PLENTY_OF_ROOM_MARGIN) value += engine.raise_bias;
    return value - heightDangerPenalty(post_raise_height);
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
