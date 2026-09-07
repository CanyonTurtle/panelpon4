// All drawing: palette setup, the board/cursor/panel, and the title/game-over
// screens. Not unit tested -- everything here bottoms out in WASM4's extern
// draw calls, which only make sense under an actual WASM4 host.

const std = @import("std");
const c = @import("constants.zig");
const s = @import("state.zig");
const w4 = @import("wasm4.zig");
const sym = @import("symbols.zig");

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

// Shared "warning/highlight" dither: red + yellow, the brightest pair
// available, reading as orange. Used by the cursor outline, the combo-chain
// flash, and the flying combo popup.
const WARM_DITHER_HUES = [2]u8{ 0, 2 };

// A checkerboard bitmap big enough to cover the whole board plus a 1px
// margin on every edge, so any highlight rect up to the full board size can
// be cut out of it via a single blitSub call instead of plotting a dither
// pixel by pixel (see drawColorRect/plotDithered above, which still do that
// for the normal per-tile block fills -- this is a separate, reusable
// primitive for overlay effects like the combo flash/popup below, and for
// any future dithered animation that wants the same trick). The 1px margin
// gives drawDitheredRectBlit's src_x/src_y phase-alignment offset (0 or 1)
// somewhere to read from without ever running past the edge of this bitmap,
// for any rect up to the full board's width/height.
const CHECKER_W: usize = @as(usize, c.COLS) * @as(usize, @intCast(c.TILE)) + 2;
const CHECKER_H: usize = @as(usize, c.VISIBLE_ROWS) * @as(usize, @intCast(c.TILE)) + 2;
const CHECKER_BYTES: usize = (CHECKER_W * CHECKER_H + 7) / 8;

const checker_board: [CHECKER_BYTES]u8 = blk: {
    @setEvalBranchQuota(200_000);
    var buf: [CHECKER_BYTES]u8 = [_]u8{0} ** CHECKER_BYTES;
    var bit_index: usize = 0;
    while (bit_index < CHECKER_W * CHECKER_H) : (bit_index += 1) {
        const x = bit_index % CHECKER_W;
        const y = bit_index / CHECKER_W;
        if ((x + y) % 2 == 0) {
            const byte_i = bit_index / 8;
            const shift: u3 = @intCast(7 - (bit_index % 8));
            buf[byte_i] |= @as(u8, 1) << shift;
        }
    }
    break :blk buf;
};

// Cuts a w x h dithered rect of two hues out of the checkerboard bitmap via
// one hardware blit (WASM4's 1BPP blit: bit 0 -> DRAW_COLORS color1, bit 1 ->
// color2), instead of one Rect() call per pixel. The src_x/src_y offset (0
// or 1, matching x/y's own parity) keeps the checkerboard's phase anchored
// to absolute screen coordinates -- the same `(x+y) % 2` rule
// plotDithered/drawColorRect use -- so adjacent or moving dithered rects
// stay visually consistent instead of each restarting the pattern at its own
// top-left corner.
fn drawDitheredRectBlit(x: i32, y: i32, w: i32, h: i32, hues: [2]u8) void {
    if (w <= 0 or h <= 0) return;
    w4.DRAW_COLORS.* = HUE_DRAWCOLOR[hues[0]] | (HUE_DRAWCOLOR[hues[1]] << 4);
    const src_x: u32 = @intCast(@mod(x, 2));
    const src_y: u32 = @intCast(@mod(y, 2));
    w4.BlitSub(&checker_board, x, y, @intCast(w), @intCast(h), src_x, src_y, @intCast(CHECKER_W), w4.BLIT_1BPP);
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

fn drawPoppingCell(x: i32, y: i32, color: u8, timer: i16) void {
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

fn drawLandingCell(x: i32, y: i32, color: u8, timer: i16) void {
    const elapsed = c.LAND_FRAMES - timer;
    const squash: i32 = if (elapsed < 3) (3 - @as(i32, elapsed)) * 2 else 0;
    const height = BLOCK_SIZE - squash;
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
                    drawNormalCell(x, y, cell.color);
                },
                .falling => drawNormalCell(x, base_y - cell.fall_off, cell.color),
                .popping => drawPoppingCell(x, base_y, cell.color, cell.timer),
                .landing => drawLandingCell(x, base_y, cell.color, cell.timer),
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
const CURSOR_DITHER_HUES = WARM_DITHER_HUES;

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

// Roughly where the score digits sit (see drawPanel) -- popups fly here.
const MATCH_POPUP_TARGET_X: i32 = c.PANEL_X + 14;
const MATCH_POPUP_TARGET_Y: i32 = 10;
// The board's top edge -- badges rise here before the main flight to the
// score (see drawMatchPopups).
const MATCH_POPUP_EDGE_Y: i32 = c.BOARD_Y;

// Sized snugly around the label (WASM4's font is a fixed 8x8 per glyph) with
// a couple pixels of padding -- a small, subtle badge rather than something
// covering the whole match. Extra padding on top keeps the glyph clear of
// the outline (see drawBadgeOutline) instead of touching it.
const MATCH_POPUP_CHAR_W: i32 = 8;
const MATCH_POPUP_PAD_X: i32 = 2;
const MATCH_POPUP_PAD_TOP: i32 = 2;
const MATCH_POPUP_PAD_BOTTOM: i32 = 1;

// A 1px background-colored outline around the badge, with the 4 corner
// pixels left unpainted (showing the dithered fill underneath) -- the same
// chamfer idea as drawBevelledBlock's corner punch, giving the badge a
// subtly rounded, beveled edge instead of a harsh flat rectangle.
fn drawBadgeOutline(x: i32, y: i32, w: i32, h: i32) void {
    if (w <= 2 or h <= 2) return;
    w4.DRAW_COLORS.* = DC_BG;
    w4.Rect(x + 1, y, @intCast(w - 2), 1); // top
    w4.Rect(x + 1, y + h - 1, @intCast(w - 2), 1); // bottom
    w4.Rect(x, y + 1, 1, @intCast(h - 2)); // left
    w4.Rect(x + w - 1, y + 1, 1, @intCast(h - 2)); // right
}

fn drawMatchPopups() void {
    for (s.match_popups) |p| {
        if (!p.active) continue;

        var cur_x = p.x;
        var cur_y = p.y;
        const rise_start = s.MATCH_POPUP_HOLD;
        const fly_start = s.MATCH_POPUP_HOLD + s.MATCH_POPUP_RISE;
        if (p.elapsed < rise_start) {
            // Holds at the height of the match's topmost block.
        } else if (p.elapsed < fly_start) {
            // Quickly eases straight up to the board's top edge -- a short
            // "lift off" before the main flight, proportional to how far
            // above the top edge it already spawned (ease-out: fast start,
            // settling in).
            const t: i32 = p.elapsed - rise_start;
            const total: i32 = s.MATCH_POPUP_RISE;
            const remain = total - t;
            const num = total * total - remain * remain;
            const den = total * total;
            cur_y = p.y + @divTrunc((MATCH_POPUP_EDGE_Y - p.y) * num, den);
        } else {
            // Ease-in toward the score (t^2, not a constant-speed drift) --
            // starts slow and accelerates from the top edge, reading as a
            // "magnetic pull" rather than a simple slide.
            const fly_elapsed: i32 = p.elapsed - fly_start;
            const fly_total: i32 = s.MATCH_POPUP_FLY;
            const num = fly_elapsed * fly_elapsed;
            const den = fly_total * fly_total;
            cur_x = p.x + @divTrunc((MATCH_POPUP_TARGET_X - p.x) * num, den);
            cur_y = MATCH_POPUP_EDGE_Y + @divTrunc((MATCH_POPUP_TARGET_Y - MATCH_POPUP_EDGE_Y) * num, den);
        }

        const label = p.label[0..p.label_len];
        const badge_w = @as(i32, @intCast(label.len)) * MATCH_POPUP_CHAR_W + 2 * MATCH_POPUP_PAD_X;
        const badge_h = MATCH_POPUP_CHAR_W + MATCH_POPUP_PAD_TOP + MATCH_POPUP_PAD_BOTTOM;
        const badge_x = cur_x - @divTrunc(badge_w, 2);
        const badge_y = cur_y - @divTrunc(badge_h, 2);

        drawDitheredRectBlit(badge_x, badge_y, badge_w, badge_h, WARM_DITHER_HUES);
        drawBadgeOutline(badge_x, badge_y, badge_w, badge_h);
        // Black text directly on the bright orange block reads clearly on
        // its own -- the same technique drawSymbolFor uses for symbols on a
        // block color -- so no separate outline pass is needed here.
        w4.DRAW_COLORS.* = DC_BG;
        w4.Text(label, badge_x + MATCH_POPUP_PAD_X, badge_y + MATCH_POPUP_PAD_TOP);
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
    drawMatchPopups();
}
