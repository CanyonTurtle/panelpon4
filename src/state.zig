// The game's model layer: the board grid, cursor, score/chain, and all other
// mutable global state, plus the small set of pure helpers (ring-buffer
// indexing, RNG, board-busy query) that only need that state and nothing
// else. Deliberately has no dependency on rendering, input, or wasm4 --
// everything here is plain data and logic, testable without a WASM4 host.

const c = @import("constants.zig");

pub const CellState = enum(u8) { empty, normal, falling, popping, landing, swapping };

pub const Cell = struct {
    color: u8 = 0,
    state: CellState = .empty,
    timer: i16 = 0,
    fall_off: i16 = 0, // pixels above true slot while falling
    swap_dir: i8 = 0, // -1, 0, +1: sign of the swap slide offset
    // While popping, `timer` drives this cell's own staggered visual
    // animation, but `pop_group_end` is the same value across every cell in
    // the match and only reaches 0 when the *last* one finishes. Cells are
    // only actually removed (freeing them for gravity) when pop_group_end
    // hits 0, so the pop animation is staggered but the logical disappearance
    // -- and the gravity it triggers -- happens for the whole match at once.
    pop_group_end: i16 = 0,
    // Marked true, all at once, on the whole contiguous stack of settled
    // blocks directly above a pop the instant it finishes clearing (see
    // sim.simulate) -- not tracked through gravity as things actually fall,
    // which only invites confusion from intermediate empty gaps a block
    // might pass through on its way down. It then simply rides along
    // whenever this cell's data is moved by gravity (a plain struct copy),
    // however many frames that takes. A match that includes a chainable
    // cell is a genuine chain continuation (something shifted because of an
    // earlier break); a match made of only ordinary settled blocks is not,
    // even if it happens while some unrelated cascade elsewhere is still
    // busy. Reverts to false the moment a block settles back to .normal
    // without being part of a match -- see sim.checkMatches.
    chainable: bool = false,
    // Set true (only ever alongside state = .popping) for every cell in a
    // match whose multiplier > 1 -- a genuine chain continuation, not just
    // the first pop of a fresh combo. render.zig reads it to render the
    // orange dithered flash instead of this cell's normal color while it
    // pops. Never propagated by gravity (popping cells are never subject to
    // it) and always reset by the time a fresh Cell{} replaces this one when
    // the pop clears, so it never leaks onto an unrelated cell.
    combo_flash: bool = false,
};

pub var grid: [c.ROWS][c.COLS]Cell = undefined;
pub var top: u8 = 0; // physical row index that logical row 0 currently maps to
pub var scroll_px: u32 = 0;
pub var rise_frame_counter: u32 = 0;
pub var rng_state: u32 = 0x9e3779b9;

pub var cursor_col: u8 = 2;
pub var cursor_row: u8 = c.VISIBLE_ROWS - 3;

pub var score: u32 = 0;
pub var chain: u8 = 0;

pub var game_over: bool = false;
pub var started: bool = false;

pub var frame_count: u32 = 0;
pub var prev_gamepad: u8 = 0;
pub var held_dir: u8 = 0;
pub var das_counter: u8 = 0;

// Touch/mouse state: a touch never teleports the cursor or swaps directly
// under the finger -- see input.updateTouch -- so all it needs to track is
// whether a press is ongoing and whether it has already spent its one swap.
// Touch gets its own held_dir/das_counter (distinct from the gamepad's above)
// so that a frame with no gamepad input doesn't reset touch's DAS timing,
// and vice versa -- each input method's "how long has this direction been
// held" state is independent.
pub var touch_active: bool = false;
pub var touch_swapped_this_press: bool = false;
pub var touch_held_dir: u8 = 0;
pub var touch_das_counter: u8 = 0;

// A floating "xN" + orange-dithered highlight that flashes over a chain
// match's location, then flies to the score display. Purely cosmetic --
// spawned by sim.checkMatches on a genuine chain (multiplier > 1), advanced
// once per frame by tickComboPopups (called from sim.simulate), and drawn by
// render.drawComboPopups. Nothing here affects gameplay, so none of it needs
// to be exact -- just cleared on reset like everything else.
pub const COMBO_POPUP_HOLD: i16 = 12; // frames flashing in place before flying
pub const COMBO_POPUP_FLY: i16 = 28; // frames spent flying to the score
pub const COMBO_POPUP_LIFETIME: i16 = COMBO_POPUP_HOLD + COMBO_POPUP_FLY;
const MAX_COMBO_POPUPS = 4;

pub const ComboPopup = struct {
    active: bool = false,
    multiplier: u8 = 0,
    x: i32 = 0,
    y: i32 = 0,
    w: i32 = 0,
    h: i32 = 0,
    elapsed: i16 = 0,
};

pub var combo_popups: [MAX_COMBO_POPUPS]ComboPopup = [_]ComboPopup{.{}} ** MAX_COMBO_POPUPS;

pub fn spawnComboPopup(multiplier: u8, x: i32, y: i32, w: i32, h: i32) void {
    for (&combo_popups) |*p| {
        if (!p.active) {
            p.* = .{ .active = true, .multiplier = multiplier, .x = x, .y = y, .w = w, .h = h, .elapsed = 0 };
            return;
        }
    }
    // Pool full -- would need 4+ simultaneous chain groups landing in the
    // same frame. Silently drop rather than crash; missing one flourish is
    // harmless.
}

pub fn tickComboPopups() void {
    for (&combo_popups) |*p| {
        if (!p.active) continue;
        p.elapsed += 1;
        if (p.elapsed >= COMBO_POPUP_LIFETIME) p.active = false;
    }
}

pub fn clearComboPopups() void {
    for (&combo_popups) |*p| p.* = .{};
}

pub fn rngNext() u32 {
    var x = rng_state;
    x ^= x << 13;
    x ^= x >> 17;
    x ^= x << 5;
    rng_state = x;
    return x;
}

pub fn randRange(n: u32) u32 {
    return rngNext() % n;
}

pub fn physRow(logical: u8) u8 {
    return @intCast((@as(u16, top) + @as(u16, logical)) % @as(u16, c.ROWS));
}

pub fn cellAt(logical_row: u8, col: u8) *Cell {
    return &grid[physRow(logical_row)][col];
}

pub fn boardBusy() bool {
    for (0..c.ROWS) |lr| {
        for (0..c.COLS) |col| {
            const s = cellAt(@intCast(lr), @intCast(col)).state;
            if (s == .falling or s == .popping or s == .landing or s == .swapping) return true;
        }
    }
    return false;
}

// Resets every piece of state this module owns to a fresh, empty board. Test
// fixtures across state.zig/board.zig/sim.zig call this before setting up
// their own scenario, so one test's leftover grid contents can't bleed into
// the next.
pub fn resetForTest() void {
    for (0..c.ROWS) |r| {
        for (0..c.COLS) |col| grid[r][col] = Cell{};
    }
    top = 0;
    scroll_px = 0;
    rise_frame_counter = 0;
    cursor_col = 2;
    cursor_row = c.VISIBLE_ROWS - 3;
    score = 0;
    chain = 0;
    game_over = false;
    clearComboPopups();
}

const testing = @import("std").testing;

test "physRow wraps around the ring buffer at ROWS" {
    resetForTest();
    top = c.ROWS - 1;
    try testing.expectEqual(@as(u8, c.ROWS - 1), physRow(0));
    try testing.expectEqual(@as(u8, 0), physRow(1));
    try testing.expectEqual(@as(u8, 1), physRow(2));
}

test "cellAt honors the current top offset" {
    resetForTest();
    top = 3;
    cellAt(0, 2).* = Cell{ .color = 4, .state = .normal };
    try testing.expectEqual(CellState.normal, grid[3][2].state);
    try testing.expectEqual(@as(u8, 4), grid[3][2].color);
}

test "boardBusy is false on an empty/settled board and true mid-animation" {
    resetForTest();
    try testing.expect(!boardBusy());
    cellAt(0, 0).state = .normal;
    try testing.expect(!boardBusy());
    cellAt(0, 0).state = .falling;
    try testing.expect(boardBusy());
}
