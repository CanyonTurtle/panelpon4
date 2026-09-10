// Shared numeric layout/timing constants used across multiple modules.
// Constants used by only one module live in that module instead.

pub const COLS: u8 = 6;
pub const VISIBLE_ROWS: u8 = 12; // traditional Panel de Pon board size (6x12)
// Offscreen garbage staging rows above the ceiling (see sim_garbage.
// spawnGarbage) -- never rendered/reachable, sized so a piece always fits.
pub const SPAWN_ROWS: u8 = 10;
// The rotating window doRise/physRow actually rotate through: every visible
// row plus one extra buffer row rising in from below.
pub const RING_SIZE: u8 = VISIBLE_ROWS + 1;
pub const ROWS: u8 = SPAWN_ROWS + RING_SIZE; // spawn buffer + the rotating window
pub const TILE: i32 = 12;
pub const NUM_COLORS: u8 = 5; // 3 solid hues + 2 dithered blends of adjacent hues

// Content width is COLS*TILE (72px), centered in the space left of the
// panel (0..PANEL_X, i.e. (108-72)/2 = 18).
pub const BOARD_X: i32 = 18;
pub const BOARD_Y: i32 = 0;
pub const PANEL_X: i32 = 108;

// Promoted from a render_cpu-local constant so sim_matches.checkMatches can
// compute a match popup's spawn point without importing rendering code.
pub const CPU_MICRO_TILE: i32 = 7;
pub const CPU_BOARD_Y: i32 = 66;

// var (not const): game_modes.applyProfile retunes these per story tier.
pub var POP_FRAMES: i16 = 34; // per-block pop duration; longer gives big combos/chains more time to read
pub const POP_FLASH_FRAMES: i16 = 10;
pub const POP_STAGGER_FRAMES: i16 = 4; // delay between each matched block's pop, so they go one at a time

// Every cell in a match/recycle group blinks in lockstep, then holds steady,
// before its own staggered pop/reveal cascade begins (see Cell.pre_pop_timer).
pub var PRE_POP_BLINK_FRAMES: i16 = 24;
pub var PRE_POP_PAUSE_FRAMES: i16 = 12;
// Kept manually in sync with the two fields above by applyProfile -- a plain
// literal, since a var's initializer must be comptime-known.
pub var PRE_POP_TOTAL_FRAMES: i16 = 36;
pub const LAND_FRAMES: i16 = 8;
pub const COMBO_DISPLAY_FRAMES: u16 = 90; // 1.5s -- how long the panel's "COMBO" label lingers
pub const POINTS_TO_WIN: u8 = 2; // best of 3 -- first to 2 match wins takes the series
pub const GARBAGE_PUNISH_DISPLAY_FRAMES: u16 = 90; // 1.5s -- how long a character's "punish" reaction lingers
pub const CHARACTER_ANIM_FRAME_TICKS: u32 = 20; // frames each of a character's 2 animation frames holds

// Grace window for a left-hold to join Z before the story tier screen's
// secret X Hard combo commits to an ordinary Medium tap (see main.zig).
pub const STORY_SECRET_GRACE_FRAMES: u16 = 20;

// How long the walk-up-to-the-next-opponent scene's slide-in animation
// takes (render_screens.drawStoryWalkTransition) before X can skip ahead.
pub const STORY_WALK_TRANSITION_FRAMES: u32 = 20;

// The character screen's confirm flash (see state.setup_flash_timer):
// blinks the selection outline every TOGGLE frames, 3 full on/off cycles.
pub const SETUP_FLASH_TOTAL_FRAMES: u16 = 24;
pub const SETUP_FLASH_TOGGLE_FRAMES: u16 = 4;

// The CPU reveal screen's "spinning to a stop" animation: each of
// CPU_REVEAL_STEPS ticks holds longer than the last, landing on the pick.
pub const CPU_REVEAL_STEPS: u16 = 10;
pub const CPU_REVEAL_HOLD_BASE: u16 = 3;
pub const CPU_REVEAL_HOLD_GROWTH: u16 = 3;

// The "3 2 1 START" countdown overlay (see board.beginCountdown): "3"/"2"/"1"
// rise then hold steady; "START" rises then blinks instead of holding.
pub const COUNTDOWN_RISE_FRAMES: i32 = 10;
pub const COUNTDOWN_RISE_PX: i32 = 10;
pub const COUNTDOWN_HOLD_FRAMES: i32 = 50; // ~1s hold for "3"/"2"/"1"
pub const COUNTDOWN_NUMBER_FRAMES: i32 = COUNTDOWN_RISE_FRAMES + COUNTDOWN_HOLD_FRAMES;
pub const COUNTDOWN_BLINK_HALF_FRAMES: i32 = 10; // one on/off half-cycle for START
pub const COUNTDOWN_BLINK_COUNT: i32 = 3;
pub const COUNTDOWN_START_FRAMES: i32 = COUNTDOWN_RISE_FRAMES + COUNTDOWN_BLINK_HALF_FRAMES * 2 * COUNTDOWN_BLINK_COUNT;
pub const COUNTDOWN_TOTAL_FRAMES: i32 = COUNTDOWN_NUMBER_FRAMES * 3 + COUNTDOWN_START_FRAMES;

// The closing "wipe" once a match ends covers RING_SIZE rows, not just
// VISIBLE_ROWS -- the hidden buffer row can be partially on-screen mid-scroll.
pub const CLOSING_FRAMES_PER_ROW: i32 = 4;
pub const CLOSING_TOTAL_FRAMES: i32 = @as(i32, RING_SIZE) * CLOSING_FRAMES_PER_ROW;
pub const SWAP_FRAMES: i16 = 6;
pub const FALL_SPEED: i16 = 4; // pixels per frame while falling

pub const MOVE_DAS_FIRST: u8 = 12;
pub const MOVE_DAS_REPEAT: u8 = 6;

// Manual raise (board.tryManualRaise) finishes the rising row in 1/3s, then
// locks out another manual raise for 2/3s (WASM-4 runs at 60fps).
pub const MANUAL_RAISE_FRAMES: u32 = 20;
pub const MANUAL_RAISE_COOLDOWN: u32 = 40;

// A board only tops out once idle, with a block at/above the ceiling, for
// this many consecutive frames (1s at 60fps) -- see board.updateDangerTimer.
pub var DANGER_FORGIVENESS_FRAMES: u32 = 60;

// Percentage multiplier on board.riseSpeedFramesPerPixel (100 = unchanged);
// story mode's "stack rise speed" knob. Quick match and versus stay at 100.
pub var RISE_SPEED_SCALE_PCT: u32 = 100;

const testing = @import("std").testing;

test "STORY_SECRET_GRACE_FRAMES is a short grace window, well under a second" {
    try testing.expect(STORY_SECRET_GRACE_FRAMES > 0);
    try testing.expect(STORY_SECRET_GRACE_FRAMES < 60);
}

test "closing wipe covers every RING_SIZE row, not just VISIBLE_ROWS" {
    const rows_covered = @divExact(CLOSING_TOTAL_FRAMES, CLOSING_FRAMES_PER_ROW);
    try testing.expectEqual(@as(i32, RING_SIZE), rows_covered);
    try testing.expect(rows_covered > VISIBLE_ROWS);
}
