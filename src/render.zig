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

// Like drawSymbolFor, but the glyph itself is vertically compressed into
// (SYMBOL_SIZE - squash) rows (simple nearest-row sampling) and the result
// re-centered within the normal SYMBOL_SIZE-tall space -- the panic squish
// (see PANIC_SQUISH_AMOUNT/drawNormalCell) squishes only the symbol, never
// the block it's drawn on, so this leaves the block's own bevel/fill
// completely untouched -- only the glyph inside it looks compressed.
fn drawSymbolSquished(color: u8, x: i32, y: i32, squash: i32) void {
    if (squash <= 0) {
        drawSymbolFor(color, x, y);
        return;
    }
    const new_h = SYMBOL_SIZE - squash;
    if (new_h <= 0) return;
    w4.DRAW_COLORS.* = DC_BG;
    const rows = sym.SYMBOLS[color];
    const y_off = @divTrunc(squash, 2);
    var oy: i32 = 0;
    while (oy < new_h) : (oy += 1) {
        const src_row: usize = @intCast(@divTrunc(oy * SYMBOL_SIZE, new_h));
        const row = rows[src_row];
        for (row, 0..) |ch, rx| {
            if (ch == '#') w4.Rect(x + @as(i32, @intCast(rx)), y + y_off + oy, 1, 1);
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

// sym_bounce nudges only the symbol glyph up/down, not the block underneath
// it (see isColumnStressed/stressBounceOffset) -- keeps the block's own
// position (and anything keyed to it, like the hidden row's dither overlay)
// perfectly still even while a stressed column's symbols wobble in place.
// squash instead vertically compresses only the symbol glyph itself (see
// drawSymbolSquished/PANIC_SQUISH_AMOUNT) -- the block's own bevel/fill is
// never touched by either one, only ever the symbol drawn on top of it.
// Mutually exclusive with sym_bounce in practice (see drawBoard), so both
// are never meaningfully nonzero at once.
fn drawNormalCell(x: i32, y: i32, color: u8, sym_bounce: i32, squash: i32) void {
    // Flush with the tile's top-left corner; the unused trailing 1px on the
    // right/bottom becomes the gap to the next tile (see BLOCK_SIZE).
    drawBevelledBlock(x, y, BLOCK_SIZE, BLOCK_SIZE, color);
    const sym_off = @divTrunc(BLOCK_SIZE - SYMBOL_SIZE, 2);
    drawSymbolSquished(color, x + sym_off, y + sym_off + sym_bounce, squash);
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
            if (@mod(elapsed, 2) == 0) drawNormalCell(x, y, color, 0, 0);
        } else {
            drawNormalCell(x, y, color, 0, 0);
        }
        return;
    }
    const elapsed = c.POP_FRAMES - timer;
    if (elapsed < 0) {
        // Still waiting its turn in the pop cascade (see POP_STAGGER_FRAMES)
        // -- render exactly like a settled block until then.
        drawNormalCell(x, y, color, 0, 0);
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
    drawNormalCell(x, y, color, 0, 0);
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
    drawNormalCell(x + offset, y, color, 0, 0);
}

// A column with any content within this many rows of the ceiling (see
// board.updateDangerTimer's game-over check, at logical row SPAWN_ROWS) is
// close enough to the rise hazard that its settled blocks bounce in place as
// a warning -- matching other Panel de Pon clients' more generous warning
// zone (a few rows of headroom before the stack is actually touching the
// top) now that the full 12-row board gives room for it, rather than only
// reacting once a column is already touching the very top row.
const STRESS_WARNING_ROWS: u8 = 3;

// An explicit per-frame timing chart, not a plain linear triangle wave --
// standard keyframe-animation practice for a bounce: hold longer on the
// highest and second-highest positions (slow in/out at the top, like real
// gravity briefly arresting upward motion) and spend fewer frames in the
// quick transit through the lower positions, rather than moving at a
// constant rate the whole way. Reads as a snappier, more deliberate hop
// instead of a mechanical wobble.
const BOUNCE_KEYFRAMES = [16]i32{ 0, 0, -1, -2, -2, -3, -3, -3, -3, -3, -3, -2, -2, -1, 0, 0 };

fn isColumnStressed(b: *s.Board, col: u8) bool {
    var lr: u8 = 0;
    while (lr < STRESS_WARNING_ROWS) : (lr += 1) {
        if (b.cellAt(c.SPAWN_ROWS + lr, col).state != .empty) return true;
    }
    return false;
}

fn stressBounceOffset() i32 {
    return BOUNCE_KEYFRAMES[s.frame_count % BOUNCE_KEYFRAMES.len];
}

// How many pixels shorter a settled real block renders while the board's
// own lose timer (Board.danger_timer) is actually running -- see
// drawBoard's `panicking` check. A constant squash rather than another
// animated bounce: the point is a plain, unmistakably different look from
// the ordinary ambient stress bounce, read at a glance rather than timed
// against.
const PANIC_SQUISH_AMOUNT: i32 = 2;

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
    // The lose timer (see board.updateDangerTimer) is a strictly more
    // urgent warning than the ordinary per-column stress bounce above --
    // once it's actually running, every settled real block switches from
    // wobbling its symbol to rendering panic-squished instead (see
    // PANIC_SQUISH_AMOUNT), a clearer "the clock is now really running"
    // affordance than the milder ambient bounce.
    const panicking = b.danger_timer > 0;

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
                    // Only a settled real block's *symbol* bounces (see
                    // drawNormalCell's sym_bounce) -- the block itself, and
                    // garbage (which has no symbol), stay put at base_y, so
                    // nothing keyed to a block's actual position (like the
                    // hidden row's dither overlay below) ever falls out of
                    // sync with it. While panicking, the bounce is replaced
                    // entirely by a squash (see drawNormalCell's squash) --
                    // the two are mutually exclusive, never both nonzero.
                    if (cell.is_garbage) {
                        rgarbage.drawLinked(x, base_y, rgarbage.edgesAt(b, lr, col));
                    } else if (panicking) {
                        drawNormalCell(x, base_y, cell.color, 0, PANIC_SQUISH_AMOUNT);
                    } else {
                        const sym_bounce = if (col_stressed[col]) bounce else 0;
                        drawNormalCell(x, base_y, cell.color, sym_bounce, 0);
                    }
                },
                .falling => {
                    const y = base_y - cell.fall_off;
                    if (cell.is_garbage) rgarbage.drawLinked(x, y, rgarbage.edgesAt(b, lr, col)) else drawNormalCell(x, y, cell.color, 0, 0);
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

    // One mark per settled garbage piece, at its own true pixel-space
    // centroid (see garbage_pieces.pieceCenters) -- drawn as its own pass,
    // on top of everything above, since a centroid can straddle several
    // cells rather than belonging to any single one of them. Lets two
    // different pieces resting against each other, rendered as one seamless
    // slab with no visible seam (see rgarbage.drawLinked), still read as
    // visually distinct blocks instead of one bigger one. Passed the same
    // `wiped` count as the main loop above, so a piece's mark shrinks in
    // sync with the closing wipe and disappears entirely once the match is
    // over, rather than lingering over a board the wipe has already cleared.
    const centers = rgarbage.pieceCenters(b, wiped);
    for (centers.items[0..centers.count]) |pc| rgarbage.drawMark(pc.x, pc.y);
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

// How far each bracket sits beyond the block's own edge (not the tile's --
// the block is flush with the tile's top-left corner, see BLOCK_SIZE, so a
// bracket centered on the block is offset the same amount on every side
// regardless). CURSOR_OUT_BASE is the resting/contracted distance -- the
// default look, and what a fresh move snaps back to; while idling, it
// breathes out to CURSOR_OUT_BASE + CURSOR_OUT_PULSE and back (see
// drawCursor) rather than sitting at a fixed size the whole time.
const CURSOR_OUT_BASE: i32 = 1;
const CURSOR_OUT_PULSE: i32 = 1;
const CURSOR_CORNER_LEN: i32 = 3;
// A discrete 2-frame animation (contracted/expanded), not a smooth
// interpolation -- the same idiom as every other animation in the game
// (see render_character.currentFrame), holding each state for this many
// engine frames before toggling to the other. A gradual per-pixel slide
// instead reads as the dithered checkerboard's two hues swapping in place
// (since which hue lands on a given pixel depends on its absolute
// position -- see plotDithered) rather than an actual size change.
const CURSOR_BREATHE_HOLD_FRAMES: u32 = 15;
const CURSOR_DITHER_HUES = badge.WARM_DITHER_HUES;

// One tile's own 4 corner brackets -- like a photo mounted by its own four
// corner tabs, not a single box traced around it (the classic Panel de Pon
// cursor look). `x`/`y` is the block's own top-left corner (== the tile's,
// since the block is flush with it); `out` is how far the bracket sits
// beyond the block's edge on every side, so it's centered on the block.
fn drawCursorCorners(x: i32, y: i32, out: i32, hues: [2]u8) void {
    const x0 = x - out;
    const y0 = y - out;
    const x1 = x + BLOCK_SIZE - 1 + out;
    const y1 = y + BLOCK_SIZE - 1 + out;
    var i: i32 = 0;
    while (i < CURSOR_CORNER_LEN) : (i += 1) {
        plotDithered(x0 + i, y0, hues); // top-left
        plotDithered(x0, y0 + i, hues);
        plotDithered(x1 - i, y0, hues); // top-right
        plotDithered(x1, y0 + i, hues);
        plotDithered(x0 + i, y1, hues); // bottom-left
        plotDithered(x0, y1 - i, hues);
        plotDithered(x1 - i, y1, hues); // bottom-right
        plotDithered(x1, y1 - i, hues);
    }
}

// Always the player's own cursor -- the CPU has no cursor to show (its board
// is drawn too small for one to read well, and it has no real input anyway).
// Hidden while touch is the active input method (see state.cursor_hidden) --
// swipes move it relative to wherever it already is rather than aiming at a
// touched tile, so there's nothing the player needs to see it for.
fn drawCursor() void {
    if (s.winner != .none or s.cursor_hidden) return;
    const row = s.player.cursor_row;
    const col = s.player.cursor_col;
    const base_x = c.BOARD_X + @as(i32, col) * c.TILE;
    const base_y = c.BOARD_Y + @as(i32, row) * c.TILE - @as(i32, @intCast(s.player.scroll_px));

    // Breathe by alternating between two discrete sizes (contracted at
    // CURSOR_OUT_BASE, expanded at CURSOR_OUT_BASE + CURSOR_OUT_PULSE) --
    // driven by cursor_idle_frames (time since the cursor last actually
    // moved), not raw frame_count, so idle_frames == 0 always lands on the
    // contracted frame: the cursor snaps to it the instant it moves, and
    // only starts alternating again once it's been sitting there for a
    // whole CURSOR_BREATHE_HOLD_FRAMES -- a fast-playing player never sees
    // it breathe at all.
    const expanded = @mod(@divTrunc(s.cursor_idle_frames, CURSOR_BREATHE_HOLD_FRAMES), 2) == 1;
    const out = if (expanded) CURSOR_OUT_BASE + CURSOR_OUT_PULSE else CURSOR_OUT_BASE;

    // Rather than staying pinned to the two static grid tiles, each slot's
    // corners ride along with whatever block is actually there right now --
    // so a live swap (see CellState.swapping/drawSwappingCell's identical
    // offset formula) visibly carries the cursor along with the two blocks
    // as they trade places, instead of the cursor sitting still while the
    // blocks slide underneath it.
    const abs_row = row + c.SPAWN_ROWS;
    const left = s.player.cellAt(abs_row, col);
    const right = s.player.cellAt(abs_row, col + 1);
    const left_offset: i32 = if (left.state == .swapping) @as(i32, left.swap_dir) * @divTrunc(c.TILE * @as(i32, left.timer), c.SWAP_FRAMES) else 0;
    const right_offset: i32 = if (right.state == .swapping) @as(i32, right.swap_dir) * @divTrunc(c.TILE * @as(i32, right.timer), c.SWAP_FRAMES) else 0;

    drawCursorCorners(base_x + left_offset, base_y, out, CURSOR_DITHER_HUES);
    drawCursorCorners(base_x + c.TILE + right_offset, base_y, out, CURSOR_DITHER_HUES);
}

// Where the player's own portrait sits -- shifted down from the screen's
// very top edge by rchar.FRAME_MARGIN so its themed frame (rchar.drawFrame)
// has room above it, rather than being pushed off-screen. CHAR_TEXT_X is
// shared with render()'s own badge.drawMatchPopups call below, so the flying
// match-popup badge and the score digits it lands on agree on where the
// score actually is.
const CHAR_PORTRAIT_Y: i32 = rchar.FRAME_MARGIN;
const CHAR_TEXT_X: i32 = c.PANEL_X + rchar.W + rchar.FRAME_MARGIN + 2;

// The player's own character portrait, framed in their chosen character's
// own theme (see rchar.drawFrame) and animated per render_character.zig,
// plus score/points squeezed in beside it. The old static yellow "COMBO"/
// "xN" chain callout that used to sit below the portrait is gone -- the
// flying match-popup badge (badge.drawMatchPopups, now landing right here
// for both sides) already communicates the same thing, and the character's
// own combo/win bounce (see rchar.bounceOffset) reinforces it further, so
// keeping a second static text readout around just ate space for no benefit.
fn drawPanel() void {
    rchar.drawFrame(c.PANEL_X, CHAR_PORTRAIT_Y, s.player_character);
    rchar.draw(c.PANEL_X, CHAR_PORTRAIT_Y, s.player_character, rchar.stateFor(&s.player), rchar.currentFrame());

    w4.DRAW_COLORS.* = 0x0002;
    var buf: [12]u8 = undefined;
    const score_str = std.fmt.bufPrint(&buf, "{d}", .{s.player.score}) catch "0";
    w4.Text(score_str, CHAR_TEXT_X, 2);
    badge.drawPoints(CHAR_TEXT_X, 10, s.player_points);
}

const MENU_PANEL_X: i32 = 20;
const MENU_PANEL_W: i32 = 120;

// Common backdrop for every pre-game screen: the parallaxing background
// (see render_bg.zig) plus the panel's own fill, held perfectly still --
// callers draw their own border (the title screen's neutral bezel vs. the
// setup screens' character-themed one) and content into the returned Y.
// `base_y`/`h` differ per screen (some have more to fit than others), so
// both are the caller's own choice rather than shared constants.
fn drawMenuPanelFill(base_y: i32, h: i32) i32 {
    bg.draw();
    w4.DRAW_COLORS.* = 0x0001;
    w4.Rect(MENU_PANEL_X, base_y, MENU_PANEL_W, @intCast(h));
    return base_y;
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

// Position of each portrait in the setup screen's character grid -- wraps
// into rows of CHARS_PER_ROW rather than one long line (7 characters, at
// this sprite size plus gap, are too wide for the panel to fit in a single
// row), each row independently centered in the panel's own width so a
// shorter final row (3, not 4) still sits centered under the one above it
// rather than left-aligned.
const CHARS_PER_ROW: u8 = 4;
const CHAR_SLOT_GAP: i32 = 8;
const CHAR_ROW_GAP: i32 = 8;

fn charRowCount(row: u8) u8 {
    const start = row * CHARS_PER_ROW;
    return @intCast(@min(CHARS_PER_ROW, characters.COUNT - start));
}

fn charSlotPos(index: u8) struct { x: i32, y: i32, row: u8 } {
    const row = index / CHARS_PER_ROW;
    const col = index % CHARS_PER_ROW;
    const row_w = @as(i32, charRowCount(row)) * rchar.W + (@as(i32, charRowCount(row)) - 1) * CHAR_SLOT_GAP;
    const start_x = MENU_PANEL_X + @divTrunc(MENU_PANEL_W - row_w, 2);
    const x = start_x + @as(i32, col) * (rchar.W + CHAR_SLOT_GAP);
    const y = @as(i32, row) * (rchar.H + CHAR_ROW_GAP);
    return .{ .x = x, .y = y, .row = row };
}

// The setup flow's own screen position -- held fixed across all 3 steps
// (character, CPU reveal, difficulty) so the panel doesn't jump around
// between them, just its height/content changes.
const SETUP_BASE_Y: i32 = 24;

pub fn drawSetupCharacterScreen() void {
    const y = drawMenuPanelFill(SETUP_BASE_Y, 120);
    // Retheme the panel border itself to whichever character is currently
    // selected -- "switching should retheme the setup menu".
    drawThemedPanelBorder(MENU_PANEL_X, y, MENU_PANEL_W, 120, characters.ALL[s.player_character]);

    w4.DRAW_COLORS.* = 0x0003;
    w4.Text("SETUP", 58, y + 6);
    w4.DRAW_COLORS.* = 0x0002;
    w4.Text("CHARACTER", 40, y + 18);

    // Every character is shown at once (not just the current pick) --
    // left/right cycles the player's own selection (see main.zig),
    // highlighted with a dithered outline -- solid normally, blinking on/off
    // for a moment right after confirming (see state.setup_flash_timer)
    // before moving on to watch the CPU pick its own.
    const frame = rchar.currentFrame();
    const grid_y = y + 34;
    const flashing = s.setup_flash_timer > 0;
    const flash_on = !flashing or blinkOn(c.SETUP_FLASH_TOTAL_FRAMES - s.setup_flash_timer, c.SETUP_FLASH_TOGGLE_FRAMES);
    var last_row: u8 = 0;
    for (0..characters.COUNT) |i| {
        const pos = charSlotPos(@intCast(i));
        const cy = grid_y + pos.y;
        last_row = pos.row;
        rchar.draw(pos.x, cy, @intCast(i), .normal, frame);
        if (i == s.player_character and flash_on) {
            drawDitheredRectOutline(pos.x - 2, cy - 2, rchar.W + 4, rchar.H + 4, badge.WARM_DITHER_HUES);
        }
    }
    const grid_bottom = grid_y + @as(i32, last_row) * (rchar.H + CHAR_ROW_GAP) + rchar.H;

    w4.DRAW_COLORS.* = 0x0002;
    var buf: [24]u8 = undefined;
    const you_label = std.fmt.bufPrint(&buf, "YOU: {s}", .{characters.ALL[s.player_character].name}) catch "YOU";
    w4.Text(you_label, 28, grid_bottom + 6);
    if (!flashing) {
        w4.Text("<-      ->", 40, grid_bottom + 18);
        w4.Text("PRESS X", 52, grid_bottom + 30);
    }
}

// True during the "on" half of a simple on/off blink -- elapsed frames
// since some start point, toggling every `period` frames.
fn blinkOn(elapsed: u16, period: u16) bool {
    return @mod(elapsed, period * 2) < period;
}

// Left edge of one of 2 side-by-side portraits (see drawSetupCpuRevealScreen)
// -- same centered-row idea as charSlotX, just for 2 slots instead of 4.
const REVEAL_GAP: i32 = 24;
fn revealSlotX(which: u8) i32 {
    const total_w = rchar.W * 2 + REVEAL_GAP;
    const start = MENU_PANEL_X + @divTrunc(MENU_PANEL_W - total_w, 2);
    return start + @as(i32, which) * (rchar.W + REVEAL_GAP);
}

pub fn drawSetupCpuRevealScreen() void {
    const y = drawMenuPanelFill(SETUP_BASE_Y, 80);
    drawThemedPanelBorder(MENU_PANEL_X, y, MENU_PANEL_W, 80, characters.ALL[s.player_character]);

    w4.DRAW_COLORS.* = 0x0003;
    w4.Text("SETUP", 58, y + 6);
    w4.DRAW_COLORS.* = 0x0002;
    w4.Text("CPU IS CHOOSING", 26, y + 18);

    const frame = rchar.currentFrame();
    const row_y = y + 34;
    const you_x = revealSlotX(0);
    const cpu_x = revealSlotX(1);
    rchar.draw(you_x, row_y, s.player_character, .normal, frame);
    drawDitheredRectOutline(you_x - 2, row_y - 2, rchar.W + 4, rchar.H + 4, badge.WARM_DITHER_HUES);

    // Spins through every character once per tick, holding each a little
    // longer than the last (see state.cpu_reveal_tick/constants.
    // CPU_REVEAL_HOLD_*), landing for good on the real pick at the final
    // tick -- a slot machine slowing to a stop rather than an instant reveal.
    const done = s.cpu_reveal_tick >= c.CPU_REVEAL_STEPS - 1;
    const spin_index: u8 = if (done) s.cpu_character else @intCast(s.cpu_reveal_tick % characters.COUNT);
    rchar.draw(cpu_x, row_y, spin_index, .normal, frame);
    drawDitheredRectOutline(cpu_x - 2, row_y - 2, rchar.W + 4, rchar.H + 4, badge.WARM_DITHER_HUES);

    w4.DRAW_COLORS.* = 0x0002;
    var buf: [24]u8 = undefined;
    const you_label = std.fmt.bufPrint(&buf, "YOU: {s}", .{characters.ALL[s.player_character].name}) catch "YOU";
    w4.Text(you_label, 22, row_y + rchar.H + 8);
    w4.DRAW_COLORS.* = 0x0004;
    var buf2: [24]u8 = undefined;
    const cpu_label = if (done)
        std.fmt.bufPrint(&buf2, "CPU: {s}", .{characters.ALL[s.cpu_character].name}) catch "CPU"
    else
        "CPU: ???";
    w4.Text(cpu_label, 22, row_y + rchar.H + 20);
}

pub fn drawSetupDifficultyScreen() void {
    const y = drawMenuPanelFill(SETUP_BASE_Y, 110);
    drawThemedPanelBorder(MENU_PANEL_X, y, MENU_PANEL_W, 110, characters.ALL[s.player_character]);

    w4.DRAW_COLORS.* = 0x0003;
    w4.Text("SETUP", 58, y + 6);
    w4.DRAW_COLORS.* = 0x0002;
    w4.Text("DIFFICULTY", 40, y + 18);

    var buf: [24]u8 = undefined;
    const you_label = std.fmt.bufPrint(&buf, "YOU: {s}", .{characters.ALL[s.player_character].name}) catch "YOU";
    w4.Text(you_label, 28, y + 32);
    w4.DRAW_COLORS.* = 0x0004;
    var buf2: [24]u8 = undefined;
    const cpu_label = std.fmt.bufPrint(&buf2, "CPU: {s}", .{characters.ALL[s.cpu_character].name}) catch "CPU";
    w4.Text(cpu_label, 28, y + 44);

    w4.DRAW_COLORS.* = 0x0002;
    drawDifficultyBar(40, y + 62);
    var buf3: [24]u8 = undefined;
    // Every level runs cpu_engine's actual move search -- see
    // cpu_ai.configFor -- lower levels just listen to it far less reliably.
    const label = std.fmt.bufPrint(&buf3, "LEVEL {d}", .{s.difficulty}) catch "LEVEL ?";
    w4.Text(label, 58, y + 74);
    w4.Text("<-      ->", 40, y + 88);
    w4.Text("PRESS X", 52, y + 100);
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

// How far a particle travels from its spawn point by the end of its life,
// and how big it starts out (shrinking to nothing by the same point) -- see
// state.Particle/Board.spawnPopParticles. Linear growth/shrink, same
// integer-elapsed-over-total style as every other timed animation here
// (e.g. drawSwappingCell's slide) rather than anything fancier.
const PARTICLE_MAX_DIST: i32 = 10;
const PARTICLE_START_SIZE: i32 = 3;

fn drawParticles(particles: []const s.Particle) void {
    for (particles) |p| {
        if (!p.active) continue;
        const dist = @divTrunc(PARTICLE_MAX_DIST * @as(i32, p.elapsed), s.PARTICLE_LIFE);
        const size = PARTICLE_START_SIZE - @divTrunc(PARTICLE_START_SIZE * @as(i32, p.elapsed), s.PARTICLE_LIFE);
        if (size <= 0) continue;
        const x = p.x + @as(i32, p.dir_x) * dist - @divTrunc(size, 2);
        const y = p.y + @as(i32, p.dir_y) * dist - @divTrunc(size, 2);
        const hue = if (p.color < 3) p.color else DITHER_HUES[p.color - 3][0];
        w4.DRAW_COLORS.* = HUE_DRAWCOLOR[hue];
        w4.Oval(x, y, @intCast(size), @intCast(size));
    }
}

pub fn render() void {
    clearBackground();
    drawBoard(&s.player);
    maskBelowBoard();
    drawFrame();
    drawCursor();
    drawPanel();
    badge.drawMatchPopups(&s.player.match_popups, CHAR_TEXT_X, 10);
    drawParticles(&s.player.particles);
    // In the gutter between the player's own frame and the panel column.
    badge.drawGarbageQueueIcons(96, c.BOARD_Y + 4, &s.player);
    render_cpu.draw();
}
