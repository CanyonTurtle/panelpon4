// A deliberately simple random-move CPU opponent for the initial vs-CPU
// build -- actually seeking matches is out of scope for now (see the module
// comment on state.Board for the broader vs-CPU design). It just picks a
// random swap every so often, like a distracted player idly poking at the
// board, mirroring the cadence (if not the intent) of input.zig's
// player-driven cursor/swap handling.

const c = @import("constants.zig");
const s = @import("state.zig");
const sim = @import("sim.zig");

// Frames between random moves -- long enough to read as a plausible, if
// unskilled, opponent rather than frantic button-mashing, and to leave the
// previous swap's animation time to resolve before picking a new target.
const MOVE_INTERVAL: u32 = 20;
var move_timer: u32 = 0;

pub fn update(self: *s.Board) void {
    if (self.boardBusy()) return; // wait for the board to settle, like a player naturally would
    move_timer += 1;
    if (move_timer < MOVE_INTERVAL) return;
    move_timer = 0;

    self.cursor_row = @intCast(self.randRange(c.VISIBLE_ROWS));
    self.cursor_col = @intCast(self.randRange(c.COLS - 1));
    sim.trySwap(self);
}

const testing = @import("std").testing;

test "cpu AI stays put for the first MOVE_INTERVAL-1 idle frames" {
    move_timer = 0;
    var b: s.Board = .{};
    const orig_row = b.cursor_row;
    const orig_col = b.cursor_col;
    for (0..MOVE_INTERVAL - 1) |_| update(&b);
    try testing.expectEqual(orig_row, b.cursor_row);
    try testing.expectEqual(orig_col, b.cursor_col);
}

test "cpu AI waits while its board is busy" {
    move_timer = 0;
    var b: s.Board = .{};
    b.cellAt(0, 0).state = .falling;
    const orig_row = b.cursor_row;
    const orig_col = b.cursor_col;
    for (0..MOVE_INTERVAL * 2) |_| update(&b);
    try testing.expectEqual(orig_row, b.cursor_row);
    try testing.expectEqual(orig_col, b.cursor_col);
}
