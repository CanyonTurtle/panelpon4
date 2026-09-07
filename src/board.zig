// Row generation, the rising floor, and (re)starting a game.

const c = @import("constants.zig");
const s = @import("state.zig");

pub fn riseSpeedFramesPerPixel() u32 {
    const level = s.score / 300;
    const speed = if (level > 4) 4 else 8 - level;
    return speed;
}

pub fn generateRowInto(target_phys: u8, logical_r: u8) void {
    var row_colors: [c.COLS]u8 = undefined;
    var ci: u8 = 0;
    while (ci < c.COLS) : (ci += 1) {
        var above1: i16 = -1;
        var above2: i16 = -1;
        if (logical_r >= 1) {
            const cell1 = s.cellAt(logical_r - 1, ci);
            if (cell1.state == .normal) above1 = cell1.color;
        }
        if (logical_r >= 2) {
            const cell2 = s.cellAt(logical_r - 2, ci);
            if (cell2.state == .normal) above2 = cell2.color;
        }

        var chosen: u8 = 0;
        var tries: u8 = 0;
        while (true) {
            chosen = @intCast(s.randRange(c.NUM_COLORS));
            var ok = true;
            if (ci >= 2 and row_colors[ci - 1] == chosen and row_colors[ci - 2] == chosen) ok = false;
            if (ok and above1 >= 0 and above2 >= 0 and above1 == chosen and above2 == chosen) ok = false;
            tries += 1;
            if (ok or tries > 20) break;
        }
        row_colors[ci] = chosen;
    }

    ci = 0;
    while (ci < c.COLS) : (ci += 1) {
        s.grid[target_phys][ci] = s.Cell{ .color = row_colors[ci], .state = .normal };
    }
}

pub fn doRise() void {
    var col: u8 = 0;
    while (col < c.COLS) : (col += 1) {
        if (s.cellAt(0, col).state != .empty) {
            s.game_over = true;
            return;
        }
    }
    generateRowInto(s.top, c.ROWS - 1);
    s.top = @intCast((@as(u16, s.top) + 1) % @as(u16, c.ROWS));

    // Logical row indices are relative to `top`, so a fixed cursor_row would
    // silently point at a different (lower) absolute row after this shift,
    // which reads as the cursor snapping down. Decrement it to keep tracking
    // the same physical row it was on, so the cursor rises with the stack
    // unless the player is actively moving it.
    if (s.cursor_row > 0) s.cursor_row -= 1;
}

pub fn updateRise() void {
    if (s.boardBusy()) return;
    s.rise_frame_counter += 1;
    if (s.rise_frame_counter >= riseSpeedFramesPerPixel()) {
        s.rise_frame_counter = 0;
        s.scroll_px += 1;
        if (s.scroll_px >= @as(u32, @intCast(c.TILE))) {
            s.scroll_px -= @as(u32, @intCast(c.TILE));
            doRise();
        }
    }
}

pub fn resetGame() void {
    s.game_over = false;
    s.score = 0;
    s.chain = 0;
    s.top = 0;
    s.scroll_px = 0;
    s.rise_frame_counter = 0;
    s.cursor_col = 2;
    s.cursor_row = c.VISIBLE_ROWS - 3;

    for (0..c.ROWS) |r| {
        for (0..c.COLS) |col| {
            s.grid[r][col] = s.Cell{};
        }
    }

    const start_rows_filled: u8 = 5;
    var r: u8 = c.VISIBLE_ROWS - start_rows_filled;
    while (r < c.ROWS) : (r += 1) {
        generateRowInto(r, r);
    }
}

const testing = @import("std").testing;

test "doRise triggers game_over once a column reaches the top row" {
    s.resetForTest();
    s.cellAt(0, 0).state = .normal;
    doRise();
    try testing.expect(s.game_over);
}

test "doRise shifts top and keeps the cursor tracking the same physical row" {
    s.resetForTest();
    s.cursor_row = 4;
    const before_top = s.top;
    doRise();
    try testing.expect(!s.game_over);
    try testing.expectEqual(@as(u8, (before_top + 1) % c.ROWS), s.top);
    try testing.expectEqual(@as(u8, 3), s.cursor_row);
}

test "generateRowInto never produces a 3-in-a-row horizontally" {
    s.resetForTest();
    s.rng_state = 12345;
    for (0..50) |i| {
        generateRowInto(0, 0);
        var run: u8 = 1;
        var run_color = s.grid[0][0].color;
        for (1..c.COLS) |col| {
            if (s.grid[0][col].color == run_color) {
                run += 1;
                try testing.expect(run < 3);
            } else {
                run = 1;
                run_color = s.grid[0][col].color;
            }
        }
        _ = i;
    }
}

test "riseSpeedFramesPerPixel decreases with score and floors at 4" {
    s.resetForTest();
    s.score = 0;
    try testing.expectEqual(@as(u32, 8), riseSpeedFramesPerPixel());
    s.score = 300;
    try testing.expectEqual(@as(u32, 7), riseSpeedFramesPerPixel());
    s.score = 3000;
    try testing.expectEqual(@as(u32, 4), riseSpeedFramesPerPixel());
}
