// Marathon mode's own HUD, filling the recentered board's freed side
// margins instead of reusing render.zig's drawPanel/render_cpu.zig.

const std = @import("std");
const s = @import("state.zig");
const w4 = @import("wasm4.zig");
const rchar = @import("render_character.zig");
const cells = @import("render_cells.zig");
const badge = @import("render_badge.zig");
const board = @import("board.zig");

const PORTRAIT_X: i32 = 8;
const PORTRAIT_Y: i32 = 8;

// Vertical bar in the right-side margin (board spans x=44..116) -- fills
// bottom-up as rise_freeze banks, draining back down as it ticks off.
const METER_X: i32 = 128;
const METER_Y: i32 = 20;
const METER_W: i32 = 10;
const METER_H: i32 = 100;
const METER_HUES = cells.DITHER_HUES[1]; // a cooler pair than the warm hues elsewhere, reads as "frozen"

// Chain/combo popups fly here instead of the score panel every other mode
// targets -- right above the meter they're filling.
pub const POPUP_TARGET_X: i32 = METER_X + @divTrunc(METER_W, 2);
pub const POPUP_TARGET_Y: i32 = METER_Y - 10;

pub fn drawHud(main_board: *s.Board, character: u8) void {
    rchar.drawFrame(PORTRAIT_X, PORTRAIT_Y, character);
    rchar.draw(PORTRAIT_X, PORTRAIT_Y, character, rchar.stateFor(main_board), rchar.currentFrame());

    w4.DRAW_COLORS.* = 0x0002;
    var buf: [12]u8 = undefined;
    const score_str = std.fmt.bufPrint(&buf, "{d}", .{main_board.score}) catch "0";
    w4.Text(score_str, PORTRAIT_X, PORTRAIT_Y + rchar.H + rchar.FRAME_MARGIN + 4);

    w4.DRAW_COLORS.* = cells.DC_BG;
    w4.Rect(METER_X, METER_Y, METER_W, METER_H);
    const filled = @divTrunc(METER_H * @as(i32, @intCast(main_board.rise_freeze)), @as(i32, @intCast(board.MARATHON_MAX_RISE_FREEZE)));
    if (filled > 0) badge.drawDitheredRectBlit(METER_X, METER_Y + METER_H - filled, METER_W, filled, METER_HUES);

    badge.drawMatchPopups(&main_board.match_popups, POPUP_TARGET_X, POPUP_TARGET_Y);
}
