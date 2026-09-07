// Rigid-body garbage gravity for the CPU engine's simplified Grid -- a port
// of sim_garbage.zig's updateGarbageGravity into the engine's instant,
// no-animation model, split into its own file to keep cpu_engine.zig under
// the project's ~500-line-per-file guideline (mirroring the
// sim.zig/sim_garbage.zig split this is itself modeled on).
//
// The real game's garbage falls and lands as one connected rigid body, not
// independently per cell like an ordinary block (see state.Cell.is_garbage):
// a piece touching down anywhere in a connected clump stops the *whole*
// clump at once, so a wide slab resting unevenly across towers of different
// heights settles at the height dictated by its *tallest* support, not each
// column sinking to its own natural rest depth. The engine's own Grid used
// to ignore this entirely (see git history) and just dropped every occupied
// cell -- garbage included -- straight down per column like a normal block,
// which meant it couldn't reason correctly about a garbage slab propped up
// by uneven towers, or about what's left once a match breaks a chunk out of
// one (the remaining pieces need to be free to fall apart independently,
// exactly as connectivity recomputed fresh each step already provides for).
//
// settle() is the engine's whole gravity step (replacing the old
// applyGravity in cpu_engine.zig): real (non-garbage) cells still resolve in
// one shot per column, since they have no rigid-body constraint of their
// own and garbage simply acts as a fixed obstacle for that sub-step: but
// garbage bodies advance at most one row per call here, with connectivity
// recomputed fresh every time (mirroring sim_garbage.zig's own "connectivity
// recomputed fresh every frame" approach, so a body that merges with a
// neighbor mid-fall, or gets split by a match eating into it, is picked up
// correctly on the very next call) -- so settle() loops both sub-steps
// together until a full pass produces no more movement, converging to the
// same instant-rest configuration the real frame-by-frame process would
// eventually reach, without needing to actually simulate any frames.

const std = @import("std");
const g = @import("cpu_grid.zig");

const ROWS = g.ROWS;
const COLS = g.COLS;
const EMPTY = g.EMPTY;
const GARBAGE = g.GARBAGE;
const Grid = g.Grid;

// Real (non-garbage) cells settle per column in one shot, exactly like the
// old applyGravity, except a garbage cell now acts as a fixed obstacle that
// splits the column into independent segments instead of just being another
// value to pack along with everything else -- it does not move here at all
// (see settleGarbageStep below for how it moves). Returns whether anything
// actually moved, so settle() knows when to stop looping.
fn settleRealCells(grid: *Grid) bool {
    var moved = false;
    for (0..COLS) |col| {
        // The next row a falling real cell would come to rest in within the
        // segment currently being scanned -- reset to just above a garbage
        // cell every time one is hit, since real cells can never pass
        // through or displace one.
        var write_row: i32 = @as(i32, ROWS) - 1;
        var row: i32 = @as(i32, ROWS) - 1;
        while (row >= 0) : (row -= 1) {
            const v = grid.cell[@intCast(row)][col];
            if (v == GARBAGE) {
                write_row = row - 1;
                continue;
            }
            if (v == EMPTY) continue;
            if (row != write_row) {
                grid.cell[@intCast(write_row)][col] = v;
                grid.cell[@intCast(row)][col] = EMPTY;
                moved = true;
            }
            write_row -= 1;
        }
    }
    return moved;
}

fn isMember(members: []const [2]u8, r: u8, col: u8) bool {
    for (members) |pos| {
        if (pos[0] == r and pos[1] == col) return true;
    }
    return false;
}

// True the instant any member is blocked from advancing one more row -- by
// the board's floor, or by an occupied cell outside this same body -- since
// the whole connected clump moves together (see sim_garbage.zig's own
// identically-named check, which this mirrors exactly).
fn blocked(grid: *const Grid, members: []const [2]u8) bool {
    for (members) |pos| {
        const r = pos[0];
        const col = pos[1];
        if (r + 1 >= ROWS) return true;
        if (isMember(members, r + 1, col)) continue;
        if (grid.cell[r + 1][col] != EMPTY) return true;
    }
    return false;
}

// One rigid-body step for every connected garbage clump on the board:
// flood-fills each one fresh (4-connectivity, same technique as
// sim_matches.zig's own match grouping), and shifts it down by exactly one
// row if nothing blocks it. Bodies are found and moved one at a time in a
// single left-to-right, top-to-bottom sweep, so a clump discovered later in
// the same call already reflects any earlier clump's move this step --
// harmless (it only ever makes a later clump's own blocked-check more
// conservative, never less), and avoids needing a second pass to react to
// it. Returns whether anything moved.
fn settleGarbageStep(grid: *Grid) bool {
    var visited: [ROWS][COLS]bool = std.mem.zeroes([ROWS][COLS]bool);
    var stack: [ROWS * COLS][2]u8 = undefined;
    var members: [ROWS * COLS][2]u8 = undefined;
    var moved = false;

    for (0..ROWS) |lr0| {
        for (0..COLS) |col0| {
            if (visited[lr0][col0]) continue;
            visited[lr0][col0] = true;
            if (grid.cell[lr0][col0] != GARBAGE) continue;

            var stack_len: usize = 1;
            stack[0] = .{ @intCast(lr0), @intCast(col0) };
            var member_count: usize = 0;
            while (stack_len > 0) {
                stack_len -= 1;
                const pos = stack[stack_len];
                members[member_count] = pos;
                member_count += 1;
                const r = pos[0];
                const col = pos[1];

                if (r > 0 and !visited[r - 1][col]) {
                    visited[r - 1][col] = true;
                    if (grid.cell[r - 1][col] == GARBAGE) {
                        stack[stack_len] = .{ r - 1, col };
                        stack_len += 1;
                    }
                }
                if (r + 1 < ROWS and !visited[r + 1][col]) {
                    visited[r + 1][col] = true;
                    if (grid.cell[r + 1][col] == GARBAGE) {
                        stack[stack_len] = .{ r + 1, col };
                        stack_len += 1;
                    }
                }
                if (col > 0 and !visited[r][col - 1]) {
                    visited[r][col - 1] = true;
                    if (grid.cell[r][col - 1] == GARBAGE) {
                        stack[stack_len] = .{ r, col - 1 };
                        stack_len += 1;
                    }
                }
                if (col + 1 < COLS and !visited[r][col + 1]) {
                    visited[r][col + 1] = true;
                    if (grid.cell[r][col + 1] == GARBAGE) {
                        stack[stack_len] = .{ r, col + 1 };
                        stack_len += 1;
                    }
                }
            }
            const body = members[0..member_count];
            if (blocked(grid, body)) continue;

            // Bottom-most rows first, so shifting one member down never
            // overwrites another not-yet-moved member of the same body.
            var oi: usize = 1;
            while (oi < member_count) : (oi += 1) {
                const key = members[oi];
                var oj: usize = oi;
                while (oj > 0 and members[oj - 1][0] < key[0]) {
                    members[oj] = members[oj - 1];
                    oj -= 1;
                }
                members[oj] = key;
            }
            for (body) |pos| {
                grid.cell[pos[0] + 1][pos[1]] = grid.cell[pos[0]][pos[1]];
                grid.cell[pos[0]][pos[1]] = EMPTY;
            }
            moved = true;
        }
    }
    return moved;
}

// The engine's whole gravity step, replacing the old (per-cell, garbage-
// unaware) applyGravity -- see the module doc comment for why this needs
// two different sub-steps looped together rather than one.
pub fn settle(grid: *Grid) void {
    while (true) {
        const a = settleRealCells(grid);
        const b = settleGarbageStep(grid);
        if (!a and !b) break;
    }
}
