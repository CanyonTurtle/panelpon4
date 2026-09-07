// Pixel-art symbols drawn on top of each block color, so shapes stay
// distinguishable even without color. See render.zig's SYMBOLS pairing
// comment for which symbol goes with which color.

pub const SYMBOL_SIZE: usize = 11; // same parity as render.BLOCK_SIZE -> perfectly centered, no remainder

pub const SYM_CIRCLE = [SYMBOL_SIZE][]const u8{
    "....###....",
    "..##...##..",
    ".#.......#.",
    ".#.......#.",
    "#.........#",
    "#.........#",
    "#.........#",
    ".#.......#.",
    ".#.......#.",
    "..##...##..",
    "....###....",
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
pub const SYM_DIAMOND = [SYMBOL_SIZE][]const u8{
    ".....#.....",
    "....#.#....",
    "...#...#...",
    "..#.....#..",
    ".#.......#.",
    "#.........#",
    ".#.......#.",
    "..#.....#..",
    "...#...#...",
    "....#.#....",
    ".....#.....",
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
pub const SYM_STAR = [SYMBOL_SIZE][]const u8{
    ".....#.....",
    ".....#.....",
    ".....#.....",
    "...#.#.#...",
    "....###....",
    "###########",
    "....###....",
    "...#.#.#...",
    ".....#.....",
    ".....#.....",
    ".....#.....",
};
// Colors 0-2 are the solid hues (red, teal, yellow). Colors 3-4 are dithered
// checkerboard blends of two adjacent hues -- red+teal reads as purple, and
// teal+yellow reads as green -- giving 5 distinguishable block colors out of
// only 3 real hues (WASM-4's palette has just 4 slots total, one of which is
// the background). Symbols follow the requested pairing: heart/red,
// triangle/teal, star/yellow, diamond/purple, circle/green.
pub const SYMBOLS = [5][SYMBOL_SIZE][]const u8{ SYM_HEART, SYM_TRIANGLE, SYM_STAR, SYM_DIAMOND, SYM_CIRCLE };
