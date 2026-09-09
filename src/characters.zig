// The 4 selectable characters (see main.zig's setup screen): each just a
// distinct hue/dither pair, a distinct main-frame border style, and a
// distinct emblem (reusing symbols.MICRO_SYMBOLS, already in the game for
// the CPU's micro board) -- rather than authoring a fully separate hand-
// drawn portrait per character, the *face* itself (eyes/mouth/expression)
// is shared, state-and-frame-driven logic in render_character.zig, applied
// consistently to whichever character/color/emblem is selected. That's
// what "each character has animations for normal/combo/punish/win, 2 frames
// each" means in practice here: the animation is genuinely state-driven,
// just not a unique bitmap per character on top of that.

const sym = @import("symbols.zig");

pub const BorderStyle = enum { solid, checkered, dashed, double };

pub const Character = struct {
    name: []const u8,
    hues: [2]u8, // index into HUE_DRAWCOLOR (0=red,1=teal,2=yellow); equal = solid fill, different = dithered
    border_style: BorderStyle,
    emblem: u8, // index into symbols.MICRO_SYMBOLS
};

pub const COUNT = 4;

pub const ALL = [COUNT]Character{
    .{ .name = "BLAZE", .hues = .{ 0, 0 }, .border_style = .solid, .emblem = 1 }, // red, triangle
    .{ .name = "WAVE", .hues = .{ 1, 1 }, .border_style = .checkered, .emblem = 4 }, // teal, circle
    .{ .name = "SPARK", .hues = .{ 2, 2 }, .border_style = .dashed, .emblem = 2 }, // yellow, star
    .{ .name = "PRISM", .hues = .{ 0, 2 }, .border_style = .double, .emblem = 3 }, // red+yellow, diamond
};

// The CPU always picks a different character than the player's current
// pick (see main.zig) -- deterministic (not randomized) is plenty: there's
// no expectation of variety run-to-run here, only that the two sides never
// visually clash.
pub fn cpuPickFor(player_pick: u8) u8 {
    return (player_pick + 1) % COUNT;
}
