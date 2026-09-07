// Debug-only helpers for scripted testing: setting up exact board scenarios
// and reading back cell/chain state from outside the cart, for use by
// tools/wasm4-harness.js (screenshots, frame-by-frame scenario scripts).
// Every function takes a `board: u32` selector (0 = player, 1 = anything
// else = cpu) so a script can set up both sides of a vs-CPU scenario.
//
// These are plain `pub fn`s, not `export fn`s -- main.zig conditionally
// exports them as WASM exports only in Debug builds (see the comptime block
// there), so a release cart (`zig build --release=small`) never gains this
// surface and still exports only start/update.

const s = @import("state.zig");

fn boardFor(board: u32) *s.Board {
    return if (board == 0) &s.player else &s.cpu;
}

// callconv(.c) because @export (see main.zig) requires an explicit calling
// convention -- the same one `export fn` would pick implicitly.
pub fn clearBoard() callconv(.c) void {
    s.player = s.Board{};
    s.cpu = s.Board{ .rng_state = s.CPU_RNG_SEED };
    s.winner = .none;
}

pub fn setCell(board: u32, logical_row: u32, col: u32, color: u32, state: u32) callconv(.c) void {
    const cell = boardFor(board).cellAt(@intCast(logical_row), @intCast(col));
    cell.* = s.Cell{ .color = @intCast(color), .state = @enumFromInt(@as(u8, @intCast(state))) };
}

pub fn setCursor(board: u32, col: u32, row: u32) callconv(.c) void {
    const b = boardFor(board);
    b.cursor_col = @intCast(col);
    b.cursor_row = @intCast(row);
}

pub fn getChain(board: u32) callconv(.c) u32 {
    return boardFor(board).chain;
}

// Packed as state(8) | color(8) | chainable(1), least-significant byte first.
pub fn getCellInfo(board: u32, logical_row: u32, col: u32) callconv(.c) u32 {
    const cell = boardFor(board).cellAt(@intCast(logical_row), @intCast(col));
    var v: u32 = @intFromEnum(cell.state);
    v |= @as(u32, cell.color) << 8;
    v |= @as(u32, if (cell.chainable) 1 else 0) << 16;
    return v;
}

// state.Winner's ordinal (none=0, player=1, cpu=2, draw=3) -- lets a script
// confirm a vs-CPU match actually resolved, and which way, without having to
// infer it from rendered text.
pub fn getWinner() callconv(.c) u32 {
    return @intFromEnum(s.winner);
}
