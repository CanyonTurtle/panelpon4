// The game's model layer: `Board` holds one player's side of the match (grid, cursor, score, rise, RNG) -- pure data/logic, no render/input/wasm4 deps, testable without a WASM4 host.
// `player`/`cpu` below are the two instances every module takes as an explicit `*Board`, rather than reaching into one implicit global board.

const std = @import("std");
const c = @import("constants.zig");
const fx = @import("state_fx.zig");
const characters = @import("characters.zig");

// `recycling` is garbage's own analog of `popping` (see Cell.is_garbage),
// kept distinct so a real matched block never gets confused with an inert garbage block converting in place.
pub const CellState = enum(u8) { empty, normal, falling, popping, landing, swapping, recycling };

pub const Cell = struct {
    color: u8 = 0,
    state: CellState = .empty,
    timer: i16 = 0,
    fall_off: i16 = 0, // pixels above true slot while falling
    swap_dir: i8 = 0, // -1, 0, +1: sign of the swap slide offset
    // `timer` staggers this cell's own pop animation, but removal (and the
    // gravity it triggers) waits for the whole group's pop_group_end to hit 0.
    pop_group_end: i16 = 0,
    // Counts down in lockstep (no per-member offset) across a whole pop/
    // recycle group's blink+pause preamble; `timer` above only starts staggering once this hits 0 for the group (see sim.simulate).
    pre_pop_timer: i16 = 0,
    // Marked true on the settled stack above a pop the instant it clears (see
    // sim.simulate), then rides along through gravity copies; a match including a chainable cell is a genuine chain continuation. Reverts to false once a block settles without being part of a match.
    chainable: bool = false,
    // An inert, colorless block dropped on the *other* board by a big
    // combo/chain (see sim.checkMatches' spawnGarbage); falls/lands like any other block but is never swappable or match-eligible until a match adjacent to it (or another recycling cell, transitively) triggers it into .recycling -- see garbage_reveals below and sim.simulate.
    is_garbage: bool = false,
    // Meaningful only while .recycling: whether this cell converts once the
    // group resolves. Only a clump's bottom row per column converts per event.
    garbage_reveals: bool = false,
    // One persistent id per spawn -- a whole piece moves/converts together
    // regardless of spatial adjacency to other pieces.
    garbage_group: u8 = 0,
};

// A pending garbage attack -- mirrors sim_garbage.spawnGarbage's own params,
// not yet applied. See sim_garbage.zig's queueing lifecycle functions.
pub const GarbageAttack = struct { rows: u8 = 0, width: u8 = 0, anchor_col: u8 = 0 };

const MAX_INCOMING_GARBAGE = 8;

// One player's whole side of the match. `player`/`cpu` (below) run the exact
// same logic every frame -- the only asymmetry is input source and render style.
pub const Board = struct {
    grid: [c.ROWS][c.COLS]Cell = std.mem.zeroes([c.ROWS][c.COLS]Cell),
    top: u8 = 0, // physical row index that logical row 0 currently maps to
    scroll_px: u32 = 0,
    rise_frame_counter: u32 = 0,
    rng_state: u32 = 0x9e3779b9,
    // Index into the shared row sequence (board.writeNextRow). Resets to 0
    // in resetGame, so each fresh match starts both boards at the same index.
    rows_generated: u32 = 0,

    // Manual raise (Z button): always finishes in exactly MANUAL_RAISE_FRAMES;
    // cooldown ticks every frame even while busy, unlike the raise itself.
    manual_raise_elapsed: u32 = 0,
    manual_raise_start_scroll: u32 = 0,
    manual_raise_cooldown: u32 = 0,

    cursor_col: u8 = 2,
    cursor_row: u8 = c.VISIBLE_ROWS - 3,

    score: u32 = 0,
    chain: u8 = 0,
    // Unlike `chain`, a combo has no ongoing state -- holds the last one's
    // size for COMBO_DISPLAY_FRAMES, meaningless once the timer hits 0.
    combo_display: u8 = 0,
    combo_display_timer: u16 = 0,
    // Set when a queued attack lands -- drives the portrait's "punish"
    // reaction for a while, ticked down exactly like combo_display_timer.
    garbage_punish_timer: u16 = 0,
    game_over: bool = false,
    // Frames at the ceiling, paused only by an in-flight pop/recycle and
    // reset only once the ceiling clears entirely (board.updateDangerTimer).
    danger_timer: u32 = 0,

    // Next id sim_garbage.spawnGarbage hands out, wrapping as u8 -- plenty
    // of distinct ids for any garbage piece actually still around at once.
    next_garbage_group: u8 = 0,

    // A chain keeps overwriting this with the latest step's size; only the
    // FINAL step survives to send, never a sum of every step.
    chain_pending_garbage: ?GarbageAttack = null,
    // Attacks aimed at this board, waiting for it to go idle before landing
    // -- garbage never appears while either side is still resolving.
    incoming_garbage: [MAX_INCOMING_GARBAGE]?GarbageAttack = [_]?GarbageAttack{null} ** MAX_INCOMING_GARBAGE,

    match_popups: [fx.MAX_MATCH_POPUPS]fx.MatchPopup = [_]fx.MatchPopup{.{}} ** fx.MAX_MATCH_POPUPS,

    particles: [fx.MAX_PARTICLES]fx.Particle = [_]fx.Particle{.{}} ** fx.MAX_PARTICLES,

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

    // Rows below SPAWN_ROWS are a fixed, non-rotating staging area mapping
    // straight through; rows from SPAWN_ROWS on are the actual rotating ring.
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

};

// Arbitrary, just so the two boards' garbage-reveal colors/CPU picks don't
// evolve in lockstep with each other from the same stream.
pub const CPU_RNG_SEED: u32 = 0x853c49e6;

pub var player: Board = .{};
pub var cpu: Board = .{ .rng_state = CPU_RNG_SEED };

// Both boards topping out the same frame is a draw; `.none` means in progress.
pub const Winner = enum { none, player, cpu, draw };
pub var winner: Winner = .none;

// Best-of-N points (constants.POINTS_TO_WIN); `set_winner` at that threshold
// drives main.zig's choice between "next match" and "series decided".
pub var player_points: u8 = 0;
pub var cpu_points: u8 = 0;
pub var set_winner: Winner = .none;

pub var started: bool = false;

// Pre-game screen order per mode -- versus's confirm gates netplay
// connection before a countdown, since joining mid-match desyncs peers.
pub const MenuPhase = enum { title, mode_select, setup_character, setup_cpu_reveal, setup_difficulty, story_tier_select, versus_confirm };
pub var menu_phase: MenuPhase = .title;
// Frames since menu_phase last changed (see main.zig's setMenuPhase) --
// drives the panel's ease-in slide and flash-cut transition below.
pub var menu_phase_timer: u32 = 0;
// Counts down from a fixed value the instant menu_phase changes, driving a
// brief flash-and-dissolve overlay -- purely cosmetic, never gates input.
pub var menu_transition_flash: u32 = 0;

// story/quick/versus as before; tutorial is a scripted single-board
// walkthrough (see tutorial.zig) with GAMEPAD2 driving `cpu` in versus only.
pub const GameMode = enum { quick, story, tutorial, versus };
// Tutorial is first (main.zig's prevMode/nextMode, render_screens'
// GAME_MODE_LABELS) so a new player's default highlight is the onboarding path.
pub var game_mode: GameMode = .tutorial;

// The tutorial's fixed lesson sequence (see tutorial.zig for content/logic).
pub const TutorialStep = enum { intro, move, swap, match, chain, garbage, raise, outro };
pub var tutorial_step: TutorialStep = .intro;

// Only easy/medium/hard cycle ordinarily -- `xhard` is only reachable via
// hold-left+swap-button on hard (game_modes.xhard_revealed is just a hint).
pub const StoryTier = enum { easy, medium, hard, xhard };
pub var story_tier: StoryTier = .easy;
// Index into characters.ALL for the current story run. Advances on a win;
// a loss retries the same stage.
pub var story_stage: u8 = 0;
// Resets to 0 only on a fresh run, never per-stage retry -- "beat hard with
// no game overs" means the whole run.
pub var story_game_overs: u32 = 0;
// Decision window for a left-press on Hard: ordinary tap vs. the secret
// hold-left-then-Z combo into X Hard (constants.STORY_SECRET_GRACE_FRAMES).
pub var story_left_grace_timer: u16 = 0;

// Who's joined the traveling party (freed by defeat, plus Mermaid from the
// start) -- main.zig's beginStoryFlow. Drops back to false on a stage loss.
pub var story_party: [characters.COUNT]bool = [_]bool{false} ** characters.COUNT;

// Mid-run sub-screens shown while s.started stays true -- MenuPhase only
// renders while !s.started, so these get their own switch in main.zig.
pub const StoryFlowStep = enum { none, character_select, walk_transition };
pub var story_flow_step: StoryFlowStep = .none;
// True when advancing to a new stage after a win (character_select leads
// into walk_transition); false when retrying after a loss (leads straight back into the countdown).
pub var story_flow_advancing: bool = false;
pub var story_flow_timer: u32 = 0;
// Highlighted pick while story_flow_step == .character_select.
pub var story_select_cursor: u8 = 0;

// Nonzero blocks input while the confirm outline blinks; at 0, main.zig
// rolls the CPU's pick and moves to `.setup_cpu_reveal`.
pub var setup_flash_timer: u16 = 0;

// `cpu_reveal_tick` drives the "spinning to a stop" animation's current
// step; `cpu_reveal_timer` counts down that tick's own hold.
pub var cpu_reveal_tick: u16 = 0;
pub var cpu_reveal_timer: u16 = 0;

// Set only by board.beginCountdown -- freezes input/simulation while
// render.drawCountdown turns the remaining count into "3/2/1/START".
pub var countdown_timer: i32 = 0;

// Purely cosmetic top-to-bottom wipe before drawGameOver -- never touches
// either Board's actual grid, just skips drawing already-"popped" rows.
pub var closing_timer: i32 = 0;

// 1-10: levels 1-4 are cpu_ai's random flipper at increasing speed; 5-10
// hand off to cpu_engine's real search instead (cpu_ai.configFor).
pub var difficulty: u8 = 1;

// The CPU's pick is always recomputed to differ from the player's own
// (characters.cpuPickFor) -- drives both sides' theming/portrait.
pub var player_character: u8 = 0;
pub var cpu_character: u8 = 1;

pub var frame_count: u32 = 0;
pub var prev_gamepad: u8 = 0;
// GAMEPAD2's own previous-frame snapshot -- versus mode's second real
// player needs their own "just pressed" history, not GAMEPAD1's.
pub var cpu_prev_gamepad: u8 = 0;
pub var held_dir: u8 = 0;
pub var das_counter: u8 = 0;

// A parallel copy of held_dir/das_counter/etc. above, used only in versus
// mode where GAMEPAD2 drives `cpu` through the same input functions.
pub var cpu_held_dir: u8 = 0;
pub var cpu_das_counter: u8 = 0;
pub var cpu_button_pending_swap: bool = false;
pub var cpu_cursor_idle_frames: u32 = 0;

// True only for a versus peer whose own real input is GAMEPAD2 -- every
// peer wants to see themselves in the main seat; render.render() reads this.
pub var versus_render_swapped: bool = false;

// Resets to 0 on any cursor move -- render.drawCursor uses it to drive the
// idle blink, so a fast-playing player never sees it blink at all.
pub var cursor_idle_frames: u32 = 0;

// One-deep buffer for the swap button: a press while mid-animation is
// remembered and applied once possible (input.updateSwap).
pub var button_pending_swap: bool = false;

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
