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
    // Counts down identically (no per-member offset) for every cell in a
    // pop/recycle group, so the whole group's pre-pop blink+pause preamble
    // (see PRE_POP_TOTAL_FRAMES) plays back in lockstep across every member
    // instead of staggered like `timer` above. `timer` itself doesn't start
    // counting down until this reaches 0 for the whole group (see
    // sim.simulate) -- so the existing staggered pop cascade proceeds
    // exactly as it did before this preamble existed, just uniformly
    // delayed for everyone.
    pre_pop_timer: i16 = 0,
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
    // cell has no animation of its own: if it's going to convert at all (see
    // garbage_reveals below), it reveals its (already-picked) color the
    // instant its own staggered turn in the group arrives (see
    // render.drawRecyclingCell) and then just sits there looking like a
    // plain normal block -- inactive, unswappable, ineligible to match or
    // fall -- until the *whole* group finishes and every converting member
    // becomes fully active together (is_garbage reset to false, chainable
    // granted -- see the shared .popping/.recycling branch in sim.simulate).
    is_garbage: bool = false,
    // Only meaningful while state == .recycling: whether this particular
    // garbage cell will actually convert to a real block once the group
    // resolves, as opposed to just flashing along with the rest of its
    // clump and then reverting to plain inert garbage. A garbage clump
    // taller than one row only ever converts its bottom-most (per column)
    // row per recycle event -- see sim.checkMatches, which sets this -- so
    // a tall clump peels off one row at a time across successive matches
    // rather than the whole thing cashing in at once. Reset to false again
    // once the group resolves (see sim.simulate), regardless of which way
    // it went.
    garbage_reveals: bool = false,
    // Which garbage *piece* this cell belongs to -- one persistent id per
    // combo/chain that spawned it (see sim_garbage.spawnGarbage, which
    // assigns a fresh one, and Board.next_garbage_group below), completely
    // independent of where the cell physically ends up or what it happens
    // to be touching. A match only pulls in a garbage piece if one of its
    // cells actually touches the match; from there the *whole* piece
    // (every cell sharing this id, wherever it is) comes along together --
    // never a *different* piece just because the two happen to be sitting
    // right next to each other (see sim_matches.checkMatches' propagation
    // pass, and Cell.garbage_reveals' own per-piece "only the bottom row"
    // rule, both keyed off this rather than transient spatial adjacency).
    // Meaningless once is_garbage is false.
    garbage_group: u8 = 0,
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

// A single pending garbage attack -- rows/width/anchor_col are exactly
// sim_garbage.spawnGarbage's own parameters, just not applied to the board
// yet. See sim_garbage.zig's queueChainGarbage/queueComboGarbage/
// resolveChainEnd/releaseIncomingGarbage for the full queueing lifecycle
// this and the two Board fields below exist for.
pub const GarbageAttack = struct { rows: u8 = 0, width: u8 = 0, anchor_col: u8 = 0 };

const MAX_INCOMING_GARBAGE = 8;

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
    // How many rows this board has ever consumed from the shared row
    // sequence since its own last reset (see shared_rows below) -- the
    // index into that sequence for whichever row this board generates next,
    // via board.writeNextRow. Resets to 0 along with everything else in
    // resetGame, so each fresh match starts both boards back at the same
    // index 0 (see board.resetSharedRows, called once per match alongside
    // resetGame for each board).
    rows_generated: u32 = 0,

    // Manual raise (the Z button -- see board.tryManualRaise/updateRise).
    // `manual_raise_elapsed` counts 1..MANUAL_RAISE_FRAMES while a manual
    // raise is in progress (0 = none active), finishing whatever fraction of
    // the current row is left (`manual_raise_start_scroll` is scroll_px at
    // the moment it was triggered) over that fixed duration regardless of
    // how much of the row was already risen -- so it always takes exactly
    // 1/3 second, never faster or slower depending on timing luck.
    // `manual_raise_cooldown` is a separate, simpler countdown that starts
    // the instant the button is pressed and blocks another manual raise
    // until it reaches 0, ticking down every frame regardless of whether
    // the board is busy (unlike the raise itself, which -- like the normal
    // automatic rise -- pauses while busy).
    manual_raise_elapsed: u32 = 0,
    manual_raise_start_scroll: u32 = 0,
    manual_raise_cooldown: u32 = 0,

    cursor_col: u8 = 2,
    cursor_row: u8 = c.VISIBLE_ROWS - 3,

    score: u32 = 0,
    chain: u8 = 0,
    // The size of the most recent combo (see sim_matches.checkMatches'
    // is_combo) -- unlike `chain`, a combo has no ongoing state of its own,
    // so this just holds the last one's size for COMBO_DISPLAY_FRAMES (see
    // render.drawPanel), ticked down once per frame in sim.simulate.
    // Meaningless once combo_display_timer reaches 0.
    combo_display: u8 = 0,
    combo_display_timer: u16 = 0,
    // Set (see sim_garbage.releaseIncomingGarbage) the instant a queued
    // attack actually lands on this board -- drives the character portrait's
    // "punish" reaction (see render_character.zig) for a little while
    // afterward, ticked down once per frame in sim.simulate exactly like
    // combo_display_timer above.
    garbage_punish_timer: u16 = 0,
    game_over: bool = false,
    // Counts consecutive idle frames spent with a block at or above the
    // ceiling -- see board.updateDangerTimer, which is what actually sets
    // game_over now (a rise reaching the top no longer ends the game by
    // itself; see board.doRise). Reset to 0 the instant either condition
    // stops holding, so a close call that gets cleared in time never
    // carries over into the next one.
    danger_timer: u32 = 0,

    // The next id sim_garbage.spawnGarbage will hand out (see
    // Cell.garbage_group) -- incremented (wrapping) once per spawn call, so
    // every cell placed by that ONE call shares an id no other piece has
    // recently used. Cyclical rather than ever-growing: a u8 is plenty of
    // distinct ids for any garbage piece actually still around waiting to
    // be recycled at once, and wrapping means it never needs anything
    // bigger than a single byte per board no matter how long a match runs.
    next_garbage_group: u8 = 0,

    // A chain still in progress on THIS board keeps overwriting this with
    // whatever the latest step's garbage would be (see
    // sim_garbage.queueChainGarbage) -- only the FINAL step's size survives
    // to actually send, once the chain concludes (see
    // sim_garbage.resolveChainEnd), never a sum of every step along the way.
    // A combo's own garbage has no such "wait for it to grow" concern (it's
    // already a single, complete event) and goes straight into the
    // *opponent's* incoming_garbage below instead.
    chain_pending_garbage: ?GarbageAttack = null,
    // Garbage attacks aimed at THIS board, waiting for it to go idle before
    // actually landing (see sim_garbage.releaseIncomingGarbage) -- so
    // garbage from either side never appears while a match or chain is
    // still resolving, on the sending board OR the receiving one.
    incoming_garbage: [MAX_INCOMING_GARBAGE]?GarbageAttack = [_]?GarbageAttack{null} ** MAX_INCOMING_GARBAGE,

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

    // Logical rows 0..SPAWN_ROWS-1 are a fixed, non-rotating garbage staging
    // area (see sim_garbage.spawnGarbage) -- they map straight through to the
    // same-numbered physical slots and are never touched by `top`. Logical
    // rows SPAWN_ROWS.. (the ceiling and everything below it, plus the hidden
    // rise buffer) are the actual rotating ring, exactly as the whole board
    // used to be before the spawn buffer existed -- `top` still just walks
    // 0..RING_SIZE-1 within that sub-window, unaffected by SPAWN_ROWS.
    pub fn physRow(self: *const Board, logical: u8) u8 {
        if (logical < c.SPAWN_ROWS) return logical;
        const rel: u16 = @as(u16, logical) - @as(u16, c.SPAWN_ROWS);
        const ring_phys: u16 = (@as(u16, self.top) + rel) % @as(u16, c.RING_SIZE);
        return c.SPAWN_ROWS + @as(u8, @intCast(ring_phys));
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
// value, purely so the two boards' garbage-reveal colors/CPU move picks
// don't evolve in lockstep with each other from the same stream (row
// generation no longer comes from either of these -- see shared_rows below).
pub const CPU_RNG_SEED: u32 = 0x853c49e6;

pub var player: Board = .{};
pub var cpu: Board = .{ .rng_state = CPU_RNG_SEED };

// The shared row sequence both boards' rising rows are drawn from (see
// board.rowForIndex) -- "predetermined at match start" and "the same for
// both players per row" in practice: whichever board first reaches a given
// row index (Board.rows_generated) generates and caches it here; the other
// board just replays that exact result once it reaches the same index,
// however much later. Deliberately keyed purely by index, never by either
// board's own actual stack content, since that's exactly what would make
// the two boards' sequences diverge and defeat the point -- see
// board.pickRowColors, which avoids an accidental run of 3 against the
// previous two rows *in this sequence*, not whatever's really on a board.
//
// A fixed-size ring rather than something unbounded: `shared_rows_count`
// only ever grows, but a lookup wraps via `% SHARED_ROW_CACHE`, so a board
// that somehow fell more than a full cache's worth of rows behind the other
// would start reading overwritten (stale) entries -- 512 rows is roughly
// 6-7 minutes of continuous rising even at the fastest pace (see
// board.riseSpeedFramesPerPixel's floor), comfortably past how long a real
// match actually runs before someone's board tops out, so this is treated
// as effectively unbounded in practice rather than engineered against.
pub const SHARED_ROW_CACHE: u32 = 512;
pub var shared_row_rng_state: u32 = 0x2545f491;
pub var shared_rows: [SHARED_ROW_CACHE][c.COLS]u8 = undefined;
// How many rows of the shared sequence have been generated so far, across
// the whole session -- NOT reset by resetGame (which runs once per board,
// and resetting this from there would corrupt the cache for whichever
// board resets second); see board.resetSharedRows, called once per match
// instead. shared_row_rng_state itself is never reseeded at all, mirroring
// each board's own rng_state -- it just keeps evolving continuously across
// the whole session/every rematch, so consecutive rematches still see a
// different sequence rather than literally the same one every time.
pub var shared_rows_count: u32 = 0;

// Who won the match once either board tops out (see board.updateDangerTimer) -- both
// simultaneously (extremely unlikely, but possible if both boards top out
// on the exact same frame) is a draw. `.none` means the match is still in
// progress. See main.zig for where this gets set and drives the overall
// game-over screen (render.drawGameOver).
pub const Winner = enum { none, player, cpu, draw };
pub var winner: Winner = .none;

// Best-of-N match points (see constants.POINTS_TO_WIN and
// board.awardMatchPoint, the only place these change): a draw awards no
// point to either side. `set_winner` is set the instant either side reaches
// POINTS_TO_WIN and drives main.zig's choice between "next match, same
// series" (press X -> board.beginCountdown, points untouched) and "series
// decided" (press X -> back to the title screen, points reset) -- see
// render.drawGameOver for the two different overlays this produces.
pub var player_points: u8 = 0;
pub var cpu_points: u8 = 0;
pub var set_winner: Winner = .none;

pub var started: bool = false;

// Which of the two pre-game screens is showing while `!started` and no
// countdown is active -- see main.zig. `title` is the branded splash
// ("PRESS X" to continue); `setup` is where the CPU difficulty is actually
// adjusted before a series begins. Reset to `.title` only when a full
// series concludes (see set_winner above) -- mid-series, pressing X on a
// match's own game-over screen skips straight back into a countdown, never
// back through either menu screen.
pub const MenuPhase = enum { title, setup };
pub var menu_phase: MenuPhase = .title;

// A brief "3 2 1 START" overlay shown once per match, right after both
// boards (and the shared row cache) reset but before real simulation
// begins -- see board.beginCountdown (the only way this ever gets set) and
// main.zig, which freezes input/simulation and just renders the
// already-reset boards underneath it while this counts down to 0.
// render.drawCountdown turns the remaining count back into "which stage
// (3/2/1/START), how far into it".
pub var countdown_timer: i32 = 0;

// Ticks down in main.zig once `winner` leaves .none, before drawGameOver
// actually shows the match-over/winner overlay -- a purely cosmetic
// top-to-bottom wipe (render.drawBoard/render_cpu.drawMicroBoard just skip
// drawing already-"popped" rows; nothing here ever touches either Board's
// actual grid) so a loss reads as one final cascade rather than an instant
// cut to the overlay.
pub var closing_timer: i32 = 0;

// The CPU's difficulty, 1-10 -- set on the title screen (see main.zig) and
// then fixed for the rest of the session (there's no menu to revisit it
// mid-match or between replays). Levels 1-4 are cpu_ai's original random
// flipper at increasing speed; 5-10 hand off to cpu_engine's actual move
// search instead, at increasing strength -- see cpu_ai.configFor.
pub var difficulty: u8 = 1;

// Which of characters.ALL each side is playing as -- set on the setup
// screen (see main.zig); the CPU's is always recomputed to differ from the
// player's own pick whenever that changes (see characters.cpuPickFor).
// Drives both sides' main-frame theming and in-game portrait (see
// render.drawFrame/render_character.zig).
pub var player_character: u8 = 0;
pub var cpu_character: u8 = 1;

pub var frame_count: u32 = 0;
pub var prev_gamepad: u8 = 0;
pub var held_dir: u8 = 0;
pub var das_counter: u8 = 0;

// Frames since the player's own cursor last actually moved (see
// input.moveCursor/applyPendingTouchSwipe, the only places that reset this
// to 0) -- render.drawCursor uses it (instead of raw frame_count) to drive
// the idle blink, so the cursor snaps back to its small, settled outline the
// instant it moves and only starts blinking again once it's been sitting
// still for a while -- a fast-playing player never sees it blink at all.
pub var cursor_idle_frames: u32 = 0;

// Counts down from a few frames the instant a swap actually goes through
// (see input.updateSwap/applyPendingTouchSwipe) -- render.drawCursor adds an
// extra contraction on top of the ordinary blink while this is nonzero, a
// quick, deliberate "click" of feedback distinct from the idle pulse.
pub var cursor_swap_flash: u8 = 0;

// One-deep input buffering for the swap button (X), mirroring touch's own
// buffering (see touch_pending_dir below): a press that lands while the
// cursor's current pair can't swap yet (e.g. still mid-animation from the
// *previous* swap) is remembered here instead of silently dropped, and
// applied automatically the instant it becomes possible -- see
// input.updateSwap. Only one press is ever remembered; pressing again while
// one is already pending changes nothing (there's nothing more to buffer).
pub var button_pending_swap: bool = false;

// True whenever touch is the active input method (see input.updateTouch) --
// hides the player's cursor (render.drawCursor) until a gamepad button
// brings it back (see main.zig). Touch aims directly at the block it
// touches down on (see touch_anchor_col/row below) rather than needing to
// see where a separate cursor currently sits, so there's nothing on-screen
// the player needs the cursor visible for while using it.
pub var cursor_hidden: bool = false;

// Touch/mouse state: swipe-only (see input.updateTouch) -- a tap or hold
// with no meaningful drag does nothing at all. Touching down picks a target
// cell directly from the touch's on-board position (`touch_anchor_col/row`);
// swiping left/right then swaps that cell with its neighbor in that
// direction (moving the anchor along with it, so a continued drag in the
// same direction keeps swapping the same physical block further across the
// board), and swiping up/down retargets to the row above/below instead
// (there's no vertical swap to perform -- blocks only ever swap
// horizontally). Starting a new touch elsewhere re-anchors to that new
// location, abandoning whatever the previous touch was doing.
//
// `touch_swipe_origin_x/y` is where the *current* swipe-detection window
// started measuring from -- reset on every new press and every time a drag
// crosses the swipe threshold in some direction (so one long continuous
// drag chains multiple swipes instead of requiring separate lift-and-touch
// gestures each time). `touch_pending_dir` implements one-deep input
// buffering: a swipe detected while the target cell can't swap yet (e.g.
// still mid-animation from the *previous* swap) is remembered -- only the
// most recent one, a newer swipe always overwrites an older still-pending
// one rather than queuing both -- and retried every frame until it
// succeeds, so a fast continuous drag chains swaps at the fastest rate the
// swap animation allows, with none silently dropped. A vertical (retarget)
// request has no such waiting condition, so it always resolves the same
// frame it's queued. Only ever drives `player` -- the CPU has no real input
// (see cpu_ai.zig).
pub var touch_active: bool = false;
pub var touch_anchor_col: u8 = 0;
pub var touch_anchor_row: u8 = 0;
pub var touch_swipe_origin_x: i32 = 0;
pub var touch_swipe_origin_y: i32 = 0;
pub var touch_pending_dir: u8 = 0;

const testing = std.testing;

test "physRow: spawn buffer rows map straight through, ignoring top" {
    var b: Board = .{};
    b.top = 5;
    try testing.expectEqual(@as(u8, 0), b.physRow(0));
    try testing.expectEqual(@as(u8, c.SPAWN_ROWS - 1), b.physRow(c.SPAWN_ROWS - 1));
}

test "physRow wraps around the rotating window at RING_SIZE" {
    var b: Board = .{};
    b.top = c.RING_SIZE - 1;
    try testing.expectEqual(@as(u8, c.SPAWN_ROWS + c.RING_SIZE - 1), b.physRow(c.SPAWN_ROWS));
    try testing.expectEqual(@as(u8, c.SPAWN_ROWS), b.physRow(c.SPAWN_ROWS + 1));
    try testing.expectEqual(@as(u8, c.SPAWN_ROWS + 1), b.physRow(c.SPAWN_ROWS + 2));
}

test "cellAt honors the current top offset, within the rotating window" {
    var b: Board = .{};
    b.top = 3;
    b.cellAt(c.SPAWN_ROWS, 2).* = Cell{ .color = 4, .state = .normal };
    try testing.expectEqual(CellState.normal, b.grid[c.SPAWN_ROWS + 3][2].state);
    try testing.expectEqual(@as(u8, 4), b.grid[c.SPAWN_ROWS + 3][2].color);
}

test "boardBusy is false on an empty/settled board and true mid-animation" {
    var b: Board = .{};
    try testing.expect(!b.boardBusy());
    b.cellAt(0, 0).state = .normal;
    try testing.expect(!b.boardBusy());
    b.cellAt(0, 0).state = .falling;
    try testing.expect(b.boardBusy());
}
