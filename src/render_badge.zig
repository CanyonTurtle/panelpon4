// Rendering for the chain/combo match popup badge (see state.MatchPopup) --
// split out from render.zig to keep that file under the project's
// ~500-line-per-file guideline. Also home to the shared checkerboard-blit
// dithering primitive (drawDitheredRectBlit), a reusable building block for
// any future dithered-highlight effect, not just this badge.

const c = @import("constants.zig");
const s = @import("state.zig");
const w4 = @import("wasm4.zig");

// nibble values for DRAW_COLORS color1, one per palette slot (index+1) --
// mirrors render.zig's own DC_BG/HUE_DRAWCOLOR mapping.
const DC_BG: u16 = 1;
const HUE_DRAWCOLOR = [3]u16{ 2, 3, 4 };

// Shared "warning/highlight" dither: red + yellow, the brightest pair
// available, reading as orange. Used here for the badge, and by
// render.zig's cursor outline.
pub const WARM_DITHER_HUES = [2]u8{ 0, 2 };

// A checkerboard bitmap big enough to cover the whole board plus a 1px
// margin on every edge, so any highlight rect up to the full board size can
// be cut out of it via a single blitSub call instead of plotting a dither
// pixel by pixel. The 1px margin gives drawDitheredRectBlit's src_x/src_y
// phase-alignment offset (0 or 1) somewhere to read from without ever
// running past the edge of this bitmap, for any rect up to the full board's
// width/height.
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
// to absolute screen coordinates -- the same `(x+y) % 2` rule render.zig's
// plotDithered/drawColorRect use -- so adjacent or moving dithered rects
// stay visually consistent instead of each restarting the pattern at its own
// top-left corner.
pub fn drawDitheredRectBlit(x: i32, y: i32, w: i32, h: i32, hues: [2]u8) void {
    if (w <= 0 or h <= 0) return;
    w4.DRAW_COLORS.* = HUE_DRAWCOLOR[hues[0]] | (HUE_DRAWCOLOR[hues[1]] << 4);
    const src_x: u32 = @intCast(@mod(x, 2));
    const src_y: u32 = @intCast(@mod(y, 2));
    w4.BlitSub(&checker_board, x, y, @intCast(w), @intCast(h), src_x, src_y, @intCast(CHECKER_W), w4.BLIT_1BPP);
}

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
// chamfer idea as render.drawBevelledBlock's corner punch, giving the badge
// a subtly rounded, beveled edge instead of a harsh flat rectangle.
fn drawBadgeOutline(x: i32, y: i32, w: i32, h: i32) void {
    if (w <= 2 or h <= 2) return;
    w4.DRAW_COLORS.* = DC_BG;
    w4.Rect(x + 1, y, @intCast(w - 2), 1); // top
    w4.Rect(x + 1, y + h - 1, @intCast(w - 2), 1); // bottom
    w4.Rect(x, y + 1, 1, @intCast(h - 2)); // left
    w4.Rect(x + w - 1, y + 1, 1, @intCast(h - 2)); // right
}

// Small warm-dithered pips in the gutter beside a board, one per queued
// incoming garbage attack (see Board.incoming_garbage) -- a lightweight
// heads-up that an attack is about to land the instant this board goes idle,
// visible without having to read the board itself. Width scales with the
// attack's own width in columns, so a full 6-wide row and a narrow 3-wide
// combo read as visibly different threats; height is a fixed small pip per
// queued attack, not proportional to `rows` -- a multi-row chain attack is
// still one single incoming event, just a bigger one. Stacked downward from
// `top_y`.
const QUEUE_ICON_H: i32 = 4;
const QUEUE_ICON_GAP: i32 = 2;

pub fn drawGarbageQueueIcons(x: i32, top_y: i32, board: *const s.Board) void {
    var y = top_y;
    for (board.incoming_garbage) |slot| {
        const attack = slot orelse continue;
        const w = @as(i32, attack.width) + 2;
        drawDitheredRectBlit(x, y, w, QUEUE_ICON_H, WARM_DITHER_HUES);
        y += QUEUE_ICON_H + QUEUE_ICON_GAP;
    }
}

// Best-of-N match-point pips (see constants.POINTS_TO_WIN/state.set_winner)
// -- one per point needed to take the series, filled solid once earned,
// just an outline otherwise. Used by both render.drawPanel (the player) and
// render_cpu.draw (the CPU), next to each side's own score.
const POINT_PIP_SIZE: i32 = 4;
const POINT_PIP_GAP: i32 = 2;

pub fn drawPoints(x: i32, y: i32, points: u8) void {
    var i: u8 = 0;
    while (i < c.POINTS_TO_WIN) : (i += 1) {
        const px = x + @as(i32, i) * (POINT_PIP_SIZE + POINT_PIP_GAP);
        if (i < points) {
            w4.DRAW_COLORS.* = 0x0004;
            w4.Rect(px, y, POINT_PIP_SIZE, POINT_PIP_SIZE);
        } else {
            w4.DRAW_COLORS.* = 0x0002;
            w4.Rect(px, y, POINT_PIP_SIZE, 1);
            w4.Rect(px, y + POINT_PIP_SIZE - 1, POINT_PIP_SIZE, 1);
            w4.Rect(px, y, 1, POINT_PIP_SIZE);
            w4.Rect(px + POINT_PIP_SIZE - 1, y, 1, POINT_PIP_SIZE);
        }
    }
}

// `target_x`/`target_y` is roughly where the caller's own score digits sit
// (see render.drawPanel/render_cpu.draw) -- popups fly there. A parameter
// rather than a fixed constant since the player and CPU panels put their
// score at different positions/scales.
pub fn drawMatchPopups(match_popups: []const s.MatchPopup, target_x: i32, target_y: i32) void {
    for (match_popups) |p| {
        if (!p.active) continue;

        var cur_x = p.x;
        var cur_y = p.y;
        if (p.elapsed < s.MATCH_POPUP_RISE) {
            // Quickly eases up just a couple pixels -- a small, local hop
            // meant to catch the eye right at the match, not travel anywhere
            // (ease-out: fast start, settling in).
            const t: i32 = p.elapsed;
            const total: i32 = s.MATCH_POPUP_RISE;
            const remain = total - t;
            const num = total * total - remain * remain;
            const den = total * total;
            cur_y = p.y + @divTrunc((p.edge_y - p.y) * num, den);
        } else if (p.elapsed < p.pop_end) {
            // Waits right there until the match's own pop animation actually
            // finishes -- see p.pop_end.
            cur_y = p.edge_y;
        } else {
            // Ease-in toward the score (t^2, not a constant-speed drift) --
            // starts slow and accelerates now that the match has cleared,
            // reading as a "magnetic pull" rather than a simple slide.
            const fly_elapsed: i32 = p.elapsed - p.pop_end;
            const fly_total: i32 = s.MATCH_POPUP_FLY;
            const num = fly_elapsed * fly_elapsed;
            const den = fly_total * fly_total;
            cur_x = p.x + @divTrunc((target_x - p.x) * num, den);
            cur_y = p.edge_y + @divTrunc((target_y - p.edge_y) * num, den);
        }

        const label = p.label[0..p.label_len];
        const badge_w = @as(i32, @intCast(label.len)) * MATCH_POPUP_CHAR_W + 2 * MATCH_POPUP_PAD_X;
        const badge_h = MATCH_POPUP_CHAR_W + MATCH_POPUP_PAD_TOP + MATCH_POPUP_PAD_BOTTOM;
        const badge_x = cur_x - @divTrunc(badge_w, 2);
        const badge_y = cur_y - @divTrunc(badge_h, 2);

        drawDitheredRectBlit(badge_x, badge_y, badge_w, badge_h, WARM_DITHER_HUES);
        drawBadgeOutline(badge_x, badge_y, badge_w, badge_h);
        // Black text directly on the bright orange block reads clearly on
        // its own -- the same technique render.drawSymbolFor uses for
        // symbols on a block color -- so no separate outline pass is needed
        // here.
        w4.DRAW_COLORS.* = DC_BG;
        w4.Text(label, badge_x + MATCH_POPUP_PAD_X, badge_y + MATCH_POPUP_PAD_TOP);
    }
}
