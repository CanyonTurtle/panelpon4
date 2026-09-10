// The CPU engine's board snapshot, shared by cpu_engine.zig/cpu_engine_garbage.zig.
// Only covers the interactable window -- the hidden rising buffer row is out of scope.

const s = @import("state.zig");
const c = @import("constants.zig");

pub const ROWS: u8 = c.VISIBLE_ROWS;
pub const COLS: u8 = c.COLS;

pub const EMPTY: i8 = -1;
pub const GARBAGE: i8 = -2;

pub const Grid = struct {
    cell: [ROWS][COLS]i8 = [_][COLS]i8{[_]i8{EMPTY} ** COLS} ** ROWS,

    // `.falling`/`.landing`/`.swapping` read as real content (already decided);
    // `.popping`/`.recycling` read as EMPTY since they're still undecided.
    pub fn fromBoard(b: *s.Board) Grid {
        var g: Grid = .{};
        for (0..ROWS) |lr| {
            for (0..COLS) |col| {
                // lr is window-relative; add SPAWN_ROWS for the absolute row.
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
