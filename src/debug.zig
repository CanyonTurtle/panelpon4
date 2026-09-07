// Debug-only helpers for scripted testing: setting up exact board scenarios
// and reading back cell/chain state from outside the cart, for use by
// tools/wasm4-harness.js (screenshots, frame-by-frame scenario scripts).
//
// These are plain `pub fn`s, not `export fn`s -- main.zig conditionally
// exports them as WASM exports only in Debug builds (see the comptime block
// there), so a release cart (`zig build --release=small`) never gains this
// surface and still exports only start/update.

const c = @import("constants.zig");
const s = @import("state.zig");
const board = @import("board.zig");

// callconv(.c) because @export (see main.zig) requires an explicit calling
// convention -- the same one `export fn` would pick implicitly.
pub fn clearBoard() callconv(.c) void {
    board.resetGame();
    for (0..c.ROWS) |r| {
        for (0..c.COLS) |col| s.grid[r][col] = s.Cell{};
    }
    s.score = 0;
    s.chain = 0;
}

pub fn setCell(logical_row: u32, col: u32, color: u32, state: u32) callconv(.c) void {
    const cell = s.cellAt(@intCast(logical_row), @intCast(col));
    cell.* = s.Cell{ .color = @intCast(color), .state = @enumFromInt(@as(u8, @intCast(state))) };
}

pub fn setCursor(col: u32, row: u32) callconv(.c) void {
    s.cursor_col = @intCast(col);
    s.cursor_row = @intCast(row);
}

pub fn getChain() callconv(.c) u32 {
    return s.chain;
}

// Packed as state(8) | color(8) | chainable(1), least-significant byte first.
pub fn getCellInfo(logical_row: u32, col: u32) callconv(.c) u32 {
    const cell = s.cellAt(@intCast(logical_row), @intCast(col));
    var v: u32 = @intFromEnum(cell.state);
    v |= @as(u32, cell.color) << 8;
    v |= @as(u32, if (cell.chainable) 1 else 0) << 16;
    return v;
}
