// The CPU side of the panel: its score/label and its board at a simplified
// micro scale -- split out from render.zig to keep that file under the
// project's ~500-line-per-file guideline.
//
// The micro board mirrors the player's full-detail rendering (see
// render.drawBoard) in substance -- dithered colors 3-4, tiny per-color
// icons, smooth per-pixel rise scrolling, falling/swapping slide, a cursor,
// and popping/recycling animation -- just abstracted down to fit the space:
// no bevels, no linked-garbage bezel slab (each garbage cell renders
// individually), no landing squash, no column-stress bounce, no match
// popups (there's no room for a badge this small). Identical physics
// doesn't require pixel-identical rendering -- this is a secondary,
// at-a-glance view of the opponent's board, not a second full board.

const std = @import("std");
const c = @import("constants.zig");
const s = @import("state.zig");
const w4 = @import("wasm4.zig");
const sym = @import("symbols.zig");

// Mirrors render.zig's own DC_BG/DC_FRAME/HUE_DRAWCOLOR/GARBAGE_HUE/
// dither-hue mapping, and render_badge.zig's warm cursor/badge dither pair.
const DC_BG: u16 = 1;
const DC_FRAME: u16 = 2;
const HUE_DRAWCOLOR = [3]u16{ 2, 3, 4 };
const GARBAGE_HUE: u8 = 1;
const DITHER_HUES = [2][2]u8{ .{ 0, 1 }, .{ 1, 2 } };
const CURSOR_DITHER_HUES = [2]u8{ 0, 2 };

fn ditherHues(color: u8) ?[2]u8 {
    if (color < 3) return null;
    return DITHER_HUES[color - 3];
}

const MICRO_TILE: i32 = 7;
const MICRO_GAP: i32 = 1;
const MICRO_CELL: i32 = MICRO_TILE - MICRO_GAP;
const MICRO_SYMBOL_SIZE: i32 = sym.MICRO_SYMBOL_SIZE;

// Where the CPU's mini scoreboard/board sit in the panel column.
const LABEL_Y: i32 = 44;
const SCORE_Y: i32 = 54;
const BOARD_Y: i32 = 66;
const BOARD_H: i32 = @as(i32, c.VISIBLE_ROWS) * MICRO_TILE;

// Fills a w x h rect at (x, y) as a checkerboard of two DRAW_COLORS values
// (pass the same value twice for a solid fill), clipped vertically to
// [clip_top, clip_bottom) a pixel at a time -- needed since the board
// smoothly scrolls (see drawMicroBoard) and a row can be only partially
// inside the board's frame at any given moment.
fn fillChecker(x: i32, y: i32, w: i32, h: i32, dc_a: u16, dc_b: u16, clip_top: i32, clip_bottom: i32) void {
    if (w <= 0 or h <= 0) return;
    var dy: i32 = 0;
    while (dy < h) : (dy += 1) {
        const py = y + dy;
        if (py < clip_top or py >= clip_bottom) continue;
        var dx: i32 = 0;
        while (dx < w) : (dx += 1) {
            w4.DRAW_COLORS.* = if (@mod(dx + dy, 2) == 0) dc_a else dc_b;
            w4.Rect(x + dx, py, 1, 1);
        }
    }
}

// A real block color: a solid hue, or (colors 3-4) a checkerboard dither of
// two adjacent hues -- same rule as render.drawColorRect. Garbage is a
// muted background+teal checkerboard, same as render.drawGarbageRect.
fn fillCell(x: i32, y: i32, w: i32, h: i32, color: u8, is_garbage: bool, clip_top: i32, clip_bottom: i32) void {
    if (is_garbage) {
        fillChecker(x, y, w, h, DC_BG, HUE_DRAWCOLOR[GARBAGE_HUE], clip_top, clip_bottom);
        return;
    }
    if (ditherHues(color)) |hues| {
        fillChecker(x, y, w, h, HUE_DRAWCOLOR[hues[0]], HUE_DRAWCOLOR[hues[1]], clip_top, clip_bottom);
    } else {
        fillChecker(x, y, w, h, HUE_DRAWCOLOR[color], HUE_DRAWCOLOR[color], clip_top, clip_bottom);
    }
}

// A tiny 3x3 icon (see symbols.MICRO_SYMBOLS) in the background color, same
// technique as render.drawSymbolFor -- only drawn when the whole cell is
// inside the clip range, since a 3px icon straddling a partially-scrolled
// row's clip edge wouldn't read as anything recognizable anyway.
fn drawMicroIcon(x: i32, y: i32, color: u8, clip_top: i32, clip_bottom: i32) void {
    if (y < clip_top or y + MICRO_CELL > clip_bottom) return;
    w4.DRAW_COLORS.* = DC_BG;
    const off = @divTrunc(MICRO_CELL - MICRO_SYMBOL_SIZE, 2);
    const rows = sym.MICRO_SYMBOLS[color];
    for (rows, 0..) |row, ry| {
        for (row, 0..) |ch, rx| {
            if (ch == '#') w4.Rect(x + off + @as(i32, @intCast(rx)), y + off + @as(i32, @intCast(ry)), 1, 1);
        }
    }
}

// A settled/falling/swapping/landing real block: its color fill plus icon.
// Garbage skips the icon (it's colorless).
fn fillCellFull(x: i32, y: i32, cell: s.Cell, clip_top: i32, clip_bottom: i32) void {
    fillCell(x, y, MICRO_CELL, MICRO_CELL, cell.color, cell.is_garbage, clip_top, clip_bottom);
    if (!cell.is_garbage) drawMicroIcon(x, y, cell.color, clip_top, clip_bottom);
}

// A real match popping -- mirrors render.drawPoppingCell's two phases
// (a brief flash pulse, then a shrink to nothing) scaled down: the flash
// amplitude is a subtle 1px wobble rather than main's 4px (proportionate to
// the much smaller cell), and the shrink uses the exact same fraction/timing
// math as the full-scale version. No icon -- it wouldn't fit as the cell
// shrinks, same as the full-scale version.
fn drawMicroPopping(x: i32, y: i32, color: u8, timer: i16, clip_top: i32, clip_bottom: i32) void {
    const elapsed = c.POP_FRAMES - timer;
    if (elapsed < 0) {
        fillCellFull(x, y, .{ .color = color }, clip_top, clip_bottom);
        return;
    }
    var size: i32 = MICRO_CELL;
    if (elapsed < c.POP_FLASH_FRAMES) {
        const puls: i32 = @intCast(@mod(elapsed, 8));
        const delta: i32 = if (puls < 4) puls else 8 - puls;
        size = MICRO_CELL - @divTrunc(delta, 4); // 0..4 -> 0..1px wobble
    } else {
        const shrink_elapsed = elapsed - c.POP_FLASH_FRAMES;
        const shrink_total = c.POP_FRAMES - c.POP_FLASH_FRAMES;
        const remain = shrink_total - shrink_elapsed;
        size = @divTrunc(MICRO_CELL * remain, shrink_total);
        if (size < 0) size = 0;
    }
    if (size <= 0) return;
    const off = @divTrunc(MICRO_CELL - size, 2);
    fillCell(x + off, y + off, size, size, color, false, clip_top, clip_bottom);
}

// A garbage cell being recycled -- mirrors render.drawRecyclingCell: still
// looks like inert garbage until its own staggered turn (same timer/formula
// as the full-scale version), then hard-cuts to a plain revealed block (with
// its icon) and stays that way -- no animation of its own.
fn drawMicroRecycling(x: i32, y: i32, color: u8, timer: i16, clip_top: i32, clip_bottom: i32) void {
    const elapsed = c.POP_FRAMES - timer;
    if (elapsed < 0) {
        fillCell(x, y, MICRO_CELL, MICRO_CELL, 0, true, clip_top, clip_bottom);
        return;
    }
    fillCell(x, y, MICRO_CELL, MICRO_CELL, color, false, clip_top, clip_bottom);
    drawMicroIcon(x, y, color, clip_top, clip_bottom);
}

fn drawMicroBoard(b: *s.Board, origin_x: i32, origin_y: i32) void {
    const clip_top = origin_y;
    const clip_bottom = origin_y + BOARD_H;
    // Proportional scroll: scroll_px is counted in the main board's TILE
    // units, so it's rescaled here to MICRO_TILE units -- the rise reads at
    // the same relative pace, just smaller, rather than snapping row by row.
    const micro_scroll = @divTrunc(@as(i32, @intCast(b.scroll_px)) * MICRO_TILE, c.TILE);

    var lr: u8 = 0;
    while (lr < c.ROWS) : (lr += 1) {
        const base_y = origin_y + @as(i32, lr) * MICRO_TILE - micro_scroll;
        if (base_y + MICRO_TILE <= clip_top or base_y >= clip_bottom) continue;
        var col: u8 = 0;
        while (col < c.COLS) : (col += 1) {
            const cell = b.cellAt(lr, col);
            if (cell.state == .empty) continue;
            const x = origin_x + @as(i32, col) * MICRO_TILE;
            switch (cell.state) {
                .normal => fillCellFull(x, base_y, cell.*, clip_top, clip_bottom),
                .falling => {
                    const fall = @divTrunc(@as(i32, cell.fall_off) * MICRO_TILE, c.TILE);
                    fillCellFull(x, base_y - fall, cell.*, clip_top, clip_bottom);
                },
                .swapping => {
                    const off = @as(i32, cell.swap_dir) * @divTrunc(MICRO_TILE * @as(i32, cell.timer), c.SWAP_FRAMES);
                    fillCellFull(x + off, base_y, cell.*, clip_top, clip_bottom);
                },
                .landing => fillCellFull(x, base_y, cell.*, clip_top, clip_bottom),
                .popping => drawMicroPopping(x, base_y, cell.color, cell.timer, clip_top, clip_bottom),
                .recycling => drawMicroRecycling(x, base_y, cell.color, cell.timer, clip_top, clip_bottom),
                .empty => {},
            }
        }
    }

    w4.DRAW_COLORS.* = DC_FRAME;
    const w = @as(i32, c.COLS) * MICRO_TILE;
    w4.Rect(origin_x - 1, origin_y - 1, @intCast(w + 2), 1);
    w4.Rect(origin_x - 1, origin_y + BOARD_H, @intCast(w + 2), 1);
    w4.Rect(origin_x - 1, origin_y - 1, 1, @intCast(BOARD_H + 2));
    w4.Rect(origin_x + w, origin_y - 1, 1, @intCast(BOARD_H + 2));
}

// A tiny 1px dithered outline over the CPU's own (AI-driven, see cpu_ai.zig)
// two-tile cursor position -- same warm red/yellow dither rule as the
// player's own cursor (render.drawCursor), just without the pulse/contract
// animation (not worth the extra complexity at this scale).
fn drawMicroCursor(b: *s.Board, origin_x: i32, origin_y: i32) void {
    if (s.winner != .none) return;
    const micro_scroll = @divTrunc(@as(i32, @intCast(b.scroll_px)) * MICRO_TILE, c.TILE);
    const x = origin_x + @as(i32, b.cursor_col) * MICRO_TILE;
    const y = origin_y + @as(i32, b.cursor_row) * MICRO_TILE - micro_scroll;
    const w = MICRO_TILE * 2;
    const h = MICRO_TILE;

    var i: i32 = 0;
    while (i < w) : (i += 1) {
        plotDithered(x + i, y);
        plotDithered(x + i, y + h - 1);
    }
    var j: i32 = 0;
    while (j < h) : (j += 1) {
        plotDithered(x, y + j);
        plotDithered(x + w - 1, y + j);
    }
}

fn plotDithered(x: i32, y: i32) void {
    const hue = if (@mod(x + y, 2) == 0) CURSOR_DITHER_HUES[0] else CURSOR_DITHER_HUES[1];
    w4.DRAW_COLORS.* = HUE_DRAWCOLOR[hue];
    w4.Rect(x, y, 1, 1);
}

pub fn draw() void {
    w4.DRAW_COLORS.* = 0x0002;
    w4.Text("CPU", c.PANEL_X, LABEL_Y);
    var buf: [12]u8 = undefined;
    const score_str = std.fmt.bufPrint(&buf, "{d}", .{s.cpu.score}) catch "0";
    w4.Text(score_str, c.PANEL_X, SCORE_Y);

    drawMicroBoard(&s.cpu, c.PANEL_X, BOARD_Y);
    drawMicroCursor(&s.cpu, c.PANEL_X, BOARD_Y);
}
