// Shared character-portrait rendering (see characters.zig for the roster)
// -- used by both render.zig (the player) and render_cpu.zig (the CPU),
// so the two sides get identical treatment regardless of which character
// either one is playing as.

const w4 = @import("wasm4.zig");
const c = @import("constants.zig");
const s = @import("state.zig");
const characters = @import("characters.zig");
const sym = @import("symbols.zig");

// Mirrors render.zig's own DC_BG/HUE_DRAWCOLOR mapping.
const DC_BG: u16 = 1;
const HUE_DRAWCOLOR = [3]u16{ 2, 3, 4 };

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

fn fillHues(hues: [2]u8, x: i32, y: i32, size: i32) void {
    if (hues[0] == hues[1]) {
        w4.DRAW_COLORS.* = HUE_DRAWCOLOR[hues[0]];
        w4.Rect(x, y, @intCast(size), @intCast(size));
        return;
    }
    var dy: i32 = 0;
    while (dy < size) : (dy += 1) {
        var dx: i32 = 0;
        while (dx < size) : (dx += 1) {
            w4.DRAW_COLORS.* = if (@mod(dx + dy, 2) == 0) HUE_DRAWCOLOR[hues[0]] else HUE_DRAWCOLOR[hues[1]];
            w4.Rect(x + dx, y + dy, 1, 1);
        }
    }
}

fn plot(x: i32, y: i32) void {
    w4.Rect(x, y, 1, 1);
}

// A small animated portrait, SIZE x SIZE: filled with the character's own
// hue(s) (solid, or a dithered blend for a two-hue character), a chamfered
// corner punch (the same bevel technique used throughout the game), its
// emblem in the bottom-right corner (reusing symbols.MICRO_SYMBOLS, already
// in the game for the CPU's micro board), and an animated face reacting to
// `state` -- 2 frames (`frame`, from currentFrame() above), the same shared
// expression logic for every character regardless of which one it is.
pub const SIZE: i32 = 14;

pub fn draw(x: i32, y: i32, char_index: u8, state: CharState, frame: u1) void {
    const char = characters.ALL[char_index];
    fillHues(char.hues, x, y, SIZE);

    w4.DRAW_COLORS.* = DC_BG;
    plot(x, y);
    plot(x + SIZE - 1, y);
    plot(x, y + SIZE - 1);
    plot(x + SIZE - 1, y + SIZE - 1);

    const rows = sym.MICRO_SYMBOLS[char.emblem];
    for (rows, 0..) |row, ry| {
        for (row, 0..) |ch, rx| {
            if (ch == '#') plot(x + SIZE - 4 + @as(i32, @intCast(rx)), y + SIZE - 4 + @as(i32, @intCast(ry)));
        }
    }

    const cx = x + @divTrunc(SIZE, 2);
    const cy = y + @divTrunc(SIZE, 2);
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
            const spark_x = if (frame == 0) x + 2 else x + SIZE - 3;
            plot(spark_x, y + 2);
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
            if (frame == 0) plot(x + SIZE - 3, y + 2);
        },
    }
}
