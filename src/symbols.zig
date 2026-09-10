// Pixel-art symbols drawn on top of each block color, so shapes stay
// distinguishable without color. See SYMBOLS below for the color pairing.

pub const SYMBOL_SIZE: usize = 11; // same parity as render_cells.BLOCK_SIZE -> perfectly centered, no remainder

// Inset a full pixel from every edge so it doesn't touch the block's border,
// since BLOCK_SIZE == SYMBOL_SIZE leaves no padding of its own.
pub const SYM_CIRCLE = [SYMBOL_SIZE][]const u8{
    "...........",
    "....###....",
    "..##...##..",
    ".#.......#.",
    ".#.......#.",
    ".#.......#.",
    ".#.......#.",
    ".#.......#.",
    "..##...##..",
    "....###....",
    "...........",
};
// Elongated isosceles: apex, two side rails (staircase), base line -- the
// side rails are visibly longer than the base.
pub const SYM_TRIANGLE = [SYMBOL_SIZE][]const u8{
    "...........",
    "...........",
    ".....#.....",
    ".....#.....",
    "....#.#....",
    "....#.#....",
    "....#.#....",
    "...#...#...",
    "...#####...",
    "...........",
    "...........",
};
// Inset a full pixel from every edge so it doesn't touch the block's border,
// since BLOCK_SIZE == SYMBOL_SIZE leaves no padding of its own.
pub const SYM_DIAMOND = [SYMBOL_SIZE][]const u8{
    "...........",
    ".....#.....",
    "....#.#....",
    "...#...#...",
    "..#.....#..",
    ".#.......#.",
    "..#.....#..",
    "...#...#...",
    "....#.#....",
    ".....#.....",
    "...........",
};
// Shifted 1 row down from the original filled design.
pub const SYM_HEART = [SYMBOL_SIZE][]const u8{
    "...........",
    "..##...##..",
    ".#..###..#.",
    ".#.......#.",
    ".#.......#.",
    ".#.......#.",
    "..#.....#..",
    "...#...#...",
    "....#.#....",
    ".....#.....",
    "...........",
};
// The tips of all 4 arms trimmed by a pixel so it doesn't touch the block's
// border, since BLOCK_SIZE == SYMBOL_SIZE leaves no padding of its own.
pub const SYM_STAR = [SYMBOL_SIZE][]const u8{
    "...........",
    ".....#.....",
    ".....#.....",
    "...#.#.#...",
    "....###....",
    ".#########.",
    "....###....",
    "...#.#.#...",
    ".....#.....",
    ".....#.....",
    "...........",
};
// Colors 0-2 are the solid hues (red, teal, yellow); 3-4 are dithered blends
// (red+teal=purple, teal+yellow=green), giving 5 colors from 3 real hues.
pub const SYMBOLS = [5][SYMBOL_SIZE][]const u8{ SYM_HEART, SYM_TRIANGLE, SYM_STAR, SYM_DIAMOND, SYM_CIRCLE };

// Tiny 3x3 analogs for render_cpu.zig's micro board -- abstracted down to
// each symbol's simplest recognizable silhouette. Same order as SYMBOLS.
pub const MICRO_SYMBOL_SIZE: usize = 3;
pub const MICRO_SYM_HEART = [MICRO_SYMBOL_SIZE][]const u8{
    "#.#",
    "###",
    ".#.",
};
pub const MICRO_SYM_TRIANGLE = [MICRO_SYMBOL_SIZE][]const u8{
    ".#.",
    ".#.",
    "###",
};
pub const MICRO_SYM_STAR = [MICRO_SYMBOL_SIZE][]const u8{
    ".#.",
    "###",
    ".#.",
};
pub const MICRO_SYM_DIAMOND = [MICRO_SYMBOL_SIZE][]const u8{
    ".#.",
    "#.#",
    ".#.",
};
pub const MICRO_SYM_CIRCLE = [MICRO_SYMBOL_SIZE][]const u8{
    "###",
    "#.#",
    "###",
};
pub const MICRO_SYMBOLS = [5][MICRO_SYMBOL_SIZE][]const u8{
    MICRO_SYM_HEART, MICRO_SYM_TRIANGLE, MICRO_SYM_STAR, MICRO_SYM_DIAMOND, MICRO_SYM_CIRCLE,
};
