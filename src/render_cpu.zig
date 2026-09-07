// The CPU side of the panel: its score/label and its board at a simplified
// micro scale -- split out from render.zig to keep that file under the
// project's ~500-line-per-file guideline.
//
// The micro board is deliberately much simpler than the player's full-detail
// rendering (see render.drawBoard): solid-color cells, no bevel, dither, or
// symbols (there's no room for that detail this small, and it wouldn't read
// well anyway), no cursor, no match popups, and no per-pixel rise scrolling
// (each row just snaps to its new position the instant board.doRise shifts
// it, rather than easing smoothly like the player's board does). Identical
// physics doesn't require identical rendering -- this is a secondary,
// at-a-glance view of the opponent's board state, not a second full board.

const std = @import("std");
const c = @import("constants.zig");
const s = @import("state.zig");
const w4 = @import("wasm4.zig");

// Mirrors render.zig's own DC_FRAME/HUE_DRAWCOLOR/GARBAGE_HUE mapping and
// dither-hue lookup.
const DC_FRAME: u16 = 2;
const HUE_DRAWCOLOR = [3]u16{ 2, 3, 4 };
const GARBAGE_HUE: u8 = 1;
const DITHER_HUES = [2][2]u8{ .{ 0, 1 }, .{ 1, 2 } };

fn ditherHues(color: u8) ?[2]u8 {
    if (color < 3) return null;
    return DITHER_HUES[color - 3];
}

const MICRO_TILE: i32 = 7;
const MICRO_GAP: i32 = 1;
const MICRO_CELL: i32 = MICRO_TILE - MICRO_GAP;

// Where the CPU's mini scoreboard/board sit in the panel column.
const LABEL_Y: i32 = 44;
const SCORE_Y: i32 = 54;
const BOARD_Y: i32 = 66;

fn microCellHue(cell: s.Cell) u8 {
    if (cell.is_garbage) return GARBAGE_HUE;
    if (ditherHues(cell.color)) |hues| return hues[0];
    return cell.color;
}

fn drawMicroBoard(b: *s.Board, origin_x: i32, origin_y: i32) void {
    var lr: u8 = 0;
    while (lr < c.VISIBLE_ROWS) : (lr += 1) {
        const y = origin_y + @as(i32, lr) * MICRO_TILE;
        var col: u8 = 0;
        while (col < c.COLS) : (col += 1) {
            const cell = b.cellAt(lr, col);
            if (cell.state == .empty) continue;
            const x = origin_x + @as(i32, col) * MICRO_TILE;
            w4.DRAW_COLORS.* = HUE_DRAWCOLOR[microCellHue(cell.*)];
            w4.Rect(x, y, @intCast(MICRO_CELL), @intCast(MICRO_CELL));
        }
    }

    const w = @as(i32, c.COLS) * MICRO_TILE;
    const h = @as(i32, c.VISIBLE_ROWS) * MICRO_TILE;
    w4.DRAW_COLORS.* = DC_FRAME;
    w4.Rect(origin_x - 1, origin_y - 1, @intCast(w + 2), 1);
    w4.Rect(origin_x - 1, origin_y + h, @intCast(w + 2), 1);
    w4.Rect(origin_x - 1, origin_y - 1, 1, @intCast(h + 2));
    w4.Rect(origin_x + w, origin_y - 1, 1, @intCast(h + 2));
}

pub fn draw() void {
    w4.DRAW_COLORS.* = 0x0002;
    w4.Text("CPU", c.PANEL_X, LABEL_Y);
    var buf: [12]u8 = undefined;
    const score_str = std.fmt.bufPrint(&buf, "{d}", .{s.cpu.score}) catch "0";
    w4.Text(score_str, c.PANEL_X, SCORE_Y);

    drawMicroBoard(&s.cpu, c.PANEL_X, BOARD_Y);
}
