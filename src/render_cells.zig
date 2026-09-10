// Single-cell drawing primitives and the per-CellState cell drawers that
// render.drawBoard dispatches to -- split out to fit the 500-line-per-file guideline.

const c = @import("constants.zig");
const s = @import("state.zig");
const w4 = @import("wasm4.zig");
const sym = @import("symbols.zig");
const rgarbage = @import("render_garbage.zig");

// nibble values for DRAW_COLORS color1, one per palette slot (index+1)
pub const DC_BG: u16 = 1;
pub const HUE_DRAWCOLOR = [3]u16{ 2, 3, 4 };

// Blocks use only a bevel + gap + background-colored symbol, no border --
// the symbol keeps shapes distinguishable without relying on color at all.
const BEVEL_RADIUS: i32 = 1;
// Drawn 1px smaller than its tile, flush to the top-left corner -- the
// trailing row/column becomes the gap to the next tile, never doubled between neighbors.
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

// Traces a dithered outline pixel by pixel -- rect()'s border nibble is one
// solid color, so a single rect() call can't dither an outline like a fill can.
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

// Like drawSymbolFor but vertically resampled/recentered into fewer rows --
// the panic squish compresses only this glyph, never the block's own bevel/fill.
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

// Fills a block and punches its 4 corners to background color -- the same
// chamfer trick as the frame's rounded corners, at a fixed 1px radius.
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

// sym_bounce and squash each move/resize only the symbol glyph, never the
// block's own bevel/fill -- mutually exclusive in practice (see render.drawBoard).
pub fn drawNormalCell(x: i32, y: i32, color: u8, sym_bounce: i32, squash: i32) void {
    // Flush with the tile's top-left corner; the unused trailing 1px on the
    // right/bottom becomes the gap to the next tile (see BLOCK_SIZE).
    drawBevelledBlock(x, y, BLOCK_SIZE, BLOCK_SIZE, color);
    const sym_off = @divTrunc(BLOCK_SIZE - SYMBOL_SIZE, 2);
    drawSymbolSquished(color, x + sym_off, y + sym_off + sym_bounce, squash);
}

// A real matched block disappearing (see CellState.popping) -- garbage never
// uses this state, it recycles instead (see drawRecyclingCell below).
pub fn drawPoppingCell(x: i32, y: i32, color: u8, timer: i16, pre_pop_timer: i16) void {
    if (pre_pop_timer > 0) {
        // Shared pre-pop preamble (see Cell.pre_pop_timer): every match member
        // blinks in lockstep, then pauses normally, before the staggered pop cascade begins.
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

// A garbage cell recycling (see CellState.recycling): a converting cell
// (Cell.garbage_reveals) hard-cuts to a normal block on its own staggered turn; a non-converting cell just stays inert garbage throughout.
pub fn drawRecyclingCell(x: i32, y: i32, color: u8, timer: i16, edges: rgarbage.Edges, pre_pop_timer: i16, garbage_reveals: bool) void {
    if (pre_pop_timer > 0) {
        // Shared pre-pop preamble (see drawPoppingCell above): blinks then pauses,
        // still showing the inert/attached garbage look until this cell's own reveal turn.
        const elapsed = c.PRE_POP_TOTAL_FRAMES - pre_pop_timer;
        if (elapsed < c.PRE_POP_BLINK_FRAMES) {
            if (@mod(elapsed, 2) == 0) rgarbage.drawLinked(x, y, edges);
        } else {
            rgarbage.drawLinked(x, y, edges);
        }
        return;
    }
    if (!garbage_reveals) {
        // Purely cosmetic: a non-converting row (Cell.garbage_reveals false) still
        // flashes for the same span a real reveal takes, then returns to its ordinary inert look.
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
        // A connected clump lands and squash-bounces in lockstep (see sim.zig's
        // group-based gravity), staying a seamless slab through the bounce too.
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

// Columns within this many rows of the ceiling bounce as a warning --
// matches other Panel de Pon clients' more generous headroom before the top.
const STRESS_WARNING_ROWS: u8 = 3;

// Explicit per-frame keyframe chart, not a linear wave -- holds longer at
// the peak (like gravity arresting upward motion) for a snappier, deliberate hop.
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
