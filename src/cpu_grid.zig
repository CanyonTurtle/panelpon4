// The CPU engine's simplified board snapshot -- shared between cpu_engine.zig
// (move search/scoring) and cpu_engine_garbage.zig (rigid-body garbage
// physics), split into its own file purely so those two can each depend on
// it without depending on each other (mirroring state.zig's role as the
// shared foundation under sim.zig/sim_garbage.zig/sim_matches.zig).
//
// Only reasons about the currently-interactable VISIBLE_ROWS x COLS window
// (matching the cursor's own legal range -- see input.moveCursor) -- the
// hidden extra ring-buffer row still rising in is deliberately out of scope,
// same as it is for the player's own cursor.

const s = @import("state.zig");
const c = @import("constants.zig");

pub const ROWS: u8 = c.VISIBLE_ROWS;
pub const COLS: u8 = c.COLS;

pub const EMPTY: i8 = -1;
pub const GARBAGE: i8 = -2;

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
                // lr is relative to the visible window -- add SPAWN_ROWS to
                // reach the matching absolute logical row now that the board
                // has an offscreen staging area above the ceiling (see
                // Board.physRow).
                const cell = b.cellAt(@intCast(lr + c.SPAWN_ROWS), @intCast(col));
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
