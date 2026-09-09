// Shared numeric layout/timing constants used across multiple modules.
// Constants used by only one module live in that module instead.

pub const COLS: u8 = 6;
pub const VISIBLE_ROWS: u8 = 12; // traditional Panel de Pon board size (6x12)
// Offscreen rows stacked above the ceiling, purely as a garbage staging area
// (see sim_garbage.spawnGarbage) -- never rendered, never reachable by the
// cursor, never touched by the rise mechanic's ring rotation (see
// Board.physRow). Big enough that a piece almost never fails to fit even
// against a near-full board.
pub const SPAWN_ROWS: u8 = 10;
// Size of the rotating ring window that doRise/physRow actually rotate
// through -- unchanged in meaning from the old (pre-spawn-buffer) `ROWS`:
// every visible row plus one extra buffer row rising in from below.
pub const RING_SIZE: u8 = VISIBLE_ROWS + 1;
pub const ROWS: u8 = SPAWN_ROWS + RING_SIZE; // spawn buffer + the rotating window
pub const TILE: i32 = 12;
pub const NUM_COLORS: u8 = 5; // 3 solid hues + 2 dithered blends of adjacent hues

// Content width is COLS*TILE (72px); centered in the space left of the
// panel (0..PANEL_X, i.e. (108-72)/2 = 18) now that a 12px tile makes the
// board noticeably narrower than it used to be at 16px.
pub const BOARD_X: i32 = 18;
pub const BOARD_Y: i32 = 0;
pub const PANEL_X: i32 = 108;

pub const POP_FRAMES: i16 = 34; // per-block pop duration; longer gives big combos/chains more time to read
pub const POP_FLASH_FRAMES: i16 = 10;
pub const POP_STAGGER_FRAMES: i16 = 4; // delay between each matched block's pop, so they go one at a time

// Every cell in a match/recycle group gets a heads-up preamble, all in
// lockstep (simultaneously across the whole group, not staggered like the
// per-member pop cascade below), before its own pop/reveal cascade even
// begins: first it blinks (hard on/off every single frame -- a flicker, not
// the size-wobble flash below), then holds steady, normal-looking, for a
// short beat -- see Cell.pre_pop_timer, render.drawPoppingCell/
// drawRecyclingCell, and render_cpu's micro mirrors.
pub const PRE_POP_BLINK_FRAMES: i16 = 24;
pub const PRE_POP_PAUSE_FRAMES: i16 = 12;
pub const PRE_POP_TOTAL_FRAMES: i16 = PRE_POP_BLINK_FRAMES + PRE_POP_PAUSE_FRAMES;
pub const LAND_FRAMES: i16 = 8;
pub const COMBO_DISPLAY_FRAMES: u16 = 90; // 1.5s -- how long the panel's "COMBO" label lingers
pub const POINTS_TO_WIN: u8 = 2; // best of 3 -- first to 2 match wins takes the series
pub const GARBAGE_PUNISH_DISPLAY_FRAMES: u16 = 90; // 1.5s -- how long a character's "punish" reaction lingers
pub const CHARACTER_ANIM_FRAME_TICKS: u32 = 20; // frames each of a character's 2 animation frames holds

// The "3 2 1 START" countdown overlay at match start (see
// board.beginCountdown/state.countdown_timer/render.drawCountdown): "3",
// "2", "1" each rise a couple pixels then hold steady for about a second;
// "START" rises the same way but then blinks a few times instead of
// holding steady.
pub const COUNTDOWN_RISE_FRAMES: i32 = 10;
pub const COUNTDOWN_RISE_PX: i32 = 10;
pub const COUNTDOWN_HOLD_FRAMES: i32 = 50; // ~1s hold for "3"/"2"/"1"
pub const COUNTDOWN_NUMBER_FRAMES: i32 = COUNTDOWN_RISE_FRAMES + COUNTDOWN_HOLD_FRAMES;
pub const COUNTDOWN_BLINK_HALF_FRAMES: i32 = 10; // one on/off half-cycle for START
pub const COUNTDOWN_BLINK_COUNT: i32 = 3;
pub const COUNTDOWN_START_FRAMES: i32 = COUNTDOWN_RISE_FRAMES + COUNTDOWN_BLINK_HALF_FRAMES * 2 * COUNTDOWN_BLINK_COUNT;
pub const COUNTDOWN_TOTAL_FRAMES: i32 = COUNTDOWN_NUMBER_FRAMES * 3 + COUNTDOWN_START_FRAMES;

// The closing "wipe" once a match ends (see main.zig/render.drawBoard's
// wipe skip): every visible row pops, one at a time from the ceiling down,
// before the match-over overlay appears (render.drawGameOver). Covers
// RING_SIZE rows (VISIBLE_ROWS plus the one hidden rise-buffer row), not
// just VISIBLE_ROWS -- that hidden row can be partially on-screen during a
// mid-scroll frame (see render.BOARD_BOTTOM's own comment), so stopping the
// wipe one row short of it would leave a sliver of un-popped content
// visible at the very bottom right up until the overlay appears.
pub const CLOSING_FRAMES_PER_ROW: i32 = 4;
pub const CLOSING_TOTAL_FRAMES: i32 = @as(i32, RING_SIZE) * CLOSING_FRAMES_PER_ROW;
pub const SWAP_FRAMES: i16 = 6;
pub const FALL_SPEED: i16 = 4; // pixels per frame while falling

pub const MOVE_DAS_FIRST: u8 = 12;
pub const MOVE_DAS_REPEAT: u8 = 6;

pub const CURSOR_SWAP_FLASH_FRAMES: u8 = 3;

// Manual raise (the Z button, see board.tryManualRaise): finishes whatever
// row is currently rising in 1/3 second instead of waiting for the normal
// automatic pace, then locks out another manual raise for 2/3 second (WASM-4
// runs at 60fps, so 20 and 40 frames respectively).
pub const MANUAL_RAISE_FRAMES: u32 = 20;
pub const MANUAL_RAISE_COOLDOWN: u32 = 40;

// A board only actually tops out once it's sat idle, with a block at or
// above the ceiling, for this many consecutive frames (1 second at 60fps) --
// see board.updateDangerTimer. Long enough to give a high-level player a
// real beat to clear the danger row before it's final, short enough that it
// never feels like the game is ignoring an obvious loss.
pub const DANGER_FORGIVENESS_FRAMES: u32 = 60;
