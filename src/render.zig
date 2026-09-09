// All drawing: palette setup, the board/cursor/panel, and the title/game-over
// screens. Not unit tested -- everything here bottoms out in WASM4's extern
// draw calls, which only make sense under an actual WASM4 host.
//
// The player's board renders in full detail (bevel, symbols, dither,
// linked-garbage bezel) at its normal size via drawBoard/drawCursor, always
// on `s.player`. The CPU's board shares the exact same simulation but is
// drawn at a simplified micro scale by the companion render_cpu.zig, split
// out to keep this file under the project's ~500-line-per-file guideline.

const std = @import("std");
const c = @import("constants.zig");
const s = @import("state.zig");
const w4 = @import("wasm4.zig");
const sym = @import("symbols.zig");
const badge = @import("render_badge.zig");
const render_cpu = @import("render_cpu.zig");
const rgarbage = @import("render_garbage.zig");
const bg = @import("render_bg.zig");
const characters = @import("characters.zig");
const rchar = @import("render_character.zig");

// nibble values for DRAW_COLORS color1, one per palette slot (index+1)
const DC_BG: u16 = 1;
const HUE_DRAWCOLOR = [3]u16{ 2, 3, 4 };

// Blocks have no border color of their own anymore: just a 1px background
// corner-bevel (see BEVEL_RADIUS) and a 1px background gap between tiles
// (see BLOCK_SIZE), plus a symbol drawn in the background color so shapes
// stay distinguishable even without color.
const FRAME_THICKNESS: i32 = 2;
const FRAME_RADIUS: i32 = 2;
const BEVEL_RADIUS: i32 = 1;
// Each block is drawn 1px smaller than its tile, flush with the tile's
// top-left corner; the unused trailing row/column becomes the 1px gap to the
// next tile, so gaps aren't doubled up between neighbors.
const BLOCK_SIZE: i32 = c.TILE - 1;
const SYMBOL_SIZE: i32 = sym.SYMBOL_SIZE; // same parity as BLOCK_SIZE -> perfectly centered, no remainder

const DITHER_HUES = [2][2]u8{ .{ 0, 1 }, .{ 1, 2 } };

fn ditherHues(color: u8) ?[2]u8 {
    if (color < 3) return null;
    return DITHER_HUES[color - 3];
}


pub fn setupPalette() void {
    w4.PALETTE[0] = 0x1a1c2c; // background
    w4.PALETTE[1] = 0xf97690; // hue A: red
    w4.PALETTE[2] = 0x36e4e7; // hue B: teal (dithers with A -> purple, with C -> green)
    w4.PALETTE[3] = 0xfbef6a; // hue C: yellow
}

pub fn clearBackground() void {
    w4.DRAW_COLORS.* = DC_BG;
    w4.Rect(0, 0, w4.SCREEN_SIZE, w4.SCREEN_SIZE);
}

// Fills a w x h rectangle with a block color: a solid hue, or a 1px
// checkerboard dither blending two hues for colors 3-4.
fn drawColorRect(x: i32, y: i32, w: i32, h: i32, color: u8) void {
    if (w <= 0 or h <= 0) return;
    if (ditherHues(color)) |hues| {
        var dy: i32 = 0;
        while (dy < h) : (dy += 1) {
            var dx: i32 = 0;
            while (dx < w) : (dx += 1) {
                const hue = if (@mod(dx + dy, 2) == 0) hues[0] else hues[1];
                w4.DRAW_COLORS.* = HUE_DRAWCOLOR[hue];
                w4.Rect(x + dx, y + dy, 1, 1);
            }
        }
    } else {
        w4.DRAW_COLORS.* = HUE_DRAWCOLOR[color];
        w4.Rect(x, y, @intCast(w), @intCast(h));
    }
}

// Traces a 1px rectangle outline as a checkerboard dither of two hues,
// pixel by pixel (an outline can't be dithered via a single rect() call the
// way a fill can, since its DRAW_COLORS border nibble is one solid color).
fn drawDitheredRectOutline(x: i32, y: i32, w: i32, h: i32, hues: [2]u8) void {
    if (w <= 0 or h <= 0) return;
    var i: i32 = 0;
    while (i < w) : (i += 1) {
        plotDithered(x + i, y, hues);
        plotDithered(x + i, y + h - 1, hues);
    }
    var j: i32 = 0;
    while (j < h) : (j += 1) {
        plotDithered(x, y + j, hues);
        plotDithered(x + w - 1, y + j, hues);
    }
}

fn plotDithered(x: i32, y: i32, hues: [2]u8) void {
    const hue = if (@mod(x + y, 2) == 0) hues[0] else hues[1];
    w4.DRAW_COLORS.* = HUE_DRAWCOLOR[hue];
    w4.Rect(x, y, 1, 1);
}

fn drawHueSquareCentered(x: i32, y: i32, color: u8, size: i32) void {
    if (size <= 0) return;
    const off = @divTrunc(c.TILE - size, 2);
    drawColorRect(x + off, y + off, size, size, color);
}

fn drawSymbolFor(color: u8, x: i32, y: i32) void {
    w4.DRAW_COLORS.* = DC_BG;
    const rows = sym.SYMBOLS[color];
    for (rows, 0..) |row, ry| {
        for (row, 0..) |ch, rx| {
            if (ch == '#') {
                w4.Rect(x + @as(i32, @intCast(rx)), y + @as(i32, @intCast(ry)), 1, 1);
            }
        }
    }
}

// Fills a w x h block and punches its 4 corner pixels to background color --
// the same chamfer technique as the frame's rounded corners, just at a fixed
// 1px radius -- giving a subtly rounded look instead of a hard square edge.
fn drawBevelledBlock(x: i32, y: i32, w: i32, h: i32, color: u8) void {
    drawColorRect(x, y, w, h, color);
    if (w <= 2 * BEVEL_RADIUS or h <= 2 * BEVEL_RADIUS) return;
    w4.DRAW_COLORS.* = DC_BG;
    var dy: i32 = 0;
    while (dy < BEVEL_RADIUS) : (dy += 1) {
        var dx: i32 = 0;
        while (dx < BEVEL_RADIUS) : (dx += 1) {
            if (dx + dy < BEVEL_RADIUS) {
                w4.Rect(x + dx, y + dy, 1, 1);
                w4.Rect(x + w - 1 - dx, y + dy, 1, 1);
                w4.Rect(x + dx, y + h - 1 - dy, 1, 1);
                w4.Rect(x + w - 1 - dx, y + h - 1 - dy, 1, 1);
            }
        }
    }
}

fn drawNormalCell(x: i32, y: i32, color: u8) void {
    // Flush with the tile's top-left corner; the unused trailing 1px on the
    // right/bottom becomes the gap to the next tile (see BLOCK_SIZE).
    drawBevelledBlock(x, y, BLOCK_SIZE, BLOCK_SIZE, color);
    const sym_off = @divTrunc(BLOCK_SIZE - SYMBOL_SIZE, 2);
    drawSymbolFor(color, x + sym_off, y + sym_off);
}

// A real matched block disappearing (see CellState.popping). Garbage never
// uses this state -- a garbage cell pulled into the same event instead
// recycles (see drawRecyclingCell below), which has no animation of its own.
fn drawPoppingCell(x: i32, y: i32, color: u8, timer: i16, pre_pop_timer: i16) void {
    if (pre_pop_timer > 0) {
        // The whole group's shared pre-pop preamble (see Cell.pre_pop_timer)
        // -- every member of the match is in this same phase simultaneously,
        // not staggered like the pop cascade below: first a hard on/off
        // blink every single frame (distinct from the size-wobble flash
        // below, which stays visible the whole time), then a short steady
        // pause looking perfectly normal -- a heads-up cue that this cell is
        // about to pop, before the actual (staggered) pop cascade begins.
        const elapsed = c.PRE_POP_TOTAL_FRAMES - pre_pop_timer;
        if (elapsed < c.PRE_POP_BLINK_FRAMES) {
            if (@mod(elapsed, 2) == 0) drawNormalCell(x, y, color);
        } else {
            drawNormalCell(x, y, color);
        }
        return;
    }
    const elapsed = c.POP_FRAMES - timer;
    if (elapsed < 0) {
        // Still waiting its turn in the pop cascade (see POP_STAGGER_FRAMES)
        // -- render exactly like a settled block until then.
        drawNormalCell(x, y, color);
        return;
    }
    var size: i32 = BLOCK_SIZE;
    if (elapsed < c.POP_FLASH_FRAMES) {
        const puls: i32 = @intCast(@mod(elapsed, 8));
        const delta: i32 = if (puls < 4) puls else 8 - puls;
        size = BLOCK_SIZE - delta;
    } else {
        const shrink_elapsed = elapsed - c.POP_FLASH_FRAMES;
        const shrink_total = c.POP_FRAMES - c.POP_FLASH_FRAMES;
        const remain = shrink_total - shrink_elapsed;
        size = @divTrunc(BLOCK_SIZE * remain, shrink_total);
        if (size < 0) size = 0;
    }
    drawHueSquareCentered(x, y, color, size);
}

// A garbage cell being recycled (see CellState.recycling). Unlike a real
// match's pop, there's no shrink/flash animation: a garbage cell in a
// recycling group that's actually going to convert (see Cell.garbage_reveals
// -- a clump taller than one row only ever converts its bottom-most row per
// event, see sim.checkMatches) is revealed one at a time, with a delay
// between each (its own staggered timer, same mechanism as the pop cascade
// -- see POP_STAGGER_FRAMES), and the instant its own turn comes it just
// hard-cuts to looking like a plain normal block and stays that way,
// inactive, doing nothing further, until the whole group resolves (see
// sim.simulate). A non-converting cell (the rest of a taller clump) never
// reaches that reveal at all -- it just keeps looking like inert garbage
// through its own staggered turn and beyond, having only ever played the
// shared flash/pause preamble as a heads-up. Before its own turn (including
// the pre-pop blink+pause preamble -- see PRE_POP_TOTAL_FRAMES), it still
// looks like part of the not-yet-recycled garbage clump (see
// render_garbage's isAttached, which keys off this same timer -- and
// garbage_reveals -- to know when to stop treating it as attached).
fn drawRecyclingCell(x: i32, y: i32, color: u8, timer: i16, edges: rgarbage.Edges, pre_pop_timer: i16, garbage_reveals: bool) void {
    if (pre_pop_timer > 0) {
        // The whole group's shared pre-pop preamble (see Cell.pre_pop_timer
        // and drawPoppingCell above) -- blink (hard on/off every frame) then
        // a short steady pause, both still showing the inert/attached
        // garbage look; the actual reveal only happens once the preamble
        // finishes and this cell's own staggered turn comes up.
        const elapsed = c.PRE_POP_TOTAL_FRAMES - pre_pop_timer;
        if (elapsed < c.PRE_POP_BLINK_FRAMES) {
            if (@mod(elapsed, 2) == 0) rgarbage.drawLinked(x, y, edges);
        } else {
            rgarbage.drawLinked(x, y, edges);
        }
        return;
    }
    if (!garbage_reveals) {
        // Purely cosmetic: this row isn't actually converting or clearing
        // (see Cell.garbage_reveals), but it should still visibly read as
        // being processed for the same span a genuine reveal would take --
        // a flash (phase-inverted checkerboard, alternating with the normal
        // look) rather than sitting there looking untouched while the rest
        // of the group pops -- then back to its ordinary inert look once
        // that span elapses, since it never actually resolves to anything
        // else.
        const elapsed = c.POP_FRAMES - timer;
        if (elapsed < 0 or elapsed >= c.POP_FRAMES) {
            rgarbage.drawLinked(x, y, edges);
        } else if (@mod(elapsed, 8) < 4) {
            rgarbage.drawLinkedFlash(x, y, edges);
        } else {
            rgarbage.drawLinked(x, y, edges);
        }
        return;
    }
    const elapsed = c.POP_FRAMES - timer;
    if (elapsed < 0) {
        rgarbage.drawLinked(x, y, edges);
        return;
    }
    drawNormalCell(x, y, color);
}

fn drawLandingCell(x: i32, y: i32, color: u8, timer: i16, is_garbage: bool, edges: rgarbage.Edges) void {
    const elapsed = c.LAND_FRAMES - timer;
    const squash: i32 = if (elapsed < 3) (3 - @as(i32, elapsed)) * 2 else 0;
    const height = BLOCK_SIZE - squash;
    if (is_garbage) {
        // A connected clump lands (and squash-bounces) in lockstep -- see
        // sim.zig's group-based gravity -- so this stays a seamless slab
        // through the bounce too, not just at rest.
        const w: i32 = if (edges.right) BLOCK_SIZE + 1 else BLOCK_SIZE;
        rgarbage.drawGarbageRect(x, y + squash, w, height);
        w4.DRAW_COLORS.* = DC_BG;
        if (!edges.up and !edges.left) w4.Rect(x, y + squash, 1, 1);
        if (!edges.up and !edges.right) w4.Rect(x + w - 1, y + squash, 1, 1);
        if (!edges.down and !edges.left) w4.Rect(x, y + squash + height - 1, 1, 1);
        if (!edges.down and !edges.right) w4.Rect(x + w - 1, y + squash + height - 1, 1, 1);
        return;
    }
    drawBevelledBlock(x, y + squash, BLOCK_SIZE, height, color);
    if (squash == 0) {
        const sym_off = @divTrunc(BLOCK_SIZE - SYMBOL_SIZE, 2);
        drawSymbolFor(color, x + sym_off, y + sym_off);
    }
}

fn drawSwappingCell(x: i32, y: i32, color: u8, timer: i16, dir: i8) void {
    const offset: i32 = @as(i32, dir) * @divTrunc(c.TILE * @as(i32, timer), c.SWAP_FRAMES);
    drawNormalCell(x + offset, y, color);
}

// A column with any content within this many rows of the ceiling (see
// board.updateDangerTimer's game-over check, at logical row SPAWN_ROWS) is
// close enough to the rise hazard that its settled blocks bounce in place as
// a warning -- matching other Panel de Pon clients' more generous warning
// zone (a few rows of headroom before the stack is actually touching the
// top) now that the full 12-row board gives room for it, rather than only
// reacting once a column is already touching the very top row.
const STRESS_WARNING_ROWS: u8 = 3;
const STRESS_BOUNCE_PERIOD: i32 = 16;
const STRESS_BOUNCE_AMOUNT: i32 = 3;

fn isColumnStressed(b: *s.Board, col: u8) bool {
    var lr: u8 = 0;
    while (lr < STRESS_WARNING_ROWS) : (lr += 1) {
        if (b.cellAt(c.SPAWN_ROWS + lr, col).state != .empty) return true;
    }
    return false;
}

fn stressBounceOffset() i32 {
    // A quick, repeating upward hop -- reads as an agitated wobble, distinct
    // from the cursor's gentler contract/expand pulse.
    const half = @divTrunc(STRESS_BOUNCE_PERIOD, 2);
    const t: i32 = @intCast(@mod(s.frame_count, @as(u32, @intCast(STRESS_BOUNCE_PERIOD))));
    const tri: i32 = if (t < half) t else STRESS_BOUNCE_PERIOD - t;
    return -@divTrunc(tri * STRESS_BOUNCE_AMOUNT, half);
}

// The board's own visible area ends here vertically -- VISIBLE_ROWS*TILE no
// longer happens to equal SCREEN_SIZE now that the board isn't always
// exactly as tall as the screen, so this can't just be WASM4's SCREEN_SIZE
// anymore. Used both to skip rows that are entirely below it (drawBoard)
// and to mask over the bit of any row that's only *partially* below it
// (maskBelowBoard) -- WASM4's rect() has no clip-region support, so a row
// that's mid-scroll and still partly in bounds draws its *entire* tile
// height regardless of where board_bottom falls across it.
const BOARD_BOTTOM: i32 = c.BOARD_Y + @as(i32, c.VISIBLE_ROWS) * c.TILE;

// How many rows (from the ceiling down) the closing "match over" wipe has
// already popped -- see state.closing_timer/board.beginClosing, ticked down
// once per frame in main.zig once `winner` leaves .none. `.none` outside
// that window keeps this permanently 0, so drawBoard/drawMicroBoard's own
// wipe check below is a no-op during ordinary gameplay. Purely a rendering
// skip -- nothing here ever touches either Board's actual grid, so there's
// no risk of this interfering with (or surviving past) the match itself.
pub fn closingWipedRows() u8 {
    if (s.winner == .none) return 0;
    const elapsed = c.CLOSING_TOTAL_FRAMES - s.closing_timer;
    if (elapsed <= 0) return 0;
    const rows = @divTrunc(elapsed, c.CLOSING_FRAMES_PER_ROW);
    return @intCast(@min(rows, c.RING_SIZE));
}

// Full-detail board rendering -- always `s.player`, at the normal board
// position/scale. See render_cpu.zig for the CPU's simplified equivalent.
fn drawBoard(b: *s.Board) void {
    var col_stressed: [c.COLS]bool = undefined;
    for (0..c.COLS) |ci| col_stressed[ci] = isColumnStressed(b, @intCast(ci));
    const bounce = stressBounceOffset();
    const wiped = closingWipedRows();

    // Starts at SPAWN_ROWS, not 0 -- rows before that are the offscreen
    // garbage staging area (see constants.SPAWN_ROWS/Board.physRow), never
    // meant to be drawn at all.
    var lr: u8 = c.SPAWN_ROWS;
    while (lr < c.ROWS) : (lr += 1) {
        if (lr - c.SPAWN_ROWS < wiped) continue; // already "popped" by the closing wipe
        const base_y = c.BOARD_Y + @as(i32, lr - c.SPAWN_ROWS) * c.TILE - @as(i32, @intCast(b.scroll_px));
        if (base_y + c.TILE <= c.BOARD_Y or base_y >= BOARD_BOTTOM) continue;
        var col: u8 = 0;
        while (col < c.COLS) : (col += 1) {
            const cell = b.cellAt(lr, col);
            const x = c.BOARD_X + @as(i32, col) * c.TILE;
            switch (cell.state) {
                .normal => {
                    // Only settled blocks bounce -- cells already mid
                    // animation (falling/landing/popping/swapping) keep
                    // their own motion undisturbed.
                    const y = if (col_stressed[col]) base_y + bounce else base_y;
                    if (cell.is_garbage) rgarbage.drawLinked(x, y, rgarbage.edgesAt(b, lr, col)) else drawNormalCell(x, y, cell.color);
                },
                .falling => {
                    const y = base_y - cell.fall_off;
                    if (cell.is_garbage) rgarbage.drawLinked(x, y, rgarbage.edgesAt(b, lr, col)) else drawNormalCell(x, y, cell.color);
                },
                .popping => drawPoppingCell(x, base_y, cell.color, cell.timer, cell.pre_pop_timer),
                .recycling => drawRecyclingCell(x, base_y, cell.color, cell.timer, rgarbage.edgesAt(b, lr, col), cell.pre_pop_timer, cell.garbage_reveals),
                .landing => drawLandingCell(x, base_y, cell.color, cell.timer, cell.is_garbage, rgarbage.edgesAt(b, lr, col)),
                .swapping => drawSwappingCell(x, base_y, cell.color, cell.timer, cell.swap_dir),
                .empty => {},
            }
            // The one hidden ring-buffer row (see sim_matches.HIDDEN_ROW):
            // not yet promoted into the lowest accessible row, so a sparse
            // dither overlay marks the whole row as still "arriving" --
            // clearing the instant a rise actually promotes it (at which
            // point this same content renders one `lr` lower and no longer
            // matches this check at all).
            if (lr == c.ROWS - 1) {
                var dy: i32 = 0;
                while (dy < c.TILE) : (dy += 1) {
                    var dx: i32 = 0;
                    while (dx < c.TILE) : (dx += 1) {
                        if (@mod(dx + dy, 2) != 0) continue;
                        w4.DRAW_COLORS.* = DC_BG;
                        w4.Rect(x + dx, base_y + dy, 1, 1);
                    }
                }
            }
        }
    }
}

// Covers over whatever drawBoard just drew below BOARD_BOTTOM -- a row
// mid-scroll can be only partly in bounds, but still draws its whole tile
// height regardless (see BOARD_BOTTOM's comment), so without this the
// incoming row would visibly poke out past the frame's bottom edge instead
// of staying hidden until it's actually risen into view. A plain
// background-colored fill is enough since it's the exact same color the
// rest of the screen outside the board already is.
fn maskBelowBoard() void {
    const screen: i32 = @intCast(w4.SCREEN_SIZE);
    if (BOARD_BOTTOM >= screen) return; // nothing below the board to mask
    w4.DRAW_COLORS.* = DC_BG;
    w4.Rect(0, BOARD_BOTTOM, @intCast(c.PANEL_X), @intCast(screen - BOARD_BOTTOM));
}

// Fills one edge band of the frame (a w x h strip, `horizontal` true for
// the top/bottom bands where the pattern repeats along x, false for
// left/right where it repeats along y) according to the current player's
// chosen character's own border style (see characters.BorderStyle) --
// "their own style of menu border for the main frame". A two-hue character
// dithers between its pair everywhere the style would otherwise show a
// single solid hue.
fn drawThemedBand(x: i32, y: i32, w: i32, h: i32, hues: [2]u8, style: characters.BorderStyle, horizontal: bool) void {
    const len = if (horizontal) w else h;
    const thick = if (horizontal) h else w;
    var i: i32 = 0;
    while (i < len) : (i += 1) {
        var j: i32 = 0;
        while (j < thick) : (j += 1) {
            const on = switch (style) {
                .solid => true,
                .checkered => @mod(i + j, 2) == 0,
                .dashed => @mod(i, 7) < 4,
                .double => j == 0 or j == thick - 1,
            };
            if (!on) continue;
            const hue_idx: usize = if (hues[0] == hues[1]) 0 else @intCast(@mod(i + j, 2));
            w4.DRAW_COLORS.* = HUE_DRAWCOLOR[hues[hue_idx]];
            const px = if (horizontal) x + i else x + j;
            const py = if (horizontal) y + j else y + i;
            w4.Rect(px, py, 1, 1);
        }
    }
}

// A plain (unchamfered) themed border around an arbitrary panel -- used by
// the setup screen to retheme itself to whichever character is currently
// selected (see drawSetupScreen), the same color+pattern treatment
// drawFrame below gives the real game board.
fn drawThemedPanelBorder(x: i32, y: i32, w: i32, h: i32, char: characters.Character) void {
    const t = FRAME_THICKNESS;
    drawThemedBand(x, y, w, t, char.hues, char.border_style, true);
    drawThemedBand(x, y + h - t, w, t, char.hues, char.border_style, true);
    drawThemedBand(x, y, t, h, char.hues, char.border_style, false);
    drawThemedBand(x + w - t, y, t, h, char.hues, char.border_style, false);
}

// Frame around the playable area with a 2px-radius chamfer at each corner
// (WASM-4's rect() has no rounded-corner support, so the corners are faked
// by punching a small diagonal notch out of the frame in the background
// color).
fn drawFrame() void {
    // Pushed out from the board's own bounding box so the frame doesn't
    // overlap the edge tiles' own fill. Horizontally there's margin to
    // spare, so it's pushed out by the full frame thickness -- plus 1 extra
    // on the left, since blocks are flush with their tile's top-left corner
    // (only the right/bottom get a natural 1px gap from BLOCK_SIZE), so
    // without that extra px the left edge would sit flush against the first
    // column's fill while the right edge already clears the last column's
    // fill by a pixel. There is no vertical margin (the board fills the
    // screen height exactly), so it's pushed out by only 1px on top/bottom --
    // any more would push it fully off-screen and make it invisible rather
    // than just less overlapping.
    const push_left = FRAME_THICKNESS + 1;
    const push_right = FRAME_THICKNESS;
    const push_y = 1;
    const x = c.BOARD_X - push_left;
    const y = c.BOARD_Y - push_y;
    const w = @as(i32, c.COLS) * c.TILE + push_left + push_right;
    const h = @as(i32, c.VISIBLE_ROWS) * c.TILE + 2 * push_y;
    const t = FRAME_THICKNESS;
    const radius = FRAME_RADIUS;

    const char = characters.ALL[s.player_character];
    drawThemedBand(x, y, w, t, char.hues, char.border_style, true); // top
    drawThemedBand(x, y + h - t, w, t, char.hues, char.border_style, true); // bottom
    drawThemedBand(x, y, t, h, char.hues, char.border_style, false); // left
    drawThemedBand(x + w - t, y, t, h, char.hues, char.border_style, false); // right

    w4.DRAW_COLORS.* = DC_BG;
    var dy: i32 = 0;
    while (dy < radius) : (dy += 1) {
        var dx: i32 = 0;
        while (dx < radius) : (dx += 1) {
            if (dx + dy < radius) {
                w4.Rect(x + dx, y + dy, 1, 1); // top-left
                w4.Rect(x + w - 1 - dx, y + dy, 1, 1); // top-right
                w4.Rect(x + dx, y + h - 1 - dy, 1, 1); // bottom-left
                w4.Rect(x + w - 1 - dx, y + h - 1 - dy, 1, 1); // bottom-right
            }
        }
    }
}

const CURSOR_THICKNESS: i32 = 2;
const CURSOR_PULSE_PERIOD: i32 = 30;
const CURSOR_PULSE_AMOUNT: i32 = 2;

const CURSOR_PUSH: i32 = 1;
const CURSOR_DITHER_HUES = badge.WARM_DITHER_HUES;

// Always the player's own cursor -- the CPU has no cursor to show (its board
// is drawn too small for one to read well, and it has no real input anyway).
// Hidden while touch is the active input method (see state.cursor_hidden) --
// swipes move it relative to wherever it already is rather than aiming at a
// touched tile, so there's nothing the player needs to see it for.
fn drawCursor() void {
    if (s.winner != .none or s.cursor_hidden) return;
    const base_x = c.BOARD_X + @as(i32, s.player.cursor_col) * c.TILE;
    const base_y = c.BOARD_Y + @as(i32, s.player.cursor_row) * c.TILE - @as(i32, @intCast(s.player.scroll_px));

    // Blink by contracting slightly instead of changing color -- driven by
    // cursor_idle_frames (time since the cursor last actually moved), not
    // raw frame_count, and phase-shifted so idle_frames == 0 lands right on
    // the most-contracted point of the cycle: the cursor snaps to its
    // small, settled outline the instant it moves, eases back out over the
    // next half-period, and only starts ambiently blinking again if it's
    // still sitting there once that resolves -- a fast-playing player never
    // sees it blink at all.
    const half = @divTrunc(CURSOR_PULSE_PERIOD, 2);
    const t: i32 = @intCast(@mod(s.cursor_idle_frames + @as(u32, @intCast(half)), @as(u32, @intCast(CURSOR_PULSE_PERIOD))));
    const tri: i32 = if (t < half) t else CURSOR_PULSE_PERIOD - t;
    var contract = @divTrunc(tri * CURSOR_PULSE_AMOUNT, half);

    // A quick, deliberate extra squeeze right when a swap actually goes
    // through (state.cursor_swap_flash, set in input.zig) -- distinct
    // feedback from the ambient idle blink above, on top of it rather than
    // replacing it.
    if (s.cursor_swap_flash > 0) contract += 2;

    // Pushed out so the cursor straddles the boundary of its two tiles and
    // the surrounding ones, rather than tracing exactly over them. Blocks
    // are flush with their tile's top-left corner (only the right/bottom
    // get a natural 1px gap from BLOCK_SIZE), so a push of the same size on
    // every side would land right on a neighbor's fill on the right/bottom
    // but fall a pixel short into the gap on the top/left. The extra 1px on
    // top/left makes it reach the neighboring fill the same amount on every
    // side.
    const push_left = CURSOR_PUSH + 1 - contract;
    const push_top = CURSOR_PUSH + 1 - contract;
    const push_right = CURSOR_PUSH - contract;
    const push_bottom = CURSOR_PUSH - contract;
    const x = base_x - push_left;
    const y = base_y - push_top;
    const w = c.TILE * 2 + push_left + push_right;
    const h = c.TILE + push_top + push_bottom;

    // A background-colored outline reads as invisible against the (also
    // dark) background whenever the cursor sits over empty board space, so
    // it's drawn as a 1px checkerboard dither of red and yellow instead --
    // both bright, and never the same as the background either way.
    drawDitheredRectOutline(x, y, w, h, CURSOR_DITHER_HUES);
    if (w > 2 and h > 2) {
        drawDitheredRectOutline(x + 1, y + 1, w - 2, h - 2, CURSOR_DITHER_HUES);
    }

    // A small crosshair right at the boundary between the cursor's two
    // tiles, so its exact center reads clearly even while it's contracted
    // or mid-pulse.
    const cx = base_x + c.TILE;
    const cy = base_y + @divTrunc(c.TILE, 2);
    var i: i32 = -2;
    while (i <= 2) : (i += 1) {
        plotDithered(cx + i, cy, CURSOR_DITHER_HUES);
        plotDithered(cx, cy + i, CURSOR_DITHER_HUES);
    }
}

// The player's own character portrait, animated per render_character.zig,
// plus score/chain/combo/points squeezed in beside and below it -- the
// label text ("SCORE") is dropped entirely and the rest shrunk down, since
// the portrait and its reaction to what's actually happening is the more
// important thing on screen now (see this project's own commit history for
// why -- this used to be a "SCORE" label above the number, on its own line).
fn drawPanel() void {
    rchar.draw(c.PANEL_X, 0, s.player_character, rchar.stateFor(&s.player), rchar.currentFrame());

    const text_x = c.PANEL_X + rchar.H + 2;
    w4.DRAW_COLORS.* = 0x0002;
    var buf: [12]u8 = undefined;
    const score_str = std.fmt.bufPrint(&buf, "{d}", .{s.player.score}) catch "0";
    w4.Text(score_str, text_x, 2);
    badge.drawPoints(text_x, 10, s.player_points);

    // Chain and combo share this one spot rather than each getting their own
    // line -- chain takes priority when both are true (same precedence as
    // the floating badge's own label choice in sim_matches.checkMatches),
    // since it's the rarer, more meaningful feat. A combo has no ongoing
    // Board state the way chain does -- just a recent-event flag
    // (Board.combo_display_timer, ticked down once per frame in
    // sim.simulate) -- so on its own it reads as a lingering callout rather
    // than something that stays up for as long as a condition holds.
    if (s.player.chain > 1) {
        var buf2: [12]u8 = undefined;
        const chain_str = std.fmt.bufPrint(&buf2, "x{d}", .{s.player.chain}) catch "";
        w4.DRAW_COLORS.* = 0x0004;
        w4.Text(chain_str, c.PANEL_X, rchar.H + 2);
    } else if (s.player.combo_display_timer > 0) {
        w4.DRAW_COLORS.* = 0x0004;
        w4.Text("COMBO", c.PANEL_X, rchar.H + 2);
    }
}

// A slow sine-wave offset -- gives the menu panel below a gentle, alive
// bobbing motion ("personality") rather than sitting dead still, distinct
// from every other motion in the game (which all use a triangle-wave/linear
// ease -- see stressBounceOffset, drawCursor's pulse -- since a menu panel
// idling for a long time is the one place a true sinusoid's smoothness is
// worth the float math over the cheaper approximations used elsewhere).
fn menuSinOffset(period_frames: i32, amplitude_px: i32) i32 {
    const t: f32 = @floatFromInt(@mod(s.frame_count, @as(u32, @intCast(period_frames))));
    const phase = t / @as(f32, @floatFromInt(period_frames)) * std.math.tau;
    return @intFromFloat(@sin(phase) * @as(f32, @floatFromInt(amplitude_px)));
}

const MENU_PANEL_X: i32 = 20;
const MENU_PANEL_W: i32 = 120;
const MENU_SIN_PERIOD: i32 = 180; // 3s
const MENU_SIN_AMOUNT: i32 = 4;

fn menuPanelY(base_y: i32) i32 {
    return base_y + menuSinOffset(MENU_SIN_PERIOD, MENU_SIN_AMOUNT);
}

// Common backdrop for both pre-game screens: the parallaxing background
// (see render_bg.zig) plus the panel's own fill, gently bobbing (see
// menuPanelY) -- callers draw their own border (the title screen's neutral
// bezel vs. the setup screen's character-themed one) and content into the
// returned Y. `base_y`/`h` differ between the two screens (setup has more
// to fit), so both are the caller's own choice rather than shared
// constants.
fn drawMenuPanelFill(base_y: i32, h: i32) i32 {
    bg.draw();
    const y = menuPanelY(base_y);
    w4.DRAW_COLORS.* = 0x0001;
    w4.Rect(MENU_PANEL_X, y, MENU_PANEL_W, @intCast(h));
    return y;
}

pub fn drawTitleScreen() void {
    const y = drawMenuPanelFill(30, 100);
    drawPanelBorder(MENU_PANEL_X, y, MENU_PANEL_W, 100);
    w4.DRAW_COLORS.* = 0x0003;
    w4.Text("PANELPON4", 40, y + 24);
    w4.DRAW_COLORS.* = 0x0002;
    w4.Text("PRESS X", 52, y + 64);
}

// One filled-in segment per difficulty level (1-10), replacing the old
// plain "LEVEL {d}" text with something that reads at a glance without
// needing to parse a number.
fn drawDifficultyBar(x: i32, y: i32) void {
    var i: u8 = 1;
    while (i <= 10) : (i += 1) {
        const px = x + @as(i32, i - 1) * 8;
        if (i <= s.difficulty) {
            w4.DRAW_COLORS.* = 0x0004;
            w4.Rect(px, y, 6, 6);
        } else {
            w4.DRAW_COLORS.* = 0x0002;
            w4.Rect(px, y, 6, 1);
            w4.Rect(px, y + 5, 6, 1);
            w4.Rect(px, y, 1, 6);
            w4.Rect(px + 5, y, 1, 6);
        }
    }
}

// Left edge of each of the 4 portraits in the setup screen's character row
// -- evenly spaced, centered in the panel's own width.
const CHAR_SLOT_GAP: i32 = 8;
const CHAR_ROW_W: i32 = characters.COUNT * rchar.W + (characters.COUNT - 1) * CHAR_SLOT_GAP;
fn charSlotX(index: u8) i32 {
    const start = MENU_PANEL_X + @divTrunc(MENU_PANEL_W - CHAR_ROW_W, 2);
    return start + @as(i32, index) * (rchar.W + CHAR_SLOT_GAP);
}

pub fn drawSetupScreen() void {
    const y = drawMenuPanelFill(14, 140);
    // Retheme the panel border itself to whichever character is currently
    // selected -- "switching should retheme the setup menu".
    drawThemedPanelBorder(MENU_PANEL_X, y, MENU_PANEL_W, 140, characters.ALL[s.player_character]);

    w4.DRAW_COLORS.* = 0x0003;
    w4.Text("SETUP", 58, y + 6);
    w4.DRAW_COLORS.* = 0x0002;
    w4.Text("CHARACTER", 40, y + 18);

    // All 4 characters are shown at once (not just the current pick) --
    // up/down cycles the player's own selection (see main.zig), highlighted
    // with a dithered outline; the CPU's own auto-pick (always a different
    // one -- see characters.cpuPickFor) is marked with a small arrow above
    // it instead, never itself selectable.
    const frame = rchar.currentFrame();
    const row_y = y + 34;
    for (0..characters.COUNT) |i| {
        const cx = charSlotX(@intCast(i));
        rchar.draw(cx, row_y, @intCast(i), .normal, frame);
        if (i == s.player_character) {
            drawDitheredRectOutline(cx - 2, row_y - 2, rchar.W + 4, rchar.H + 4, badge.WARM_DITHER_HUES);
        }
        if (i == s.cpu_character) {
            w4.DRAW_COLORS.* = 0x0004;
            w4.Rect(cx + @divTrunc(rchar.W, 2) - 1, row_y - 5, 3, 1);
            w4.Rect(cx + @divTrunc(rchar.W, 2) - 2, row_y - 4, 5, 1);
        }
    }

    w4.DRAW_COLORS.* = 0x0002;
    var buf2: [24]u8 = undefined;
    const you_label = std.fmt.bufPrint(&buf2, "YOU: {s}", .{characters.ALL[s.player_character].name}) catch "YOU";
    w4.Text(you_label, 28, row_y + rchar.H + 6);
    w4.DRAW_COLORS.* = 0x0004;
    var buf3: [24]u8 = undefined;
    const cpu_label = std.fmt.bufPrint(&buf3, "CPU: {s}", .{characters.ALL[s.cpu_character].name}) catch "CPU";
    w4.Text(cpu_label, 28, row_y + rchar.H + 16);
    w4.DRAW_COLORS.* = 0x0002;
    w4.Text("^ up   down v", 30, row_y + rchar.H + 28);

    w4.Text("DIFFICULTY", 40, y + 96);
    drawDifficultyBar(40, y + 108);
    var buf: [24]u8 = undefined;
    // Every level runs cpu_engine's actual move search -- see
    // cpu_ai.configFor -- lower levels just listen to it far less reliably.
    const label = std.fmt.bufPrint(&buf, "LEVEL {d}", .{s.difficulty}) catch "LEVEL ?";
    w4.Text(label, 58, y + 120);
    w4.Text("<-      ->", 40, y + 132);
    w4.Text("PRESS X", 52, y + 144);
}

// Bezeled orange border for a full-screen overlay panel (the countdown and
// match-over screens): two concentric dithered outlines for a raised bezel
// look (the same technique drawCursor uses), plus a 1px black (background)
// outline just outside that so the bezel itself reads clearly against
// whatever's behind the panel -- the board, mid-scroll or otherwise --
// rather than risking blending into it the way a single flat-colored edge
// might.
fn drawPanelBorder(x: i32, y: i32, w: i32, h: i32) void {
    w4.DRAW_COLORS.* = DC_BG;
    w4.Rect(x - 1, y - 1, @intCast(w + 2), 1);
    w4.Rect(x - 1, y + h, @intCast(w + 2), 1);
    w4.Rect(x - 1, y - 1, 1, @intCast(h + 2));
    w4.Rect(x + w, y - 1, 1, @intCast(h + 2));

    drawDitheredRectOutline(x, y, w, h, badge.WARM_DITHER_HUES);
    if (w > 2 and h > 2) {
        drawDitheredRectOutline(x + 1, y + 1, w - 2, h - 2, badge.WARM_DITHER_HUES);
    }
}

// Only ever shown once the closing wipe (state.closing_timer, see
// board.beginClosing) has finished popping every row -- see main.zig, which
// gates the call on that -- so the loss reads as "board clears, then the
// verdict appears", not both at once. Shows this one match's own result
// plus the running series score always, and -- once state.set_winner says
// the whole best-of-N series is decided (see board.awardMatchPoint) -- who
// took the series instead of just prompting to continue it.
pub fn drawGameOver() void {
    const text: []const u8 = switch (s.winner) {
        .player => "YOU WIN",
        .cpu => "YOU LOSE",
        .draw => "DRAW",
        .none => unreachable, // drawGameOver is only ever called once winner != .none
    };
    const x = 20;
    const y = 52;
    const w = 120;
    const h = 68;
    w4.DRAW_COLORS.* = 0x0001;
    w4.Rect(x, y, w, h);
    drawPanelBorder(x, y, w, h);

    // Both characters stay visible through the transition -- the winning
    // side celebrating on the right, the losing side wincing on the left
    // (a draw shows both idle, since neither actually won or lost).
    const frame = rchar.currentFrame();
    const player_state: rchar.CharState = switch (s.winner) {
        .player => .win,
        .cpu => .punish,
        .draw, .none => .normal,
    };
    const cpu_state: rchar.CharState = switch (s.winner) {
        .cpu => .win,
        .player => .punish,
        .draw, .none => .normal,
    };
    rchar.draw(x + 4, y + 4, s.player_character, player_state, frame);
    rchar.draw(x + w - rchar.W - 4, y + 4, s.cpu_character, cpu_state, frame);

    w4.DRAW_COLORS.* = 0x0004;
    w4.Text("MATCH OVER", 40, 58);
    w4.Text(text, 32, 74);

    var buf: [16]u8 = undefined;
    const pts = std.fmt.bufPrint(&buf, "{d} - {d}", .{ s.player_points, s.cpu_points }) catch "";
    w4.DRAW_COLORS.* = 0x0002;
    w4.Text(pts, 64, 84);

    if (s.set_winner != .none) {
        const set_text: []const u8 = if (s.set_winner == .player) "YOU WIN THE SET!" else "CPU WINS THE SET!";
        w4.DRAW_COLORS.* = 0x0004;
        w4.Text(set_text, 12, 96);
        w4.DRAW_COLORS.* = 0x0002;
        w4.Text("PRESS X", 40, 106);
    } else {
        w4.DRAW_COLORS.* = 0x0002;
        w4.Text("PRESS X", 40, 98);
    }
}

// "3 2 1 START" shown once per match, right after resetGame -- see
// state.countdown_timer (which this turns back into "which stage, how far
// into it") and board.beginCountdown, the only place that gets set. "3",
// "2", "1" each rise a couple pixels then hold steady for about a second;
// "START" rises the same way but then blinks a few times instead of holding
// steady.
pub fn drawCountdown() void {
    const elapsed = c.COUNTDOWN_TOTAL_FRAMES - s.countdown_timer;

    var label: []const u8 = "3";
    var stage_elapsed: i32 = elapsed;
    var is_start = false;
    if (elapsed < c.COUNTDOWN_NUMBER_FRAMES) {
        label = "3";
    } else if (elapsed < c.COUNTDOWN_NUMBER_FRAMES * 2) {
        label = "2";
        stage_elapsed = elapsed - c.COUNTDOWN_NUMBER_FRAMES;
    } else if (elapsed < c.COUNTDOWN_NUMBER_FRAMES * 3) {
        label = "1";
        stage_elapsed = elapsed - c.COUNTDOWN_NUMBER_FRAMES * 2;
    } else {
        label = "START";
        stage_elapsed = elapsed - c.COUNTDOWN_NUMBER_FRAMES * 3;
        is_start = true;
    }

    // Eases up from a couple pixels below its resting spot, then either
    // holds there steady (numbers) or blinks a few times (START) -- see
    // this function's own doc comment.
    var visible = true;
    var rise_offset: i32 = 0;
    if (stage_elapsed < c.COUNTDOWN_RISE_FRAMES) {
        const remain = c.COUNTDOWN_RISE_FRAMES - stage_elapsed;
        rise_offset = @divTrunc(remain * c.COUNTDOWN_RISE_PX, c.COUNTDOWN_RISE_FRAMES);
    } else if (is_start) {
        const blink_elapsed = stage_elapsed - c.COUNTDOWN_RISE_FRAMES;
        const phase = @divTrunc(blink_elapsed, c.COUNTDOWN_BLINK_HALF_FRAMES);
        visible = @mod(phase, 2) == 0;
    }
    if (!visible) return;

    const char_w: i32 = 8;
    const text_w: i32 = @as(i32, @intCast(label.len)) * char_w;
    const cx: i32 = 80; // screen center (SCREEN_SIZE/2)
    const base_y: i32 = 70;
    const y = base_y - rise_offset;
    const pad: i32 = 8;
    const box_x = cx - @divTrunc(text_w, 2) - pad;
    const box_y = y - 6;
    const box_w = text_w + 2 * pad;
    const box_h = char_w + 12;

    w4.DRAW_COLORS.* = 0x0001;
    w4.Rect(box_x, box_y, @intCast(box_w), @intCast(box_h));
    drawPanelBorder(box_x, box_y, box_w, box_h);
    w4.DRAW_COLORS.* = 0x0004;
    w4.Text(label, cx - @divTrunc(text_w, 2), y);
}

pub fn render() void {
    clearBackground();
    drawBoard(&s.player);
    maskBelowBoard();
    drawFrame();
    drawCursor();
    drawPanel();
    badge.drawMatchPopups(&s.player.match_popups);
    // In the gutter between the player's own frame and the panel column.
    badge.drawGarbageQueueIcons(96, c.BOARD_Y + 4, &s.player);
    render_cpu.draw();
}
