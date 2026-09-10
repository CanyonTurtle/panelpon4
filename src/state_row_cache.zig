// The shared row sequence both boards' rising rows are drawn from (see
// board.rowForIndex) -- split out of state.zig (whose only consumer here is
// board.zig) to keep that file under the project's ~500-line-per-file
// guideline. "Predetermined at match start" and "the same for both players
// per row" in practice: whichever board first reaches a given row index
// (Board.rows_generated) generates and caches it here; the other board just
// replays that exact result once it reaches the same index, however much
// later. Deliberately keyed purely by index, never by either board's own
// actual stack content, since that's exactly what would make the two
// boards' sequences diverge and defeat the point -- see board.pickRowColors,
// which avoids an accidental run of 3 against the previous two rows *in
// this sequence*, not whatever's really on a board.
//
// A fixed-size ring rather than something unbounded: `shared_rows_count`
// only ever grows, but a lookup wraps via `% SHARED_ROW_CACHE`, so a board
// that somehow fell more than a full cache's worth of rows behind the other
// would start reading overwritten (stale) entries -- 512 rows is roughly
// 6-7 minutes of continuous rising even at the fastest pace (see
// board.riseSpeedFramesPerPixel's floor), comfortably past how long a real
// match actually runs before someone's board tops out, so this is treated
// as effectively unbounded in practice rather than engineered against.

const c = @import("constants.zig");

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
