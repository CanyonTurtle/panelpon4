// The game's model layer: a `Board` struct holding everything one player's
// side of the match needs (grid, cursor, score/chain, rise state, its own
// RNG stream, and its own match-popup pool), plus the small set of methods
// (ring-buffer indexing, RNG, board-busy query) that only need that board's
// own data and nothing else. Deliberately has no dependency on rendering,
// input, or wasm4 -- everything here is plain data and logic, testable
// without a WASM4 host.
//
// There are exactly two boards in a match -- `player` and `cpu` below -- and
// every module that used to reach into a single implicit global board
// (sim.zig, sim_garbage.zig, board.zig) now takes an explicit `*Board`
// (often two: `self` and its `opponent`, since a big combo/chain routes
// garbage to the *other* board -- see sim.checkMatches) so the exact same
// code drives both sides.

const std = @import("std");
const c = @import("constants.zig");

// `recycling` is garbage's own analog of `popping` (see Cell.is_garbage) --
// kept as a distinct state, not reusing `popping`, so the two can never be
// confused: a `.popping` cell is a real matched block genuinely disappearing
// (flash + shrink); a `.recycling` cell is an inert garbage block on its way
// to becoming a fresh, inactive normal-looking block, with no animation of
// its own.
pub const CellState = enum(u8) { empty, normal, falling, popping, landing, swapping, recycling };

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
    // Garbage: an inert, colorless block dropped by a big combo/chain on the
    // *other* board (see sim.checkMatches' spawnGarbage -- vs-CPU garbage is
    // never self-inflicted, it always goes to the opponent). It's `.normal`
    // at rest -- and falls/lands exactly like any other block, via the same
    // gravity code, since is_garbage rides along through a plain struct
    // copy same as every other field -- but is never swappable and never
    // seeds or joins a color match on its own. It only ever leaves this
    // state by being *recycled*: a match adjacent to it (or to another
    // recycling garbage cell -- propagation chains transitively) triggers it
    // into .recycling too, sharing that group's pop_group_end with every
    // other member (garbage or real) in the same connected event. Unlike a
    // real match (which animates then clears to empty), a recycling garbage
    // cell has no animation of its own: it reveals its (already-picked)
    // color the instant its own staggered turn in the group arrives (see
    // render.drawRecyclingCell) and then just sits there looking like a
    // plain normal block -- inactive, unswappable, ineligible to match or
    // fall -- until the *whole* group finishes and every member becomes
    // fully active together (is_garbage reset to false, chainable granted --
    // see the shared .popping/.recycling branch in sim.simulate).
    is_garbage: bool = false,
};

// A small floating text badge (an orange-dithered block with black text)
// that appears at a chain-or-combo match's location, then flies to the score
// display. Purely cosmetic -- spawned by sim.checkMatches (text like "x2" or
// "5", pre-rendered into `label` there so this module and render.zig stay
// agnostic of what the text actually says), advanced once per frame by
// tickMatchPopups (called from sim.simulate), and drawn by
// render.drawMatchPopups. Nothing here affects gameplay, so none of it needs
// to be exact -- just cleared on reset like everything else.
//
// Three phases: it eases up just a couple pixels from the center of the
// match's topmost block (`x`/`y` below) to that block's own top edge
// (`edge_y`) -- a small hop meant to catch the eye right at the match, not
// travel anywhere -- then waits there until the match's own pop animation
// actually finishes (`pop_end`, in the same elapsed-frame timeline as this
// popup), then flies from there into the score display. See
// render.drawMatchPopups for the actual interpolation.
pub const MATCH_POPUP_RISE: i16 = 6; // frames easing up to the block's own top edge
pub const MATCH_POPUP_RISE_PX: i32 = 3; // how far up that is -- a couple pixels, not half a tile
pub const MATCH_POPUP_FLY: i16 = 28; // frames easing from that edge into the score
const MAX_MATCH_POPUPS = 4;
const MATCH_POPUP_LABEL_CAP = 16;

pub const MatchPopup = struct {
    active: bool = false,
    label: [MATCH_POPUP_LABEL_CAP]u8 = undefined,
    label_len: u8 = 0,
    x: i32 = 0, // badge center, at spawn -- see sim.checkMatches for how it's picked
    y: i32 = 0, // center of the match's topmost block, at spawn
    edge_y: i32 = 0, // a couple pixels above y -- the rise phase's target, and where it waits
    pop_end: i16 = 0, // elapsed frame (this popup's own timeline) the match's pop finishes; flight starts then
    elapsed: i16 = 0,
};

// One player's whole side of the match: the board grid, cursor, rise state,
// score/chain, its own independent RNG stream, and its own match-popup pool.
// Two instances of this (see `player`/`cpu` below) are driven through the
// exact same sim.zig/sim_garbage.zig/board.zig logic every frame -- the only
// asymmetry anywhere is *what drives the cursor* (real input for `player`,
// cpu_ai's random mover for `cpu` -- see main.zig) and *how it's rendered*
// (full detail at the normal board position for `player`, a simplified
// micro-scale view for `cpu` -- see render.zig).
pub const Board = struct {
    grid: [c.ROWS][c.COLS]Cell = std.mem.zeroes([c.ROWS][c.COLS]Cell),
    top: u8 = 0, // physical row index that logical row 0 currently maps to
    scroll_px: u32 = 0,
    rise_frame_counter: u32 = 0,
    rng_state: u32 = 0x9e3779b9,

    cursor_col: u8 = 2,
    cursor_row: u8 = c.VISIBLE_ROWS - 3,

    score: u32 = 0,
    chain: u8 = 0,
    game_over: bool = false,

    match_popups: [MAX_MATCH_POPUPS]MatchPopup = [_]MatchPopup{.{}} ** MAX_MATCH_POPUPS,

    pub fn rngNext(self: *Board) u32 {
        var x = self.rng_state;
        x ^= x << 13;
        x ^= x >> 17;
        x ^= x << 5;
        self.rng_state = x;
        return x;
    }

    pub fn randRange(self: *Board, n: u32) u32 {
        return self.rngNext() % n;
    }

    pub fn physRow(self: *const Board, logical: u8) u8 {
        return @intCast((@as(u16, self.top) + @as(u16, logical)) % @as(u16, c.ROWS));
    }

    pub fn cellAt(self: *Board, logical_row: u8, col: u8) *Cell {
        return &self.grid[self.physRow(logical_row)][col];
    }

    pub fn boardBusy(self: *Board) bool {
        for (0..c.ROWS) |lr| {
            for (0..c.COLS) |col| {
                const state = self.cellAt(@intCast(lr), @intCast(col)).state;
                if (state == .falling or state == .popping or state == .landing or state == .swapping or state == .recycling) return true;
            }
        }
        return false;
    }

    pub fn spawnMatchPopup(self: *Board, label: []const u8, x: i32, y: i32, edge_y: i32, pop_end: i16) void {
        for (&self.match_popups) |*p| {
            if (!p.active) {
                p.active = true;
                p.label_len = @intCast(@min(label.len, p.label.len));
                @memcpy(p.label[0..p.label_len], label[0..p.label_len]);
                p.x = x;
                p.y = y;
                p.edge_y = edge_y;
                p.pop_end = pop_end;
                p.elapsed = 0;
                return;
            }
        }
        // Pool full -- would need 4+ simultaneous chain/combo groups landing in
        // the same frame. Silently drop rather than crash; missing one flourish
        // is harmless.
    }

    pub fn tickMatchPopups(self: *Board) void {
        for (&self.match_popups) |*p| {
            if (!p.active) continue;
            p.elapsed += 1;
            if (p.elapsed >= p.pop_end + MATCH_POPUP_FLY) p.active = false;
        }
    }

    pub fn clearMatchPopups(self: *Board) void {
        for (&self.match_popups) |*p| p.* = .{};
    }
};

// Every seed but the player's own gets an arbitrary different starting
// value, purely so the two boards' random row generation/garbage colors/
// CPU move picks don't evolve in lockstep with each other from the same
// stream.
pub const CPU_RNG_SEED: u32 = 0x853c49e6;

pub var player: Board = .{};
pub var cpu: Board = .{ .rng_state = CPU_RNG_SEED };

// Who won the match once either board tops out (see board.doRise) -- both
// simultaneously (extremely unlikely, but possible if both boards top out
// on the exact same frame) is a draw. `.none` means the match is still in
// progress. See main.zig for where this gets set and drives the overall
// game-over screen (render.drawGameOver).
pub const Winner = enum { none, player, cpu, draw };
pub var winner: Winner = .none;

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
// held" state is independent. Only ever drives `player` -- the CPU has no
// real input (see cpu_ai.zig).
pub var touch_active: bool = false;
pub var touch_swapped_this_press: bool = false;
pub var touch_held_dir: u8 = 0;
pub var touch_das_counter: u8 = 0;

const testing = std.testing;

test "physRow wraps around the ring buffer at ROWS" {
    var b: Board = .{};
    b.top = c.ROWS - 1;
    try testing.expectEqual(@as(u8, c.ROWS - 1), b.physRow(0));
    try testing.expectEqual(@as(u8, 0), b.physRow(1));
    try testing.expectEqual(@as(u8, 1), b.physRow(2));
}

test "cellAt honors the current top offset" {
    var b: Board = .{};
    b.top = 3;
    b.cellAt(0, 2).* = Cell{ .color = 4, .state = .normal };
    try testing.expectEqual(CellState.normal, b.grid[3][2].state);
    try testing.expectEqual(@as(u8, 4), b.grid[3][2].color);
}

test "boardBusy is false on an empty/settled board and true mid-animation" {
    var b: Board = .{};
    try testing.expect(!b.boardBusy());
    b.cellAt(0, 0).state = .normal;
    try testing.expect(!b.boardBusy());
    b.cellAt(0, 0).state = .falling;
    try testing.expect(b.boardBusy());
}
