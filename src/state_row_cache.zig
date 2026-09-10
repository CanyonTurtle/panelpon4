// The shared row sequence both boards replay by index (see board.rowForIndex)
// so they see identical rows. 512-row ring is ~6-7 min of continuous rise.

const c = @import("constants.zig");

pub const SHARED_ROW_CACHE: u32 = 512;
pub var shared_row_rng_state: u32 = 0x2545f491;
pub var shared_rows: [SHARED_ROW_CACHE][c.COLS]u8 = undefined;
// Generated-so-far count, across the whole session -- NOT reset by each
// board's own resetGame, only by board.resetSharedRows once per match.
pub var shared_rows_count: u32 = 0;
