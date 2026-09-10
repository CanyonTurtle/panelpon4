// Debug-only board-scenario helpers for tools/wasm4-harness.js -- plain `pub
// fn`s; main.zig exports them as WASM only in Debug builds.

const s = @import("state.zig");
const c = @import("constants.zig");
const tutorial = @import("tutorial.zig");
const characters = @import("characters.zig");
const main = @import("main.zig");

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

// Like setCell, but also marks the cell as garbage -- setCell alone can't,
// since Cell's is_garbage isn't one of its parameters.
pub fn setGarbageCell(board: u32, logical_row: u32, col: u32) callconv(.c) void {
    const cell = boardFor(board).cellAt(@intCast(logical_row), @intCast(col));
    cell.* = s.Cell{ .state = .normal, .is_garbage = true };
}

pub fn setCursor(board: u32, col: u32, row: u32) callconv(.c) void {
    const b = boardFor(board);
    b.cursor_col = @intCast(col);
    b.cursor_row = @intCast(row);
}

pub fn getChain(board: u32) callconv(.c) u32 {
    return boardFor(board).chain;
}

pub fn getScore(board: u32) callconv(.c) u32 {
    return boardFor(board).score;
}

// Packed as state(8) | color(8) | chainable(1) | is_garbage(1), least-
// significant byte first, then garbage_group(8) at bit 18.
pub fn getCellInfo(board: u32, logical_row: u32, col: u32) callconv(.c) u32 {
    const cell = boardFor(board).cellAt(@intCast(logical_row), @intCast(col));
    var v: u32 = @intFromEnum(cell.state);
    v |= @as(u32, cell.color) << 8;
    v |= @as(u32, if (cell.chainable) 1 else 0) << 16;
    v |= @as(u32, if (cell.is_garbage) 1 else 0) << 17;
    v |= @as(u32, cell.garbage_group) << 18;
    return v;
}

// state.Winner's ordinal -- lets a script confirm a match's outcome without
// reading rendered text.
pub fn getWinner() callconv(.c) u32 {
    return @intFromEnum(s.winner);
}

// Packed as col(8) | row(8), least-significant byte first.
pub fn getCursorPos(board: u32) callconv(.c) u32 {
    const b = boardFor(board);
    return @as(u32, b.cursor_col) | (@as(u32, b.cursor_row) << 8);
}

pub fn getScrollPx(board: u32) callconv(.c) u32 {
    return boardFor(board).scroll_px;
}

// Lets a script confirm the title screen's difficulty adjustment took effect
// without reading it back out of rendered pixels.
pub fn getDifficulty() callconv(.c) u32 {
    return s.difficulty;
}

// Bypasses the title screen's adjustment so a script can compare CPU levels
// without skewing the player's RNG via a different number of title frames.
pub fn setDifficulty(level: u32) callconv(.c) void {
    s.difficulty = @intCast(level);
}

pub fn getManualRaiseElapsed(board: u32) callconv(.c) u32 {
    return boardFor(board).manual_raise_elapsed;
}

pub fn getDangerTimer(board: u32) callconv(.c) u32 {
    return boardFor(board).danger_timer;
}

// Lets a script force a win/loss through the real update() branch (audio,
// closing wipe, story-flow transitions and all) instead of playing it out.
pub fn setGameOver(board: u32, over: u32) callconv(.c) void {
    boardFor(board).game_over = over != 0;
}

// Jumps straight to a tutorial step's own seeded fixture (state.TutorialStep's
// ordinal) instead of a script having to play every earlier step for real.
pub fn setTutorialStep(step: u32) callconv(.c) void {
    tutorial.beginStep(@enumFromInt(@as(u8, @intCast(step))));
}

// Jumps straight to any pre-game menu screen (state.MenuPhase's ordinal),
// via the same setMenuPhase every real navigation uses -- no title -> mode select -> ... click-through needed.
pub fn setMenuPhase(phase: u32) callconv(.c) void {
    s.started = false;
    const p: s.MenuPhase = @enumFromInt(@as(u8, @intCast(phase)));
    // Real navigation always seeds this before arriving here (setup_character's
    // confirm) -- a zero timer underflows the very next frame's decrement.
    if (p == .setup_cpu_reveal) s.cpu_reveal_timer = c.CPU_REVEAL_HOLD_BASE;
    main.setMenuPhase(p);
}

// Jumps straight to a mid-run story screen (state.StoryFlowStep's ordinal),
// seeding just enough state (a freed Mermaid) for it to render sensibly on its own.
pub fn setStoryFlowStep(step: u32) callconv(.c) void {
    s.started = true;
    s.game_mode = .story;
    s.player_character = characters.MERMAID_INDEX;
    s.story_select_cursor = characters.MERMAID_INDEX;
    s.story_party[characters.MERMAID_INDEX] = true;
    s.story_flow_step = @enumFromInt(@as(u8, @intCast(step)));
    s.story_flow_timer = 0;
}
