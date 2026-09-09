// The 4 selectable characters (see main.zig's setup screen): a real pixel-
// art silhouette each (see SPRITE_W/H below, same text-art convention as
// symbols.zig), plus a distinct hue/dither pair, main-frame border style,
// and a face anchor -- where the shared, state-and-frame-driven expression
// (eyes/mouth, see render_character.zig) gets centered on top of that
// silhouette. The expression logic itself is shared across all 4 (the same
// normal/combo/punish/win animations, just recolored and repositioned to
// each one's own head), rather than a fully separate hand-animated face per
// character.

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

// A long, low body (using the full width, not a round blob) with a head
// bump to one side and tiny leg nubs underneath -- reads as lying down
// rather than sitting up like the other 3.
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

// A rounded, glossy dome that tapers into 3 uneven drips at the bottom --
// distinct from the cloud's own 3-bump top and flat-cut bottom, this one's
// smooth on top and irregular underneath, reading as a puddle mid-ooze
// rather than a fluffy puff.
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

// A compact bird silhouette facing left: a single-pixel beak poking past
// the head on the left, a rounded body, and a tapered tail point on the
// right -- unlike every other character's own head-bump/leg-nub silhouette,
// this one reads as facing a specific direction.
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

// A boxy, mechanical silhouette -- a thin antenna on top, a squared-off
// head/body block, and two small bolt-like nubs poking out the sides at
// mid-height (same poking-past-the-silhouette technique as the bug's own
// antennae/legs) -- unmistakably rigid and geometric next to every other
// character's rounded, organic shape.
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

// Only 3 real hues exist (see HUE_DRAWCOLOR), so there are only 6 distinct
// looks total: 3 solid (already lizard/mermaid/bug) and 3 dithered pairs --
// red+teal (purple), teal+yellow (green), red+yellow (already cloud's own
// orange). Slime and crow claim the last 2 dithered pairs; robot reuses
// mermaid's solid teal deliberately -- it's the real in-game garbage
// block's own accent color, a fitting match for a "garbage themed"
// character even though the hue itself repeats (its boxy silhouette and
// dashed border read nothing like mermaid regardless). border_style
// likewise cycles back through the 4 options a second time, same reasoning.
pub const ALL = [COUNT]Character{
    .{ .name = "LIZARD", .sprite = &SPRITE_LIZARD, .face = .{ 9, 3 }, .hues = .{ 0, 0 }, .border_style = .solid },
    .{ .name = "MERMAID", .sprite = &SPRITE_MERMAID, .face = .{ 7, 2 }, .hues = .{ 1, 1 }, .border_style = .checkered },
    .{ .name = "BUG", .sprite = &SPRITE_BUG, .face = .{ 7, 3 }, .hues = .{ 2, 2 }, .border_style = .dashed },
    .{ .name = "CLOUD", .sprite = &SPRITE_CLOUD, .face = .{ 7, 3 }, .hues = .{ 0, 2 }, .border_style = .double },
    .{ .name = "SLIME", .sprite = &SPRITE_SLIME, .face = .{ 7, 3 }, .hues = .{ 1, 2 }, .border_style = .solid },
    .{ .name = "CROW", .sprite = &SPRITE_CROW, .face = .{ 8, 2 }, .hues = .{ 0, 1 }, .border_style = .checkered },
    .{ .name = "ROBOT", .sprite = &SPRITE_ROBOT, .face = .{ 7, 4 }, .hues = .{ 1, 1 }, .border_style = .dashed },
};

// The CPU always picks a different character than the player's current
// pick (see main.zig, which now plays this out as its own animated reveal
// screen) -- `roll` (any value; only taken mod COUNT - 1) picks uniformly
// among the COUNT - 1 characters that aren't player_pick, so the CPU's
// choice genuinely varies run to run instead of always being "the next
// one" -- only that the two sides never visually clash is guaranteed.
pub fn cpuPickFor(player_pick: u8, roll: u32) u8 {
    const offset: u8 = @intCast(roll % (COUNT - 1));
    return (player_pick + 1 + offset) % COUNT;
}
