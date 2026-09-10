// Move scoring/search for cpu_engine.zig: structural heuristic, beam-pruned
// lookahead, and the raise-vs-swap-vs-none decision. Reached via cpu_engine.zig's re-exports.

const std = @import("std");
const c = @import("constants.zig");
const grid_mod = @import("cpu_grid.zig");
const engine = @import("cpu_engine.zig");

const ROWS = grid_mod.ROWS;
const COLS = grid_mod.COLS;
const EMPTY = grid_mod.EMPTY;
const Grid = grid_mod.Grid;

// Discount on a follow-up's credited value (evaluateMove's lookahead), so
// the move that actually pops a chain still outranks the setup move.
const LOOKAHEAD_DISCOUNT: i32 = 2;

// Small relative to cpu_engine.BASE_WEIGHT so a real pop always beats a
// purely structural improvement, but enough to rank moves that don't pop.
const ADJACENCY_WEIGHT: i32 = 3;
const HEIGHT_WEIGHT: i32 = 2;

pub const Move = struct { row: u8, col: u8 };

// Guards horizontal adjacency (structuralScore) against wrapping from a
// row's last column into the next row's first.
const H_MASK: u128 = blk: {
    var m: u128 = 0;
    for (0..ROWS) |row| {
        for (0..COLS - 1) |col| m |= @as(u128, 1) << @intCast(row * COLS + col);
    }
    break :blk m;
};

// A column's height in rows -- 0 if empty, up to ROWS if full to the top.
// Shared by structuralScore's mild penalty and heightDangerPenalty's sharper one.
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

// Within DANGER_MARGIN rows of the top, every closer row counts steeply,
// on top of structuralScore's mild penalty (too weak alone, see raiseValue).
const DANGER_MARGIN: i32 = 3; // rows of headroom below which danger starts counting
// Deliberately much steeper than any other weight: topping out ends the game.
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

// Cascade score dominates over structuralScore; for depth > 1 adds a
// discounted look at the best follow-up, compounding LOOKAHEAD_DISCOUNT per ply.
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

// How many candidates get a further recursive ply (only the lookahead is
// pruned, never the top-level decision) -- keeps depth 3-4 affordable.
const BEAM_WIDTH: usize = 8;
const MAX_CANDIDATES = ROWS * (COLS - 1);

// Best achievable value from `grid`, used only for evaluateMove's own
// lookahead. Only the top BEAM_WIDTH candidates get a recursive ply deeper.
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

    // Partial selection sort: brings the top `beam` candidates to the
    // front; the rest never need to be in order.
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

// Best-scoring legal swap, searching `depth` moves deep, with its score
// (see bestAction). Null only if there's no legal swap at all.
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

// Just the swap, discarding its score -- see bestAction for swap-vs-raise.
pub fn bestMove(grid: Grid, depth: u8) ?Move {
    return if (bestSwapScored(grid, depth)) |r| r.move else null;
}

// The engine's "ammunition": real cells only. Garbage doesn't count -- a
// mostly-garbage board is just as short on material as an empty one.
fn realCellCount(grid: *const Grid) i32 {
    var n: i32 = 0;
    for (0..ROWS) |row| {
        for (0..COLS) |col| {
            if (grid.cell[row][col] >= 0) n += 1;
        }
    }
    return n;
}

// Below this, the board lacks material to reliably set up a match (5 rows' worth).
const LOW_MATERIAL_THRESHOLD: i32 = @as(i32, COLS) * 5;
const LOW_MATERIAL_WEIGHT: i32 = 4; // per real cell short of the threshold

// Raise's value scales up as material runs short, goes negative once
// plentiful, and is judged against the post-raise height, not current.
const PLENTY_OF_ROOM_MARGIN: i32 = DANGER_MARGIN + 2; // extra headroom required before raise_bias applies

pub fn raiseValue(grid: Grid) i32 {
    const shortfall = LOW_MATERIAL_THRESHOLD - realCellCount(&grid);
    var value = shortfall * LOW_MATERIAL_WEIGHT;
    const post_raise_height = maxColumnHeight(&grid) + 1;
    if (post_raise_height <= ROWS - PLENTY_OF_ROOM_MARGIN) value += engine.raise_bias;
    return value - heightDangerPenalty(post_raise_height);
}

// Margin the best swap/raise must beat doing nothing by -- without it, two
// moves scoring a hair apart on structural noise could oscillate forever.
const NO_OP_EPSILON: i32 = 2;

pub const Action = union(enum) { swap: Move, raise, none };

// The best swap, a raise request, or neither -- whichever scores highest
// against doing nothing (NO_OP_EPSILON). A real match always wins over both.
pub fn bestAction(grid: Grid, depth: u8) Action {
    const swap_result = bestSwapScored(grid, depth);
    const swap_value = if (swap_result) |r| r.value else std.math.minInt(i32);
    const raise_value = raiseValue(grid);
    const baseline = structuralScore(&grid);
    if (@max(swap_value, raise_value) <= baseline + NO_OP_EPSILON) return .none;
    if (raise_value > swap_value) return .raise;
    return .{ .swap = swap_result.?.move };
}
