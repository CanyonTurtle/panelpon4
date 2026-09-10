// Selectable characters (main.zig): each has a pixel-art silhouette,
// hue/dither pair, border style, and face anchor; expression logic is shared.

pub const BorderStyle = enum { solid, checkered, dashed, double };

pub const SPRITE_W: usize = 14;
pub const SPRITE_H: usize = 11;

// Three separate rounded bumps merging into one wide, flat-bottomed body --
// unmistakably fluffy rather than a single round blob.
const SPRITE_CLOUD = [SPRITE_H][]const u8{
    "..............",
    "..##..##..##..",
    ".############.",
    "##############",
    "##############",
    "##############",
    ".############.",
    "..##########..",
    "....######....",
    "..............",
    "..............",
};

// A rounded beetle body with widely-spread antennae and 4 leg nubs poking
// out past its own sides.
const SPRITE_BUG = [SPRITE_H][]const u8{
    "..#........#..",
    "...#......#...",
    "....######....",
    "..##########..",
    "#..########..#",
    ".############.",
    "#..########..#",
    ".############.",
    "..##########..",
    "....######....",
    "..............",
};

// A head/torso with flowing hair, narrowing at the waist then flaring into
// a wide, clearly-forked fish-tail fin.
const SPRITE_MERMAID = [SPRITE_H][]const u8{
    "..............",
    "....######....",
    "..##########..",
    ".############.",
    "##############",
    ".############.",
    "..##########..",
    "##############",
    "..##......##..",
    "...#......#...",
    "..............",
};

// Long, low body with a head bump to one side -- reads as lying down
// rather than sitting up like the other sprites.
const SPRITE_LIZARD = [SPRITE_H][]const u8{
    "..............",
    "..............",
    ".......##.....",
    "......#####...",
    ".###########..",
    "##############",
    "#############.",
    ".###########..",
    "...#######....",
    ".#.#....#.#...",
    "..............",
};

// Glossy dome tapering into uneven drips at the bottom -- reads as a
// puddle mid-ooze, distinct from the cloud's flat-cut bottom.
const SPRITE_SLIME = [SPRITE_H][]const u8{
    "..............",
    "....######....",
    "..##########..",
    ".############.",
    "##############",
    "##############",
    ".############.",
    "..##.####.##..",
    "..#...##...#..",
    "..#....#...#..",
    "..............",
};

// Bird silhouette facing left (beak on the left, tapered tail on the
// right) -- unlike the others, this one reads as facing a direction.
const SPRITE_CROW = [SPRITE_H][]const u8{
    "..............",
    ".......###....",
    "......#####...",
    ".....#######..",
    "....#########.",
    "#..###########",
    ".#############",
    ".#############",
    "..############",
    "...#......#...",
    "..............",
};

// Boxy, mechanical silhouette (antenna + squared block + bolt nubs) --
// rigid and geometric next to everyone else's organic shape.
const SPRITE_ROBOT = [SPRITE_H][]const u8{
    "......##......",
    "......##......",
    ".############.",
    "##############",
    "##############",
    "#.##########.#",
    "##############",
    "##############",
    ".############.",
    "...#......#...",
    "..............",
};

pub const Character = struct {
    name: []const u8,
    sprite: *const [SPRITE_H][]const u8,
    face: [2]i32, // where the shared expression (eyes/mouth) centers, relative to the sprite's own top-left
    hues: [2]u8, // index into HUE_DRAWCOLOR (0=red,1=teal,2=yellow); equal = solid fill, different = dithered
    border_style: BorderStyle,
    base_hue: f32, // degrees; see triadicPalette -- this character's own console palette
    // Story mode's walk-up transition line, spoken as cursed opponent or
    // party member alike (render_screens.drawStoryWalkTransition); keep to 14 chars or fewer, the panel's own text width.
    dialogue: []const u8,
};

pub const COUNT = 7;

// Named indices into ALL, matching declaration order below -- lets
// game_modes.zig's unlock conditions reference characters by name.
pub const LIZARD_INDEX: u8 = 0;
// Story mode locks the player to her (state.player_character) and excludes
// her from the opponent cycle (game_modes.storyOpponentFor) -- she frees everyone else, not cursed herself.
pub const MERMAID_INDEX: u8 = 1;
pub const BUG_INDEX: u8 = 2;
pub const CLOUD_INDEX: u8 = 3;
pub const SLIME_INDEX: u8 = 4;
pub const CROW_INDEX: u8 = 5;
pub const ROBOT_INDEX: u8 = 6;

// Only 3 hues exist, so robot deliberately reuses mermaid's solid teal
// (the garbage block's own accent color) and border_style cycles a second time.
pub const ALL = [COUNT]Character{
    .{ .name = "LIZARD", .sprite = &SPRITE_LIZARD, .face = .{ 9, 3 }, .hues = .{ 0, 0 }, .border_style = .solid, .base_hue = 0, .dialogue = "STILL CURSED" },
    .{ .name = "MERMAID", .sprite = &SPRITE_MERMAID, .face = .{ 7, 2 }, .hues = .{ 1, 1 }, .border_style = .checkered, .base_hue = 51, .dialogue = "FREE THEM ALL!" },
    .{ .name = "BUG", .sprite = &SPRITE_BUG, .face = .{ 7, 3 }, .hues = .{ 2, 2 }, .border_style = .dashed, .base_hue = 103, .dialogue = "IT BITES AT ME" },
    .{ .name = "CLOUD", .sprite = &SPRITE_CLOUD, .face = .{ 7, 3 }, .hues = .{ 0, 2 }, .border_style = .double, .base_hue = 154, .dialogue = "SO FOGGY..." },
    .{ .name = "SLIME", .sprite = &SPRITE_SLIME, .face = .{ 7, 3 }, .hues = .{ 1, 2 }, .border_style = .solid, .base_hue = 206, .dialogue = "CAN'T STOP IT" },
    .{ .name = "CROW", .sprite = &SPRITE_CROW, .face = .{ 8, 2 }, .hues = .{ 0, 1 }, .border_style = .checkered, .base_hue = 257, .dialogue = "IT PULLS AT ME" },
    .{ .name = "ROBOT", .sprite = &SPRITE_ROBOT, .face = .{ 7, 4 }, .hues = .{ 1, 1 }, .border_style = .dashed, .base_hue = 309, .dialogue = "SYSTEM ERROR" },
};

// Always differs from player_pick; `roll` mod (COUNT - 1) picks uniformly
// among the other COUNT - 1 characters (see main.zig's reveal screen).
pub fn cpuPickFor(player_pick: u8, roll: u32) u8 {
    const offset: u8 = @intCast(roll % (COUNT - 1));
    return (player_pick + 1 + offset) % COUNT;
}

fn channel(v: f32) u8 {
    return @intFromFloat(@round(@min(1.0, @max(0.0, v)) * 255.0));
}

// Standard HSL -> packed 0xRRGGBB (h in degrees, any range; s/l in 0..1).
fn hslToRgb(h_deg: f32, s: f32, l: f32) u32 {
    const h = @mod(@mod(h_deg, 360.0) + 360.0, 360.0) / 360.0;
    const chroma = (1.0 - @abs(2.0 * l - 1.0)) * s;
    const hp = h * 6.0;
    const x = chroma * (1.0 - @abs(@mod(hp, 2.0) - 1.0));
    const m = l - chroma / 2.0;
    const rgb: [3]f32 = if (hp < 1.0)
        .{ chroma, x, 0 }
    else if (hp < 2.0)
        .{ x, chroma, 0 }
    else if (hp < 3.0)
        .{ 0, chroma, x }
    else if (hp < 4.0)
        .{ 0, x, chroma }
    else if (hp < 5.0)
        .{ x, 0, chroma }
    else
        .{ chroma, 0, x };
    return (@as(u32, channel(rgb[0] + m)) << 16) | (@as(u32, channel(rgb[1] + m)) << 8) | channel(rgb[2] + m);
}

pub const TriadicPalette = struct { bg: u32, a: u32, b: u32, c: u32 };

// The pre-triadic fixed palette's own red/yellow hues (0xf97690/0xfbef6a,
// recovered via HSL -- not round numbers since matching perceived hue matters more than a tidy constant).
const RED_ANCHOR: f32 = 348.09;
const YELLOW_ANCHOR: f32 = 55.03;

fn circularDist(a: f32, b: f32) f32 {
    const raw = @mod(a - b, 360.0);
    return @abs(if (raw > 180.0) raw - 360.0 else raw);
}

// Which candidate offset (0, 120, or 240) reads closest to RED_ANCHOR.
fn reddestOffset(base_hue_deg: f32) f32 {
    const d0 = circularDist(base_hue_deg, RED_ANCHOR);
    const d120 = circularDist(base_hue_deg + 120.0, RED_ANCHOR);
    const d240 = circularDist(base_hue_deg + 240.0, RED_ANCHOR);
    if (d0 <= d120 and d0 <= d240) return 0.0;
    if (d120 <= d240) return 120.0;
    return 240.0;
}

// 3 hues, 120 degrees apart -- reassigned by closeness so `a` (HEART) is
// always the reddest of the 3, `c` (STAR) the yellowest of what's left, `b` (TRIANGLE) whatever remains.
pub fn triadicPalette(base_hue_deg: f32) TriadicPalette {
    const red_hue = base_hue_deg + reddestOffset(base_hue_deg);
    const other1 = red_hue + 120.0;
    const other2 = red_hue + 240.0;
    const other1_is_yellow = circularDist(other1, YELLOW_ANCHOR) <= circularDist(other2, YELLOW_ANCHOR);
    const yellow_hue = if (other1_is_yellow) other1 else other2;
    const teal_hue = if (other1_is_yellow) other2 else other1;
    return .{
        .bg = hslToRgb(base_hue_deg, 0.30, 0.11),
        .a = hslToRgb(red_hue, 0.72, 0.68),
        .b = hslToRgb(teal_hue, 0.72, 0.68),
        .c = hslToRgb(yellow_hue, 0.72, 0.68),
    };
}

test "cpuPickFor always differs from player_pick and picks uniformly mod COUNT - 1" {
    const testing = @import("std").testing;

    // Never matches the player's pick, for every starting pick and every roll.
    var player_pick: u8 = 0;
    while (player_pick < COUNT) : (player_pick += 1) {
        var roll: u32 = 0;
        while (roll < COUNT - 1) : (roll += 1) {
            const pick = cpuPickFor(player_pick, roll);
            try testing.expect(pick != player_pick);
            try testing.expect(pick < COUNT);
        }
    }

    // roll 0..COUNT-2 covers every character except player_pick exactly once.
    var seen = [_]bool{false} ** COUNT;
    var roll: u32 = 0;
    while (roll < COUNT - 1) : (roll += 1) {
        seen[cpuPickFor(2, roll)] = true;
    }
    var i: u8 = 0;
    while (i < COUNT) : (i += 1) {
        try testing.expectEqual(i != 2, seen[i]);
    }
}

test "hslToRgb reproduces pure red/green/blue at their exact hues" {
    const testing = @import("std").testing;
    try testing.expectEqual(@as(u32, 0xff0000), hslToRgb(0, 1.0, 0.5));
    try testing.expectEqual(@as(u32, 0x00ff00), hslToRgb(120, 1.0, 0.5));
    try testing.expectEqual(@as(u32, 0x0000ff), hslToRgb(240, 1.0, 0.5));
}

test "hslToRgb wraps negative and >360 hues the same as their canonical hue" {
    const testing = @import("std").testing;
    try testing.expectEqual(hslToRgb(30, 0.6, 0.5), hslToRgb(390, 0.6, 0.5));
    try testing.expectEqual(hslToRgb(30, 0.6, 0.5), hslToRgb(-330, 0.6, 0.5));
}

test "triadicPalette's a/b/c are always some rotation of base/+120/+240" {
    const testing = @import("std").testing;
    var base: f32 = 0;
    while (base < 360) : (base += 7) {
        const p = triadicPalette(base);
        const cands = [3]u32{
            hslToRgb(base, 0.72, 0.68),
            hslToRgb(base + 120.0, 0.72, 0.68),
            hslToRgb(base + 240.0, 0.72, 0.68),
        };
        // a/b/c is some permutation of the 3 raw triadic candidates --
        // reassigned by closeness (see reddestOffset), never invented.
        for ([3]u32{ p.a, p.b, p.c }) |color| {
            const found = color == cands[0] or color == cands[1] or color == cands[2];
            try testing.expect(found);
        }
        // And genuinely a permutation, not the same candidate reused twice.
        try testing.expect(p.a != p.b and p.b != p.c and p.a != p.c);
    }
}

test "triadicPalette's `a` is always this character's reddest of the 3 hues" {
    const testing = @import("std").testing;
    var base: f32 = 0;
    while (base < 360) : (base += 7) {
        const p = triadicPalette(base);
        const da = circularDist(hueOf(p.a), RED_ANCHOR);
        const db = circularDist(hueOf(p.b), RED_ANCHOR);
        const dc = circularDist(hueOf(p.c), RED_ANCHOR);
        try testing.expect(da <= db and da <= dc);
    }
}

// Recovers a candidate's hue from its known 0.72/0.68 saturation/lightness --
// lossy in general, but exact here since this same hslToRgb generated it.
fn hueOf(rgb: u32) f32 {
    var probe: f32 = 0;
    while (probe < 360) : (probe += 1) {
        if (hslToRgb(probe, 0.72, 0.68) == rgb) return probe;
    }
    unreachable; // every candidate this test feeds in came from hslToRgb itself
}

test "every character's base_hue is in [0, 360) and all 7 are distinct" {
    const testing = @import("std").testing;
    var seen = [_]bool{false} ** 360;
    for (ALL) |char| {
        try testing.expect(char.base_hue >= 0 and char.base_hue < 360);
        const idx: usize = @intFromFloat(char.base_hue);
        try testing.expect(!seen[idx]);
        seen[idx] = true;
    }
}

test "the named *_INDEX constants actually match ALL's declaration order" {
    const testing = @import("std").testing;
    try testing.expectEqualStrings("LIZARD", ALL[LIZARD_INDEX].name);
    try testing.expectEqualStrings("MERMAID", ALL[MERMAID_INDEX].name);
    try testing.expectEqualStrings("BUG", ALL[BUG_INDEX].name);
    try testing.expectEqualStrings("CLOUD", ALL[CLOUD_INDEX].name);
    try testing.expectEqualStrings("SLIME", ALL[SLIME_INDEX].name);
    try testing.expectEqualStrings("CROW", ALL[CROW_INDEX].name);
    try testing.expectEqualStrings("ROBOT", ALL[ROBOT_INDEX].name);
}
