// The CPU's search engine: resolves a candidate swap to its end state in one shot, instead of reusing sim.zig's frame-by-frame animation.
// Split across cpu_grid.zig/cpu_engine_garbage.zig/cpu_engine_eval.zig, re-exported here as one `engine.X` API.

const std = @import("std");
const grid_mod = @import("cpu_grid.zig");
const garbage = @import("cpu_engine_garbage.zig");
const eval = @import("cpu_engine_eval.zig");

pub const Move = eval.Move;
pub const ScoredMove = eval.ScoredMove;
pub const Action = eval.Action;
pub const bestSwapScored = eval.bestSwapScored;
pub const bestMove = eval.bestMove;
pub const raiseValue = eval.raiseValue;
pub const bestAction = eval.bestAction;

const ROWS = grid_mod.ROWS;
const COLS = grid_mod.COLS;

pub const EMPTY = grid_mod.EMPTY;
pub const GARBAGE = grid_mod.GARBAGE;
pub const Grid = grid_mod.Grid;

// Weights for simulateCascade's score: a deeper chain always outweighs an
// equivalent single pop; garbage counts for less since it's already sent.
pub const BASE_WEIGHT: i32 = 10;
const GARBAGE_WEIGHT: i32 = 6;
const COMBO_WEIGHT: i32 = 8;

// Set by cpu_ai.configFor, global to keep the recursive search's signatures
// unchanged. Scales only the chain bonus -- 100 reproduces the original curve.
pub var chain_weight: i32 = 100;
// Nudges raiseValue up while there's comfortably more headroom than usual.
pub var raise_bias: i32 = 0;

fn swappable(v: i8) bool {
    return v == EMPTY or v >= 0;
}

// Mirrors sim.trySwap's guard, plus: same-color pairs excluded, since a
// true no-op can still outscore every option via a free lookahead credit.
pub fn legalSwap(grid: *const Grid, row: u8, col: u8) bool {
    const a = grid.cell[row][col];
    const b = grid.cell[row][col + 1];
    if (!swappable(a) or !swappable(b)) return false;
    if (a == b) return false;
    return true;
}

pub fn swap(grid: *Grid, row: u8, col: u8) void {
    const tmp = grid.cell[row][col];
    grid.cell[row][col] = grid.cell[row][col + 1];
    grid.cell[row][col + 1] = tmp;
}

const MatchResult = struct { real_count: u32 = 0, garbage_count: u32 = 0, any: bool = false };

// Finds every 3+ run, propagates into touching garbage, then clears to
// EMPTY -- the AI only cares the space is freed, not what it'd reveal.
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
                // Only a clump's bottom-most row per column converts per
                // event, mirroring sim_matches.zig's Cell.garbage_reveals rule.
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

// Repeatedly settles/clears until nothing falls into place. Chain score
// scales as depth^3 so a real chain always beats unconnected matches.
pub fn simulateCascade(grid: *Grid) i32 {
    var total: i32 = 0;
    var chain_depth: i32 = 0;
    while (true) {
        garbage.settle(grid);
        const result = findAndClearMatches(grid);
        if (!result.any) break;
        chain_depth += 1;
        const chain_cubed = chain_depth * chain_depth * chain_depth;
        const chain_bonus = @divTrunc((chain_cubed - 1) * chain_weight, 100);
        var pass_score = @as(i32, @intCast(result.real_count)) * BASE_WEIGHT * (1 + chain_bonus);
        pass_score += @as(i32, @intCast(result.garbage_count)) * GARBAGE_WEIGHT;
        if (result.real_count > 3) pass_score += @as(i32, @intCast(result.real_count - 3)) * COMBO_WEIGHT;
        total += pass_score;
    }
    return total;
}
