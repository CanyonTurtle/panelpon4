// Single-cell drawing: the dithering/symbol primitives everything else here
// is built from, and the per-CellState cell drawers (drawNormalCell through
// drawSwappingCell) that render.drawBoard dispatches to for each board cell.
// Split out of render.zig to keep that file under the project's
// ~500-line-per-file guideline -- render.zig imports this file back for the
// handful of primitives (DC_BG, HUE_DRAWCOLOR, BLOCK_SIZE, DITHER_HUES,
// plotDithered) its own board/cursor/frame drawing still needs, and
// render_screens.zig does the same for drawDitheredRectOutline.

const c = @import("constants.zig");
const s = @import("state.zig");
const w4 = @import("wasm4.zig");
const sym = @import("symbols.zig");
const rgarbage = @import("render_garbage.zig");

// nibble values for DRAW_COLORS color1, one per palette slot (index+1)
pub const DC_BG: u16 = 1;
pub const HUE_DRAWCOLOR = [3]u16{ 2, 3, 4 };

// Blocks have no border color of their own anymore: just a 1px background
// corner-bevel (see BEVEL_RADIUS) and a 1px background gap between tiles
// (see BLOCK_SIZE), plus a symbol drawn in the background color so shapes
// stay distinguishable even without color.
const BEVEL_RADIUS: i32 = 1;
// Each block is drawn 1px smaller than its tile, flush with the tile's
// top-left corner; the unused trailing row/column becomes the 1px gap to the
// next tile, so gaps aren't doubled up between neighbors.
pub const BLOCK_SIZE: i32 = c.TILE - 1;
const SYMBOL_SIZE: i32 = sym.SYMBOL_SIZE; // same parity as BLOCK_SIZE -> perfectly centered, no remainder

pub const DITHER_HUES = [2][2]u8{ .{ 0, 1 }, .{ 1, 2 } };

fn ditherHues(color: u8) ?[2]u8 {
    if (color < 3) return null;
    return DITHER_HUES[color - 3];
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
pub fn drawDitheredRectOutline(x: i32, y: i32, w: i32, h: i32, hues: [2]u8) void {
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

pub fn plotDithered(x: i32, y: i32, hues: [2]u8) void {
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
// it (see render.isColumnStressed/stressBounceOffset) -- keeps the block's
// own position (and anything keyed to it, like the hidden row's dither
// overlay) perfectly still even while a stressed column's symbols wobble in
// place. squash instead vertically compresses only the symbol glyph itself
// (see drawSymbolSquished/PANIC_SQUISH_AMOUNT) -- the block's own bevel/fill
// is never touched by either one, only ever the symbol drawn on top of it.
// Mutually exclusive with sym_bounce in practice (see render.drawBoard), so
// both are never meaningfully nonzero at once.
pub fn drawNormalCell(x: i32, y: i32, color: u8, sym_bounce: i32, squash: i32) void {
    // Flush with the tile's top-left corner; the unused trailing 1px on the
    // right/bottom becomes the gap to the next tile (see BLOCK_SIZE).
    drawBevelledBlock(x, y, BLOCK_SIZE, BLOCK_SIZE, color);
    const sym_off = @divTrunc(BLOCK_SIZE - SYMBOL_SIZE, 2);
    drawSymbolSquished(color, x + sym_off, y + sym_off + sym_bounce, squash);
}

// A real matched block disappearing (see CellState.popping). Garbage never
// uses this state -- a garbage cell pulled into the same event instead
// recycles (see drawRecyclingCell below), which has no animation of its own.
pub fn drawPoppingCell(x: i32, y: i32, color: u8, timer: i16, pre_pop_timer: i16) void {
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
pub fn drawRecyclingCell(x: i32, y: i32, color: u8, timer: i16, edges: rgarbage.Edges, pre_pop_timer: i16, garbage_reveals: bool) void {
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

pub fn drawLandingCell(x: i32, y: i32, color: u8, timer: i16, is_garbage: bool, edges: rgarbage.Edges) void {
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

pub fn drawSwappingCell(x: i32, y: i32, color: u8, timer: i16, dir: i8) void {
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

pub fn isColumnStressed(b: *s.Board, col: u8) bool {
    var lr: u8 = 0;
    while (lr < STRESS_WARNING_ROWS) : (lr += 1) {
        if (b.cellAt(c.SPAWN_ROWS + lr, col).state != .empty) return true;
    }
    return false;
}

pub fn stressBounceOffset() i32 {
    return BOUNCE_KEYFRAMES[s.frame_count % BOUNCE_KEYFRAMES.len];
}
