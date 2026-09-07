// Shared numeric layout/timing constants used across multiple modules.
// Constants used by only one module live in that module instead.

pub const COLS: u8 = 6;
pub const VISIBLE_ROWS: u8 = 10;
pub const ROWS: u8 = VISIBLE_ROWS + 1; // one extra buffer row rising in from below
pub const TILE: i32 = 16;
pub const NUM_COLORS: u8 = 5; // 3 solid hues + 2 dithered blends of adjacent hues

pub const BOARD_X: i32 = 4;
pub const BOARD_Y: i32 = 0;
pub const PANEL_X: i32 = 108;

pub const POP_FRAMES: i16 = 26;
pub const POP_FLASH_FRAMES: i16 = 10;
pub const POP_STAGGER_FRAMES: i16 = 4; // delay between each matched block's pop, so they go one at a time
pub const LAND_FRAMES: i16 = 8;
pub const SWAP_FRAMES: i16 = 6;
pub const FALL_SPEED: i16 = 4; // pixels per frame while falling

pub const MOVE_DAS_FIRST: u8 = 12;
pub const MOVE_DAS_REPEAT: u8 = 6;
