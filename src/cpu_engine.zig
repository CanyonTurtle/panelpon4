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
// The board snapshot (Grid) lives in the companion cpu_grid.zig, garbage's
// rigid-body gravity in cpu_engine_garbage.zig, and the move-scoring/search
// half (structuralScore, evaluateMove, and everything bestAction/bestMove
// build on) in cpu_engine_eval.zig -- all split out to keep this file under
// the project's ~500-line-per-file guideline. cpu_engine_eval.zig imports
// this file back for Grid/legalSwap/swap/simulateCascade/chain_weight and
// this file re-exports its public search API below, so callers (cpu_ai.zig,
// the test files) keep reaching everything through this one `engine.X`
// alias regardless of which file actually defines it -- cross-checked
// against the real sim.zig/sim_garbage.zig behavior in
// cpu_engine_garbage_test.zig.
//
// cpu_engine_eval.zig's structural heuristic uses a per-color bitboard (one
// u128 bitmask per color, bit index row*COLS+col), where shift+AND+popCount
// tricks are a natural, safe fit (vertical adjacency is a plain row-stride
// shift with no wraparound risk at all; horizontal adjacency is guarded
// against wrapping into the next row by its own H_MASK). Match detection/
// cascade resolution here (findAndClearMatches/cpu_engine_garbage.settle)
// stays plain nested-loop array logic instead, mirroring sim_matches.zig's
// own proven approach -- that logic determines whether the AI ever "sees" a
// winning move at all, so it's worth more to keep it simple and obviously
// correct than to also force it through bit tricks.

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

// Weights for simulateCascade's score -- chosen so a deeper chain always
// outweighs an equivalent-sized single pop (chain_depth is squared, per the
// user's ask to specifically value chain-building), a combo bigger than the
// 3-block minimum adds on top of that, and clearing garbage (freeing the
// board, denying the opponent nothing since it's already been sent) counts
// for a little less than an equivalent real pop.
pub const BASE_WEIGHT: i32 = 10;
const GARBAGE_WEIGHT: i32 = 6;
const COMBO_WEIGHT: i32 = 8;

// The current CPU's own tuning knobs -- set by cpu_ai.zig (see configFor)
// right before each decide call, read by simulateCascade below and by
// cpu_engine_eval.raiseValue (via this file's own `engine.chain_weight`/
// `engine.raise_bias`). Global rather than threaded as an extra parameter
// through every function in the search (bestMoveValue's own lookahead
// recurses into itself many times per decision) purely to keep those
// signatures unchanged; the
// defaults match the engine's original, undifferentiated full-strength
// behavior, so nothing that doesn't care about difficulty (existing tests
// included) needs to set either one.
//
// chain_weight scales only the chain-continuation *bonus* (see
// simulateCascade) -- 100 reproduces the original fixed chain_depth^3
// curve exactly; less makes a weaker CPU barely value a chain over an
// equivalent flat match (so it doesn't waste moves chasing a setup it's
// unlikely to capitalize on anyway), more makes a stronger one value one
// even further beyond that.
pub var chain_weight: i32 = 100;
// raise_bias nudges raiseValue's own value up a little while there's
// comfortably more headroom than usual (see raiseValue) -- a small
// preference for a strong CPU to keep building up material for a bigger
// combo instead of only ever raising out of material necessity.
pub var raise_bias: i32 = 0;

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
// an equally-sized single pop -- and, at full strength (chain_weight ==
// 100), by more than a merely-quadratic margin (the full curve is
// chain_depth *cubed*, not squared): a plain combo only ever grows linearly
// with how many blocks happen to be in one pass, so without a steeper-than-
// quadratic chain curve, several small unconnected matches can out-score a
// genuine 2-3 step chain of the same total size, and the engine ends up
// greedily grabbing whatever's immediately available instead of setting up
// the chain that's actually worth more. A combo (a single pass popping more
// than the 3-block minimum) adds on top of that -- see the module doc
// comment for the full rationale.
//
// Only the chain-continuation *bonus* above a flat match's own face value
// scales with chain_weight (see the module var's own doc comment) -- a
// first pass (chain_depth == 1, so chain_depth^3 == 1, no bonus at all) is
// always worth its full, undiscounted per-block value regardless of
// difficulty; a real block is worth what it's worth no matter who's
// playing. What varies is only how much *extra* a deeper chain is credited
// for setting up.
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
        const chain_cubed = chain_depth * chain_depth * chain_depth;
        const chain_bonus = @divTrunc((chain_cubed - 1) * chain_weight, 100);
        var pass_score = @as(i32, @intCast(result.real_count)) * BASE_WEIGHT * (1 + chain_bonus);
        pass_score += @as(i32, @intCast(result.garbage_count)) * GARBAGE_WEIGHT;
        if (result.real_count > 3) pass_score += @as(i32, @intCast(result.real_count - 3)) * COMBO_WEIGHT;
        total += pass_score;
    }
    return total;
}
