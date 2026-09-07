// All drawing: palette setup, the board/cursor/panel, and the title/game-over
// screens. Not unit tested -- everything here bottoms out in WASM4's extern
// draw calls, which only make sense under an actual WASM4 host.

const std = @import("std");
const c = @import("constants.zig");
const s = @import("state.zig");
const w4 = @import("wasm4.zig");
const sym = @import("symbols.zig");
const badge = @import("render_badge.zig");

// nibble values for DRAW_COLORS color1, one per palette slot (index+1)
const DC_BG: u16 = 1;
const HUE_DRAWCOLOR = [3]u16{ 2, 3, 4 };
const DC_FRAME: u16 = 2; // frame/UI accent, reuses hue A

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

// Garbage (see Cell.is_garbage) is colorless and inert, so it renders as a
// muted background+hue checkerboard -- distinct from all 5 real block colors
// (which are either a solid hue or a hue+hue dither) -- with no symbol, so it
// reads at a glance as "not a real, matchable color".
const GARBAGE_HUE: u8 = 1; // teal; arbitrary, just needs to look muted/inert next to DC_BG

fn drawGarbageRect(x: i32, y: i32, w: i32, h: i32) void {
    if (w <= 0 or h <= 0) return;
    var dy: i32 = 0;
    while (dy < h) : (dy += 1) {
        var dx: i32 = 0;
        while (dx < w) : (dx += 1) {
            w4.DRAW_COLORS.* = if (@mod(dx + dy, 2) == 0) DC_BG else HUE_DRAWCOLOR[GARBAGE_HUE];
            w4.Rect(x + dx, y + dy, 1, 1);
        }
    }
}

// Which of a garbage cell's 4 orthogonal neighbors are themselves garbage,
// still attached (see sim.zig's group-based gravity -- connected garbage
// always falls/lands in lockstep, so a neighbor in any of these states is
// guaranteed to be moving the same way this cell is, not just coincidentally
// adjacent). Used to render a connected clump as one seamless slab: no gap
// or bevel on the sides facing an attached neighbor, only on the outer
// boundary of the whole clump.
const GarbageEdges = struct { up: bool = false, down: bool = false, left: bool = false, right: bool = false };

fn isAttachedGarbage(lr: u8, col: u8) bool {
    const cell = s.cellAt(lr, col);
    return cell.is_garbage and (cell.state == .normal or cell.state == .falling or cell.state == .landing);
}

fn garbageEdgesAt(lr: u8, col: u8) GarbageEdges {
    var e = GarbageEdges{};
    if (lr > 0) e.up = isAttachedGarbage(lr - 1, col);
    if (lr + 1 < c.ROWS) e.down = isAttachedGarbage(lr + 1, col);
    if (col > 0) e.left = isAttachedGarbage(lr, col - 1);
    if (col + 1 < c.COLS) e.right = isAttachedGarbage(lr, col + 1);
    return e;
}

// Like drawGarbageBlock, but extends the fill into an attached right/down
// neighbor's tile (closing the 1px gap normal blocks leave there -- an
// attached left/up neighbor closes the gap on *its* side instead, so this
// cell doesn't need to touch its own left/top) and only bevels a corner
// where both adjacent edges are unattached -- a true exterior corner of the
// whole connected clump, not a seam between two of its own cells.
fn drawGarbageBlockLinked(x: i32, y: i32, edges: GarbageEdges) void {
    const w: i32 = if (edges.right) BLOCK_SIZE + 1 else BLOCK_SIZE;
    const h: i32 = if (edges.down) BLOCK_SIZE + 1 else BLOCK_SIZE;
    drawGarbageRect(x, y, w, h);
    w4.DRAW_COLORS.* = DC_BG;
    if (!edges.up and !edges.left) w4.Rect(x, y, 1, 1);
    if (!edges.up and !edges.right) w4.Rect(x + w - 1, y, 1, 1);
    if (!edges.down and !edges.left) w4.Rect(x, y + h - 1, 1, 1);
    if (!edges.down and !edges.right) w4.Rect(x + w - 1, y + h - 1, 1, 1);
}

fn drawGarbageBlock(x: i32, y: i32, w: i32, h: i32) void {
    drawGarbageRect(x, y, w, h);
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

fn drawPoppingCell(x: i32, y: i32, color: u8, timer: i16, is_garbage: bool) void {
    const elapsed = c.POP_FRAMES - timer;
    if (is_garbage) {
        // Garbage doesn't shrink away -- it isn't disappearing, it's
        // revealing a fresh block once the whole connected pop event
        // finishes (see sim.simulate) -- so it just pulses/cracks in place
        // for as long as it's popping, at full size right up until the
        // instant it resolves into a real block.
        if (elapsed < 0) {
            drawGarbageBlock(x, y, BLOCK_SIZE, BLOCK_SIZE);
            return;
        }
        const puls: i32 = @intCast(@mod(elapsed, 8));
        const delta: i32 = if (puls < 4) puls else 8 - puls;
        const size = BLOCK_SIZE - delta;
        if (size <= 0) return;
        const off = @divTrunc(BLOCK_SIZE - size, 2);
        drawGarbageBlock(x + off, y + off, size, size);
        return;
    }
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

fn drawLandingCell(x: i32, y: i32, color: u8, timer: i16, is_garbage: bool, edges: GarbageEdges) void {
    const elapsed = c.LAND_FRAMES - timer;
    const squash: i32 = if (elapsed < 3) (3 - @as(i32, elapsed)) * 2 else 0;
    const height = BLOCK_SIZE - squash;
    if (is_garbage) {
        // A connected clump lands (and squash-bounces) in lockstep -- see
        // sim.zig's group-based gravity -- so this stays a seamless slab
        // through the bounce too, not just at rest.
        const w: i32 = if (edges.right) BLOCK_SIZE + 1 else BLOCK_SIZE;
        drawGarbageRect(x, y + squash, w, height);
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

// A column with any content in its top few rows is close enough to the rise
// hazard (see board.doRise's game-over check on logical row 0) that its
// settled blocks bounce in place as a warning -- 3 rows means a column is
// flagged as soon as it's within 2 rises of actually topping out.
const STRESS_WARNING_ROWS: u8 = 3;
const STRESS_BOUNCE_PERIOD: i32 = 16;
const STRESS_BOUNCE_AMOUNT: i32 = 3;

fn isColumnStressed(col: u8) bool {
    var lr: u8 = 0;
    while (lr < STRESS_WARNING_ROWS) : (lr += 1) {
        if (s.cellAt(lr, col).state != .empty) return true;
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

fn drawBoard() void {
    var col_stressed: [c.COLS]bool = undefined;
    for (0..c.COLS) |ci| col_stressed[ci] = isColumnStressed(@intCast(ci));
    const bounce = stressBounceOffset();

    var lr: u8 = 0;
    while (lr < c.ROWS) : (lr += 1) {
        const base_y = c.BOARD_Y + @as(i32, lr) * c.TILE - @as(i32, @intCast(s.scroll_px));
        if (base_y <= -c.TILE or base_y >= w4.SCREEN_SIZE) continue;
        var col: u8 = 0;
        while (col < c.COLS) : (col += 1) {
            const cell = s.cellAt(lr, col);
            if (cell.state == .empty) continue;
            const x = c.BOARD_X + @as(i32, col) * c.TILE;
            switch (cell.state) {
                .normal => {
                    // Only settled blocks bounce -- cells already mid
                    // animation (falling/landing/popping/swapping) keep
                    // their own motion undisturbed.
                    const y = if (col_stressed[col]) base_y + bounce else base_y;
                    if (cell.is_garbage) drawGarbageBlockLinked(x, y, garbageEdgesAt(lr, col)) else drawNormalCell(x, y, cell.color);
                },
                .falling => {
                    const y = base_y - cell.fall_off;
                    if (cell.is_garbage) drawGarbageBlockLinked(x, y, garbageEdgesAt(lr, col)) else drawNormalCell(x, y, cell.color);
                },
                .popping => drawPoppingCell(x, base_y, cell.color, cell.timer, cell.is_garbage),
                .landing => drawLandingCell(x, base_y, cell.color, cell.timer, cell.is_garbage, garbageEdgesAt(lr, col)),
                .swapping => drawSwappingCell(x, base_y, cell.color, cell.timer, cell.swap_dir),
                .empty => {},
            }
        }
    }
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

    w4.DRAW_COLORS.* = DC_FRAME;
    w4.Rect(x, y, @intCast(w), @intCast(t)); // top
    w4.Rect(x, y + h - t, @intCast(w), @intCast(t)); // bottom
    w4.Rect(x, y, @intCast(t), @intCast(h)); // left
    w4.Rect(x + w - t, y, @intCast(t), @intCast(h)); // right

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

fn drawCursor() void {
    if (s.game_over) return;
    const base_x = c.BOARD_X + @as(i32, s.cursor_col) * c.TILE;
    const base_y = c.BOARD_Y + @as(i32, s.cursor_row) * c.TILE - @as(i32, @intCast(s.scroll_px));

    // Blink by contracting slightly instead of changing color.
    const half = @divTrunc(CURSOR_PULSE_PERIOD, 2);
    const t: i32 = @intCast(@mod(s.frame_count, @as(u32, @intCast(CURSOR_PULSE_PERIOD))));
    const tri: i32 = if (t < half) t else CURSOR_PULSE_PERIOD - t;
    const contract = @divTrunc(tri * CURSOR_PULSE_AMOUNT, half);

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
}

fn drawPanel() void {
    w4.DRAW_COLORS.* = 0x0002;
    w4.Text("SCORE", c.PANEL_X, 4);
    var buf: [12]u8 = undefined;
    const score_str = std.fmt.bufPrint(&buf, "{d}", .{s.score}) catch "0";
    w4.Text(score_str, c.PANEL_X, 14);

    if (s.chain > 1) {
        var buf2: [12]u8 = undefined;
        const chain_str = std.fmt.bufPrint(&buf2, "x{d}", .{s.chain}) catch "";
        w4.DRAW_COLORS.* = 0x0004;
        w4.Text(chain_str, c.PANEL_X, 28);
    }
}

pub fn drawTitle() void {
    w4.DRAW_COLORS.* = 0x0003;
    w4.Text("PANELPON4", 40, 60);
    w4.DRAW_COLORS.* = 0x0002;
    w4.Text("PRESS X", 52, 80);
}

pub fn drawGameOver() void {
    w4.DRAW_COLORS.* = 0x0001;
    w4.Rect(20, 60, 120, 40);
    w4.DRAW_COLORS.* = 0x0004;
    w4.Text("GAME OVER", 32, 68);
    w4.DRAW_COLORS.* = 0x0002;
    w4.Text("PRESS X", 40, 84);
}

pub fn render() void {
    clearBackground();
    drawBoard();
    drawFrame();
    drawCursor();
    drawPanel();
    badge.drawMatchPopups();
}
