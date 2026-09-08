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

// Full-detail board rendering -- always `s.player`, at the normal board
// position/scale. See render_cpu.zig for the CPU's simplified equivalent.
fn drawBoard(b: *s.Board) void {
    var col_stressed: [c.COLS]bool = undefined;
    for (0..c.COLS) |ci| col_stressed[ci] = isColumnStressed(b, @intCast(ci));
    const bounce = stressBounceOffset();

    // Starts at SPAWN_ROWS, not 0 -- rows before that are the offscreen
    // garbage staging area (see constants.SPAWN_ROWS/Board.physRow), never
    // meant to be drawn at all.
    var lr: u8 = c.SPAWN_ROWS;
    while (lr < c.ROWS) : (lr += 1) {
        const base_y = c.BOARD_Y + @as(i32, lr - c.SPAWN_ROWS) * c.TILE - @as(i32, @intCast(b.scroll_px));
        if (base_y + c.TILE <= c.BOARD_Y or base_y >= BOARD_BOTTOM) continue;
        var col: u8 = 0;
        while (col < c.COLS) : (col += 1) {
            const cell = b.cellAt(lr, col);
            if (cell.state == .empty) continue;
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

// Always the player's own cursor -- the CPU has no cursor to show (its board
// is drawn too small for one to read well, and it has no real input anyway).
// Hidden while touch is the active input method (see state.cursor_hidden) --
// swipes move it relative to wherever it already is rather than aiming at a
// touched tile, so there's nothing the player needs to see it for.
fn drawCursor() void {
    if (s.winner != .none or s.cursor_hidden) return;
    const base_x = c.BOARD_X + @as(i32, s.player.cursor_col) * c.TILE;
    const base_y = c.BOARD_Y + @as(i32, s.player.cursor_row) * c.TILE - @as(i32, @intCast(s.player.scroll_px));

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
    const score_str = std.fmt.bufPrint(&buf, "{d}", .{s.player.score}) catch "0";
    w4.Text(score_str, c.PANEL_X, 14);

    if (s.player.chain > 1) {
        var buf2: [12]u8 = undefined;
        const chain_str = std.fmt.bufPrint(&buf2, "x{d}", .{s.player.chain}) catch "";
        w4.DRAW_COLORS.* = 0x0004;
        w4.Text(chain_str, c.PANEL_X, 28);
    }
}

pub fn drawTitle() void {
    w4.DRAW_COLORS.* = 0x0003;
    w4.Text("PANELPON4", 40, 44);
    w4.DRAW_COLORS.* = 0x0002;
    var buf: [24]u8 = undefined;
    // Every level runs cpu_engine's actual move search -- see
    // cpu_ai.configFor -- lower levels just listen to it far less reliably.
    const label = std.fmt.bufPrint(&buf, "LEVEL {d}", .{s.difficulty}) catch "LEVEL ?";
    w4.Text(label, 58, 68);
    w4.Text("<-      ->", 40, 80);
    w4.Text("PRESS X", 52, 100);
}

pub fn drawGameOver() void {
    const text: []const u8 = switch (s.winner) {
        .player => "YOU WIN",
        .cpu => "YOU LOSE",
        .draw => "DRAW",
        .none => unreachable, // drawGameOver is only ever called once winner != .none
    };
    w4.DRAW_COLORS.* = 0x0001;
    w4.Rect(20, 60, 120, 40);
    w4.DRAW_COLORS.* = 0x0004;
    w4.Text(text, 32, 68);
    w4.DRAW_COLORS.* = 0x0002;
    w4.Text("PRESS X", 40, 84);
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
