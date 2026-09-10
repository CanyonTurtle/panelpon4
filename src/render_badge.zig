// Match popup badge rendering (see state_fx.MatchPopup), split out of
// render.zig. Also home to the shared dither primitive drawDitheredRectBlit.

const c = @import("constants.zig");
const s = @import("state.zig");
const fx = @import("state_fx.zig");
const w4 = @import("wasm4.zig");

// nibble values for DRAW_COLORS color1, one per palette slot (index+1) --
// mirrors render.zig's own DC_BG/HUE_DRAWCOLOR mapping.
const DC_BG: u16 = 1;
const HUE_DRAWCOLOR = [3]u16{ 2, 3, 4 };

// Shared "warning/highlight" dither: red+yellow, the brightest pair, reading
// as orange. Used here for the badge, and by render.zig's cursor outline.
pub const WARM_DITHER_HUES = [2]u8{ 0, 2 };

// A checkerboard bitmap sized to the whole board plus a 1px margin, so any
// phase-aligned rect blit (drawDitheredRectBlit) stays in bounds.
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

// One hardware blit instead of per-pixel plotting; src_x/src_y phase-aligns
// the checkerboard to screen coords so adjacent dithered rects stay consistent.
pub fn drawDitheredRectBlit(x: i32, y: i32, w: i32, h: i32, hues: [2]u8) void {
    if (w <= 0 or h <= 0) return;
    w4.DRAW_COLORS.* = HUE_DRAWCOLOR[hues[0]] | (HUE_DRAWCOLOR[hues[1]] << 4);
    const src_x: u32 = @intCast(@mod(x, 2));
    const src_y: u32 = @intCast(@mod(y, 2));
    w4.BlitSub(&checker_board, x, y, @intCast(w), @intCast(h), src_x, src_y, @intCast(CHECKER_W), w4.BLIT_1BPP);
}

// Sized snugly around the 8x8 glyph with small padding; extra padding on
// top keeps the glyph clear of the outline (see drawBadgeOutline).
const MATCH_POPUP_CHAR_W: i32 = 8;
const MATCH_POPUP_PAD_X: i32 = 2;
const MATCH_POPUP_PAD_TOP: i32 = 2;
const MATCH_POPUP_PAD_BOTTOM: i32 = 1;

// Corners left unpainted for a beveled look, same idea as
// render.drawBevelledBlock's corner punch.
fn drawBadgeOutline(x: i32, y: i32, w: i32, h: i32) void {
    if (w <= 2 or h <= 2) return;
    w4.DRAW_COLORS.* = DC_BG;
    w4.Rect(x + 1, y, @intCast(w - 2), 1); // top
    w4.Rect(x + 1, y + h - 1, @intCast(w - 2), 1); // bottom
    w4.Rect(x, y + 1, 1, @intCast(h - 2)); // left
    w4.Rect(x + w - 1, y + 1, 1, @intCast(h - 2)); // right
}

// Pips in the gutter per queued garbage attack (Board.incoming_garbage):
// width scales with attack width, height is a fixed pip per attack.
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

// Best-of-N match-point pips (constants.POINTS_TO_WIN), filled once earned.
// Shared between render.drawPanel (player) and render_cpu.draw (CPU).
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

// target_x/y is where the caller's score digits sit; a parameter rather
// than a constant since player/CPU panels place scores differently.
pub fn drawMatchPopups(match_popups: []const fx.MatchPopup, target_x: i32, target_y: i32) void {
    for (match_popups) |p| {
        if (!p.active) continue;

        var cur_x = p.x;
        var cur_y = p.y;
        if (p.elapsed < fx.MATCH_POPUP_RISE) {
            // Ease-out: a small local hop to catch the eye at the match.
            const t: i32 = p.elapsed;
            const total: i32 = fx.MATCH_POPUP_RISE;
            const remain = total - t;
            const num = total * total - remain * remain;
            const den = total * total;
            cur_y = p.y + @divTrunc((p.edge_y - p.y) * num, den);
        } else if (p.elapsed < p.pop_end) {
            // Waits right there until the match's own pop animation actually
            // finishes -- see p.pop_end.
            cur_y = p.edge_y;
        } else {
            // Ease-in (t^2) toward the score: a "magnetic pull" feel.
            const fly_elapsed: i32 = p.elapsed - p.pop_end;
            const fly_total: i32 = fx.MATCH_POPUP_FLY;
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
        // Black text reads fine on the bright orange badge, no outline pass
        // needed -- same trick render.drawSymbolFor uses for symbols.
        w4.DRAW_COLORS.* = DC_BG;
        w4.Text(label, badge_x + MATCH_POPUP_PAD_X, badge_y + MATCH_POPUP_PAD_TOP);
    }
}
