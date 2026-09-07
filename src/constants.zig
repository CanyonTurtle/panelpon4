// Shared numeric layout/timing constants used across multiple modules.
// Constants used by only one module live in that module instead.

pub const COLS: u8 = 6;
pub const VISIBLE_ROWS: u8 = 12; // traditional Panel de Pon board size (6x12)
pub const ROWS: u8 = VISIBLE_ROWS + 1; // one extra buffer row rising in from below
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
pub const SWAP_FRAMES: i16 = 6;
pub const FALL_SPEED: i16 = 4; // pixels per frame while falling

pub const MOVE_DAS_FIRST: u8 = 12;
pub const MOVE_DAS_REPEAT: u8 = 6;

// Manual raise (the Z button, see board.tryManualRaise): finishes whatever
// row is currently rising in 1/3 second instead of waiting for the normal
// automatic pace, then locks out another manual raise for 2/3 second (WASM-4
// runs at 60fps, so 20 and 40 frames respectively).
pub const MANUAL_RAISE_FRAMES: u32 = 20;
pub const MANUAL_RAISE_COOLDOWN: u32 = 40;
