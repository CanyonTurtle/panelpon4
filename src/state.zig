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

// A small floating text badge (an orange-dithered block with black text)
// that appears at a chain-or-combo match's location, then flies to the score
// display. Purely cosmetic -- spawned by sim.checkMatches (text like "x2" or
// "5", pre-rendered into `label` there so this module and render.zig stay
// agnostic of what the text actually says), advanced once per frame by
// tickMatchPopups (called from sim.simulate), and drawn by
// render.drawMatchPopups. Nothing here affects gameplay, so none of it needs
// to be exact -- just cleared on reset like everything else.
//
// Three phases: it holds at the height of the match's topmost block (`x`/`y`
// below), then eases up to the top edge of the board, then eases (from
// there) into the score display -- see render.drawMatchPopups for the actual
// interpolation.
pub const MATCH_POPUP_HOLD: i16 = 12; // frames sitting at spawn height before rising
pub const MATCH_POPUP_RISE: i16 = 8; // frames easing up to the board's top edge
pub const MATCH_POPUP_FLY: i16 = 28; // frames easing from the top edge into the score
pub const MATCH_POPUP_LIFETIME: i16 = MATCH_POPUP_HOLD + MATCH_POPUP_RISE + MATCH_POPUP_FLY;
const MAX_MATCH_POPUPS = 4;
const MATCH_POPUP_LABEL_CAP = 16;

pub const MatchPopup = struct {
    active: bool = false,
    label: [MATCH_POPUP_LABEL_CAP]u8 = undefined,
    label_len: u8 = 0,
    x: i32 = 0, // badge center, at spawn -- see sim.checkMatches for how it's picked
    y: i32 = 0, // height of the match's topmost block, at spawn
    elapsed: i16 = 0,
};

pub var match_popups: [MAX_MATCH_POPUPS]MatchPopup = [_]MatchPopup{.{}} ** MAX_MATCH_POPUPS;

pub fn spawnMatchPopup(label: []const u8, x: i32, y: i32) void {
    for (&match_popups) |*p| {
        if (!p.active) {
            p.active = true;
            p.label_len = @intCast(@min(label.len, p.label.len));
            @memcpy(p.label[0..p.label_len], label[0..p.label_len]);
            p.x = x;
            p.y = y;
            p.elapsed = 0;
            return;
        }
    }
    // Pool full -- would need 4+ simultaneous chain/combo groups landing in
    // the same frame. Silently drop rather than crash; missing one flourish
    // is harmless.
}

pub fn tickMatchPopups() void {
    for (&match_popups) |*p| {
        if (!p.active) continue;
        p.elapsed += 1;
        if (p.elapsed >= MATCH_POPUP_LIFETIME) p.active = false;
    }
}

pub fn clearMatchPopups() void {
    for (&match_popups) |*p| p.* = .{};
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
    clearMatchPopups();
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
