// Shared character-portrait rendering (see characters.zig for the roster
// and each one's own pixel-art sprite) -- used by both render.zig (the
// player) and render_cpu.zig (the CPU), so the two sides get identical
// treatment regardless of which character either one is playing as.

const w4 = @import("wasm4.zig");
const c = @import("constants.zig");
const s = @import("state.zig");
const characters = @import("characters.zig");

// Mirrors render.zig's own DC_BG/HUE_DRAWCOLOR mapping.
const DC_BG: u16 = 1;
const HUE_DRAWCOLOR = [3]u16{ 2, 3, 4 };

pub const W: i32 = @intCast(characters.SPRITE_W);
pub const H: i32 = @intCast(characters.SPRITE_H);

pub const CharState = enum { normal, combo, punish, win };

// Which state a board's own character should currently be shown reacting
// in -- punish (just got hit by an attack) takes priority over combo (just
// scored one of their own), which takes priority over the default idle
// look. `win` is never derived here -- render.drawGameOver passes it
// explicitly for whoever actually won.
pub fn stateFor(board: *const s.Board) CharState {
    if (board.garbage_punish_timer > 0) return .punish;
    if (board.combo_display_timer > 0 or board.chain > 1) return .combo;
    return .normal;
}

// Ticks off state.frame_count, shared by every character -- see
// constants.CHARACTER_ANIM_FRAME_TICKS.
pub fn currentFrame() u1 {
    return @intCast(@mod(@divTrunc(s.frame_count, c.CHARACTER_ANIM_FRAME_TICKS), 2));
}

fn plot(x: i32, y: i32) void {
    w4.Rect(x, y, 1, 1);
}

// A small in-game frame around a character's portrait, themed to its own
// hues/border_style (see characters.BorderStyle) -- a self-contained analog
// of render.zig's drawThemedPanelBorder/drawThemedBand (can't import those
// directly: render.zig already imports this file), scaled down to just
// frame a single sprite rather than a whole menu panel.
pub const FRAME_THICKNESS: i32 = 2;
// Clearance between the sprite and the frame's own inner edge -- gives the
// position bounce/jitter below (see bounceOffset) room to move without
// visibly poking through the frame, without needing the frame itself to be
// huge.
const FRAME_PAD: i32 = 2;
pub const FRAME_MARGIN: i32 = FRAME_PAD + FRAME_THICKNESS;

fn frameBand(x: i32, y: i32, w: i32, h: i32, hues: [2]u8, style: characters.BorderStyle, horizontal: bool) void {
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

// Frames the sprite that will be drawn at (x, y) -- callers pass the same,
// un-bounced x/y they give draw() itself, so the frame stays put even while
// the portrait inside it bounces/jitters around.
pub fn drawFrame(x: i32, y: i32, char_index: u8) void {
    const char = characters.ALL[char_index];
    const fx = x - FRAME_MARGIN;
    const fy = y - FRAME_MARGIN;
    const fw = W + 2 * FRAME_MARGIN;
    const fh = H + 2 * FRAME_MARGIN;
    const t = FRAME_THICKNESS;
    frameBand(fx, fy, fw, t, char.hues, char.border_style, true);
    frameBand(fx, fy + fh - t, fw, t, char.hues, char.border_style, true);
    frameBand(fx, fy, t, fh, char.hues, char.border_style, false);
    frameBand(fx + fw - t, fy, t, fh, char.hues, char.border_style, false);
}

// Position offsets layered on top of the face animation for combo/punish/win
// -- up/down bouncing for an excited combo or a triumphant win, a rapid
// side-to-side jitter for a punish flinch -- read straight off s.frame_count
// (not currentFrame()'s slower blink/mouth toggle), so the motion itself
// feels snappier than the face's own cadence. Explicit per-frame keyframe
// tables, not a continuous sine/random walk -- same convention as render.
// zig's own BOUNCE_KEYFRAMES: hold longer at the peak, move quickly through
// the rest, reading as a deliberate hop/flinch rather than a mechanical
// wobble. Amplitude stays within FRAME_PAD so the sprite never visibly
// clips through its own frame (see drawFrame) while bouncing.
const COMBO_BOUNCE = [12]i32{ 0, -1, -2, -2, -1, 0, 0, -1, -2, -2, -1, 0 };
const WIN_BOUNCE = [16]i32{ 0, -1, -2, -2, -2, -1, 0, 0, 0, -1, -2, -2, -2, -1, 0, 0 };
const PUNISH_JITTER = [8]i32{ 0, 1, -1, 1, 0, -1, 1, 0 };

fn bounceOffset(state: CharState) [2]i32 {
    return switch (state) {
        .normal => .{ 0, 0 },
        .combo => .{ 0, COMBO_BOUNCE[s.frame_count % COMBO_BOUNCE.len] },
        .win => .{ 0, WIN_BOUNCE[s.frame_count % WIN_BOUNCE.len] },
        .punish => .{ PUNISH_JITTER[s.frame_count % PUNISH_JITTER.len], 0 },
    };
}

// Draws a character's own pixel-art sprite (see characters.zig), filled
// with its hue(s) (solid, or a dithered blend for a two-hue character), then
// an animated face reacting to `state` -- 2 frames (`frame`, from
// currentFrame() above) -- centered on the character's own `face` anchor,
// the same shared expression logic for every character regardless of which
// one it is.
pub fn draw(x0: i32, y0: i32, char_index: u8, state: CharState, frame: u1) void {
    const char = characters.ALL[char_index];
    const dithered = char.hues[0] != char.hues[1];
    const off = bounceOffset(state);
    const x = x0 + off[0];
    const y = y0 + off[1];

    for (char.sprite, 0..) |row, ry| {
        for (row, 0..) |ch, rx| {
            if (ch != '#') continue;
            const hue_idx: usize = if (!dithered) 0 else @intCast(@mod(rx + ry, 2));
            w4.DRAW_COLORS.* = HUE_DRAWCOLOR[char.hues[hue_idx]];
            plot(x + @as(i32, @intCast(rx)), y + @as(i32, @intCast(ry)));
        }
    }

    w4.DRAW_COLORS.* = DC_BG;
    const cx = x + char.face[0];
    const cy = y + char.face[1];
    const ex1 = cx - 4;
    const ex2 = cx + 2;
    const ey = cy - 3;

    switch (state) {
        .normal => {
            // A slow blink: eyes open, then a horizontal closed-eye line.
            if (frame == 0) {
                plot(ex1, ey);
                plot(ex2, ey);
            } else {
                plot(ex1, ey + 1);
                plot(ex1 + 1, ey + 1);
                plot(ex2, ey + 1);
                plot(ex2 + 1, ey + 1);
            }
            plot(cx - 1, cy + 3);
            plot(cx, cy + 3);
        },
        .combo => {
            // Wide, excited eyes and an open mouth, with a sparkle toggling
            // side to side.
            plot(ex1, ey);
            plot(ex1, ey + 1);
            plot(ex2, ey);
            plot(ex2, ey + 1);
            plot(cx - 1, cy + 2);
            plot(cx, cy + 2);
            plot(cx - 1, cy + 3);
            plot(cx, cy + 3);
            const spark_x = if (frame == 0) x + 1 else x + W - 2;
            plot(spark_x, y + 1);
        },
        .punish => {
            // A furrowed, angled brow and a small flat mouth -- the second
            // frame widens the eyes slightly, like a flinch.
            plot(ex1, ey - 1);
            plot(ex1 + 1, ey);
            plot(ex2 - 1, ey);
            plot(ex2, ey - 1);
            if (frame == 1) {
                plot(ex1, ey + 1);
                plot(ex2, ey + 1);
            }
            plot(cx - 1, cy + 3);
            plot(cx, cy + 3);
        },
        .win => {
            // Happy, upturned eyes and a big open-mouth smile, with a
            // sparkle blinking on and off.
            plot(ex1, ey + 1);
            plot(ex1 - 1, ey);
            plot(ex2, ey + 1);
            plot(ex2 + 1, ey);
            plot(cx - 2, cy + 2);
            plot(cx - 1, cy + 3);
            plot(cx, cy + 3);
            plot(cx + 1, cy + 2);
            if (frame == 0) plot(x + W - 2, y + 1);
        },
    }
}
