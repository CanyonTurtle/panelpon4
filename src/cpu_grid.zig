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

    // Snapshots the currently-interactable window of a real board -- now
    // safe to call even while the board is busy (see cpu_ai.update, which no
    // longer waits for full idle before doing this): `.falling`/`.landing`/
    // `.swapping` all already have their final logical color/column decided
    // (a swap exchanges cell data immediately and only animates the visual
    // slide -- see sim.trySwap; falling/landing cells simply haven't
    // finished moving down *within their own column* yet), so they're read
    // as real content here, not holes. cpu_engine.simulateCascade's own
    // gravity pass (cpu_engine_garbage.settle) then naturally resolves a
    // still-falling cell down to wherever it will actually land as part of
    // ordinary evaluation -- no frame-by-frame simulation needed for this to
    // work. `.popping`/`.recycling` cells are read as EMPTY still: what they
    // become is genuinely undecided from here (a pop clears for good; a
    // recycling garbage cell may or may not convert), so treating that
    // uncertainty as a hole the AI might fall into is the honest default
    // rather than a real fix in scope here.
    pub fn fromBoard(b: *s.Board) Grid {
        var g: Grid = .{};
        for (0..ROWS) |lr| {
            for (0..COLS) |col| {
                // lr is relative to the visible window -- add SPAWN_ROWS to
                // reach the matching absolute logical row now that the board
                // has an offscreen staging area above the ceiling (see
                // Board.physRow).
                const cell = b.cellAt(@intCast(lr + c.SPAWN_ROWS), @intCast(col));
                const has_content = switch (cell.state) {
                    .normal, .falling, .landing, .swapping => true,
                    .empty, .popping, .recycling => false,
                };
                g.cell[lr][col] = if (!has_content)
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
