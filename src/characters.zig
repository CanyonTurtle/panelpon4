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
};

pub const COUNT = 7;

// Only 3 hues exist, so robot deliberately reuses mermaid's solid teal
// (the garbage block's own accent color) and border_style cycles a second time.
pub const ALL = [COUNT]Character{
    .{ .name = "LIZARD", .sprite = &SPRITE_LIZARD, .face = .{ 9, 3 }, .hues = .{ 0, 0 }, .border_style = .solid },
    .{ .name = "MERMAID", .sprite = &SPRITE_MERMAID, .face = .{ 7, 2 }, .hues = .{ 1, 1 }, .border_style = .checkered },
    .{ .name = "BUG", .sprite = &SPRITE_BUG, .face = .{ 7, 3 }, .hues = .{ 2, 2 }, .border_style = .dashed },
    .{ .name = "CLOUD", .sprite = &SPRITE_CLOUD, .face = .{ 7, 3 }, .hues = .{ 0, 2 }, .border_style = .double },
    .{ .name = "SLIME", .sprite = &SPRITE_SLIME, .face = .{ 7, 3 }, .hues = .{ 1, 2 }, .border_style = .solid },
    .{ .name = "CROW", .sprite = &SPRITE_CROW, .face = .{ 8, 2 }, .hues = .{ 0, 1 }, .border_style = .checkered },
    .{ .name = "ROBOT", .sprite = &SPRITE_ROBOT, .face = .{ 7, 4 }, .hues = .{ 1, 1 }, .border_style = .dashed },
};

// Always differs from player_pick; `roll` mod (COUNT - 1) picks uniformly
// among the other COUNT - 1 characters (see main.zig's reveal screen).
pub fn cpuPickFor(player_pick: u8, roll: u32) u8 {
    const offset: u8 = @intCast(roll % (COUNT - 1));
    return (player_pick + 1 + offset) % COUNT;
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
