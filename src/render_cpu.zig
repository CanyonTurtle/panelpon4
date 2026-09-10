// The CPU side of the panel: score/label and a micro-scale board, split out
// of render.zig. Mirrors render.drawBoard's substance, abstracted down.

const std = @import("std");
const c = @import("constants.zig");
const s = @import("state.zig");
const w4 = @import("wasm4.zig");
const sym = @import("symbols.zig");
const badge = @import("render_badge.zig");
const characters = @import("characters.zig");
const rchar = @import("render_character.zig");

// Mirrors render.zig's own DC_BG/HUE_DRAWCOLOR mapping, and
// render_badge.zig's warm cursor/badge dither pair.
const DC_BG: u16 = 1;
const HUE_DRAWCOLOR = [3]u16{ 2, 3, 4 };
const GARBAGE_HUE: u8 = 1;
const DITHER_HUES = [2][2]u8{ .{ 0, 1 }, .{ 1, 2 } };
const CURSOR_DITHER_HUES = [2]u8{ 0, 2 };

fn ditherHues(color: u8) ?[2]u8 {
    if (color < 3) return null;
    return DITHER_HUES[color - 3];
}

const MICRO_TILE: i32 = c.CPU_MICRO_TILE;
const MICRO_GAP: i32 = 1;
const MICRO_CELL: i32 = MICRO_TILE - MICRO_GAP;
const MICRO_SYMBOL_SIZE: i32 = sym.MICRO_SYMBOL_SIZE;

// Where the CPU's portrait/scoreboard/board sit in the panel column.
const LABEL_Y: i32 = 44;
const BOARD_Y: i32 = c.CPU_BOARD_Y;
// Shared with badge.drawMatchPopups below so the flying badge lands on the
// right score text -- same idea as render.zig's own CHAR_TEXT_X.
const TEXT_X: i32 = c.PANEL_X + rchar.W + rchar.FRAME_MARGIN + 2;
const BOARD_H: i32 = @as(i32, c.VISIBLE_ROWS) * MICRO_TILE;

// Fills a w x h rect as a checkerboard (or solid, if dc_a==dc_b), clipped
// vertically since the board scrolls smoothly, not row by row.
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

// A solid hue, or (colors 3-4) a 2-hue dither -- same rule as render_cells'
// drawColorRect. Garbage is a bg+teal checkerboard, as render.drawGarbageRect.
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

// A tiny 3x3 icon (symbols.MICRO_SYMBOLS), only drawn when the whole cell
// is inside the clip range -- a clipped 3px icon wouldn't read as anything.
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

// Mirrors render.drawPoppingCell's two phases scaled down (1px wobble, not
// 4px); same fraction/timing math. No icon -- wouldn't fit as it shrinks.
fn drawMicroPopping(x: i32, y: i32, color: u8, timer: i16, pre_pop_timer: i16, clip_top: i32, clip_bottom: i32) void {
    if (pre_pop_timer > 0) {
        // Mirrors render.drawPoppingCell's own pre-pop blink+pause preamble,
        // shared in lockstep by the whole group (see Cell.pre_pop_timer).
        const elapsed = c.PRE_POP_TOTAL_FRAMES - pre_pop_timer;
        if (elapsed < c.PRE_POP_BLINK_FRAMES) {
            if (@mod(elapsed, 2) == 0) fillCellFull(x, y, .{ .color = color }, clip_top, clip_bottom);
        } else {
            fillCellFull(x, y, .{ .color = color }, clip_top, clip_bottom);
        }
        return;
    }
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

// Mirrors render.drawRecyclingCell: a converting cell hard-cuts to a plain
// revealed block at its staggered turn; a non-converting one stays garbage.
fn drawMicroRecycling(x: i32, y: i32, color: u8, timer: i16, pre_pop_timer: i16, garbage_reveals: bool, clip_top: i32, clip_bottom: i32) void {
    if (pre_pop_timer > 0) {
        // Mirrors render.drawRecyclingCell's own pre-pop blink+pause
        // preamble, shared in lockstep by the whole group.
        const elapsed = c.PRE_POP_TOTAL_FRAMES - pre_pop_timer;
        if (elapsed < c.PRE_POP_BLINK_FRAMES) {
            if (@mod(elapsed, 2) == 0) fillCell(x, y, MICRO_CELL, MICRO_CELL, 0, true, clip_top, clip_bottom);
        } else {
            fillCell(x, y, MICRO_CELL, MICRO_CELL, 0, true, clip_top, clip_bottom);
        }
        return;
    }
    if (!garbage_reveals) {
        // Mirrors render.drawRecyclingCell's flash: this row never actually
        // converts, but still reads as processed via an inverted checkerboard.
        const elapsed = c.POP_FRAMES - timer;
        if (elapsed < 0 or elapsed >= c.POP_FRAMES) {
            fillCell(x, y, MICRO_CELL, MICRO_CELL, 0, true, clip_top, clip_bottom);
        } else if (@mod(elapsed, 8) < 4) {
            fillChecker(x, y, MICRO_CELL, MICRO_CELL, HUE_DRAWCOLOR[GARBAGE_HUE], DC_BG, clip_top, clip_bottom);
        } else {
            fillCell(x, y, MICRO_CELL, MICRO_CELL, 0, true, clip_top, clip_bottom);
        }
        return;
    }
    const elapsed = c.POP_FRAMES - timer;
    if (elapsed < 0) {
        fillCell(x, y, MICRO_CELL, MICRO_CELL, 0, true, clip_top, clip_bottom);
        return;
    }
    fillCell(x, y, MICRO_CELL, MICRO_CELL, color, false, clip_top, clip_bottom);
    drawMicroIcon(x, y, color, clip_top, clip_bottom);
}

// 1px-thick analog of render.drawThemedBand -- "double" degrades to solid
// since there's no room for an inner/outer pair of lines.
fn drawThemedEdge(x: i32, y: i32, len: i32, hues: [2]u8, style: characters.BorderStyle, horizontal: bool) void {
    var i: i32 = 0;
    while (i < len) : (i += 1) {
        const on = switch (style) {
            .solid, .double => true,
            .checkered => @mod(i, 2) == 0,
            .dashed => @mod(i, 7) < 4,
        };
        if (!on) continue;
        const hue_idx: usize = if (hues[0] == hues[1]) 0 else @intCast(@mod(i, 2));
        w4.DRAW_COLORS.* = HUE_DRAWCOLOR[hues[hue_idx]];
        const px = if (horizontal) x + i else x;
        const py = if (horizontal) y else y + i;
        w4.Rect(px, py, 1, 1);
    }
}

// Duplicates render.closingWipedRows exactly (can't import it -- render.zig
// already imports this file); keep the two in sync by hand if either changes.
fn closingWipedRows() u8 {
    if (s.winner == .none) return 0;
    const elapsed = c.CLOSING_TOTAL_FRAMES - s.closing_timer;
    if (elapsed <= 0) return 0;
    const rows = @divTrunc(elapsed, c.CLOSING_FRAMES_PER_ROW);
    return @intCast(@min(rows, c.RING_SIZE));
}

fn drawMicroBoard(b: *s.Board, character: u8, origin_x: i32, origin_y: i32) void {
    const clip_top = origin_y;
    const clip_bottom = origin_y + BOARD_H;
    // Proportional scroll: rescaled from the main board's TILE units to
    // MICRO_TILE units so the rise reads at the same relative pace.
    const micro_scroll = @divTrunc(@as(i32, @intCast(b.scroll_px)) * MICRO_TILE, c.TILE);
    const wiped = closingWipedRows();

    // Starts at SPAWN_ROWS, not 0 -- see render.drawBoard's identical fix for
    // why (rows before that are the offscreen garbage staging area).
    var lr: u8 = c.SPAWN_ROWS;
    while (lr < c.ROWS) : (lr += 1) {
        if (lr - c.SPAWN_ROWS < wiped) continue; // already "popped" by the closing wipe
        const base_y = origin_y + @as(i32, lr - c.SPAWN_ROWS) * MICRO_TILE - micro_scroll;
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
                .popping => drawMicroPopping(x, base_y, cell.color, cell.timer, cell.pre_pop_timer, clip_top, clip_bottom),
                .recycling => drawMicroRecycling(x, base_y, cell.color, cell.timer, cell.pre_pop_timer, cell.garbage_reveals, clip_top, clip_bottom),
                .empty => {},
            }
        }
    }

    const char = characters.ALL[character];
    const w = @as(i32, c.COLS) * MICRO_TILE;
    drawThemedEdge(origin_x - 1, origin_y - 1, w + 2, char.hues, char.border_style, true);
    drawThemedEdge(origin_x - 1, origin_y + BOARD_H, w + 2, char.hues, char.border_style, true);
    drawThemedEdge(origin_x - 1, origin_y - 1, BOARD_H + 2, char.hues, char.border_style, false);
    drawThemedEdge(origin_x + w, origin_y - 1, BOARD_H + 2, char.hues, char.border_style, false);
}

// Same warm dither as the player's cursor (render.drawCursor), just without
// the pulse/contract animation (not worth it at this scale).
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

// Ordinarily s.cpu's own fields, but a versus peer on GAMEPAD2 passes
// s.player's instead (state.versus_render_swapped) -- this file doesn't care.
pub fn draw(board: *s.Board, character: u8, points: u8) void {
    // Framed portrait with score/points squeezed beside it, mirroring the
    // main board's own panel layout (render.drawPanel).
    rchar.drawFrame(c.PANEL_X, LABEL_Y, character);
    rchar.draw(c.PANEL_X, LABEL_Y, character, rchar.stateFor(board), rchar.currentFrame());

    w4.DRAW_COLORS.* = 0x0002;
    var buf: [12]u8 = undefined;
    const score_str = std.fmt.bufPrint(&buf, "{d}", .{board.score}) catch "0";
    w4.Text(score_str, TEXT_X, LABEL_Y + 2);
    // Story mode has no best-of-N series (render.drawPanel's identical
    // guard) -- points are meaningless there, so left blank.
    if (s.game_mode != .story) badge.drawPoints(TEXT_X, LABEL_Y + 10, points);
    // Only when `board` is really `&s.cpu`: a swapped peer's popups were
    // spawned in the full-scale coordinate system, so skip them here.
    if (board == &s.cpu) badge.drawMatchPopups(&board.match_popups, TEXT_X, LABEL_Y + 10);

    drawMicroBoard(board, character, c.PANEL_X, BOARD_Y);
    drawMicroCursor(board, c.PANEL_X, BOARD_Y);
    // In the narrow gutter right of the mini board.
    badge.drawGarbageQueueIcons(c.PANEL_X + @as(i32, c.COLS) * MICRO_TILE + 2, BOARD_Y + 2, board);
}
