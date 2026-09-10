// Rigid-body garbage gravity for the engine's Grid -- an instant port of
// sim_garbage.zig's updateGarbageGravity.

const std = @import("std");
const g = @import("cpu_grid.zig");

const ROWS = g.ROWS;
const COLS = g.COLS;
const EMPTY = g.EMPTY;
const GARBAGE = g.GARBAGE;
const Grid = g.Grid;

// Real cells settle per column in one shot; a garbage cell acts as a fixed
// obstacle splitting the column, and never moves here (see settleGarbageStep).
fn settleRealCells(grid: *Grid) bool {
    var moved = false;
    for (0..COLS) |col| {
        // Rest row within the segment being scanned; resets just above a
        // garbage cell every time one is hit (can't pass through it).
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

// True the instant any member is blocked by the floor or an outside cell --
// mirrors sim_garbage.zig's identically-named check.
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

// Flood-fills each clump fresh, shifts it down one row if unblocked. A
// later clump sees earlier moves applied -- only more conservative, never less.
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

// The engine's whole gravity step -- see the module doc comment for why
// this needs two sub-steps looped together rather than one.
pub fn settle(grid: *Grid) void {
    while (true) {
        const a = settleRealCells(grid);
        const b = settleGarbageStep(grid);
        if (!a and !b) break;
    }
}
