const std = @import("std");
const w4 = @import("wasm4.zig");

// ---------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------

const COLS: u8 = 6;
const VISIBLE_ROWS: u8 = 10;
const ROWS: u8 = VISIBLE_ROWS + 1; // one extra buffer row rising in from below
const TILE: i32 = 16;
const NUM_COLORS: u8 = 5; // 3 solid hues + 2 dithered blends of adjacent hues

const BOARD_X: i32 = 4;
const BOARD_Y: i32 = 0;
const PANEL_X: i32 = 108;

const POP_FRAMES: i16 = 26;
const POP_FLASH_FRAMES: i16 = 10;
const POP_STAGGER_FRAMES: i16 = 4; // delay between each matched block's pop, so they go one at a time
const LAND_FRAMES: i16 = 8;
const SWAP_FRAMES: i16 = 6;
const FALL_SPEED: i16 = 4; // pixels per frame while falling

const MOVE_DAS_FIRST: u8 = 12;
const MOVE_DAS_REPEAT: u8 = 6;

// nibble values for DRAW_COLORS color1, one per palette slot (index+1)
const DC_BG: u16 = 1;
const HUE_DRAWCOLOR = [3]u16{ 2, 3, 4 };
const DC_FRAME: u16 = 2; // frame/UI accent, reuses hue A

// Blocks have no border color of their own anymore: just a 1px background
// corner-bevel (see BEVEL_RADIUS) and a 1px background gap between tiles
// (see BLOCK_SIZE), plus a symbol drawn in the background color so shapes
// stay distinguishable even without color.
const FRAME_THICKNESS: i32 = 2;
const FRAME_RADIUS: i32 = 2;
const BEVEL_RADIUS: i32 = 1;
// Each block is drawn 1px smaller than its tile, flush with the tile's
// top-left corner; the unused trailing row/column becomes the 1px gap to the
// next tile, so gaps aren't doubled up between neighbors.
const BLOCK_SIZE: i32 = TILE - 1;
const SYMBOL_SIZE: i32 = 11; // same parity as BLOCK_SIZE -> perfectly centered, no remainder

const SYM_CIRCLE = [SYMBOL_SIZE][]const u8{
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
const SYM_TRIANGLE = [SYMBOL_SIZE][]const u8{
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
const SYM_DIAMOND = [SYMBOL_SIZE][]const u8{
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
const SYM_HEART = [SYMBOL_SIZE][]const u8{
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
const SYM_STAR = [SYMBOL_SIZE][]const u8{
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
const SYMBOLS = [5][SYMBOL_SIZE][]const u8{ SYM_HEART, SYM_TRIANGLE, SYM_STAR, SYM_DIAMOND, SYM_CIRCLE };

const DITHER_HUES = [2][2]u8{ .{ 0, 1 }, .{ 1, 2 } };

fn ditherHues(color: u8) ?[2]u8 {
    if (color < 3) return null;
    return DITHER_HUES[color - 3];
}

// ---------------------------------------------------------------------
// State
// ---------------------------------------------------------------------

const CellState = enum(u8) { empty, normal, falling, popping, landing, swapping };

const Cell = struct {
    color: u8 = 0,
    state: CellState = .empty,
    timer: i16 = 0,
    fall_off: i16 = 0, // pixels above true slot while falling
    swap_dir: i8 = 0, // -1, 0, +1: sign of the swap slide offset
    // While popping, `timer` drives this cell's own staggered visual
    // animation, but `pop_group_end` is the same value across every cell in
    // the match and only reaches 0 when the *last* one finishes. Cells are
    // only actually removed (freeing them for gravity) when pop_group_end
    // hits 0, so the pop animation is staggered but the logical disappearance
    // -- and the gravity it triggers -- happens for the whole match at once.
    pop_group_end: i16 = 0,
    // True on an empty cell that was just vacated by a pop, and on any
    // (formerly normal) block that falls through such a cell -- propagated
    // upward through however many blocks fall as part of the same cascade.
    // A match that includes a chainable cell is a genuine chain continuation
    // (something fell into place because of an earlier break); a match made
    // of only ordinary settled blocks is not, even if it happens while some
    // unrelated cascade elsewhere is still busy. Reverts to false the moment
    // a block settles back to .normal without being part of a match -- see
    // checkMatches.
    chainable: bool = false,
};

var grid: [ROWS][COLS]Cell = undefined;
var top: u8 = 0; // physical row index that logical row 0 currently maps to
var scroll_px: u32 = 0;
var rise_frame_counter: u32 = 0;
var rng_state: u32 = 0x9e3779b9;

var cursor_col: u8 = 2;
var cursor_row: u8 = VISIBLE_ROWS - 3;

var score: u32 = 0;
var chain: u8 = 0;

var game_over: bool = false;
var started: bool = false;

var frame_count: u32 = 0;
var prev_gamepad: u8 = 0;
var held_dir: u8 = 0;
var das_counter: u8 = 0;

// ---------------------------------------------------------------------
// RNG
// ---------------------------------------------------------------------

fn rngNext() u32 {
    var x = rng_state;
    x ^= x << 13;
    x ^= x >> 17;
    x ^= x << 5;
    rng_state = x;
    return x;
}

fn randRange(n: u32) u32 {
    return rngNext() % n;
}

// ---------------------------------------------------------------------
// Grid helpers
// ---------------------------------------------------------------------

fn physRow(logical: u8) u8 {
    return @intCast((@as(u16, top) + @as(u16, logical)) % @as(u16, ROWS));
}

fn cellAt(logical_row: u8, col: u8) *Cell {
    return &grid[physRow(logical_row)][col];
}

fn riseSpeedFramesPerPixel() u32 {
    const level = score / 300;
    const speed = if (level > 4) 4 else 8 - level;
    return speed;
}

// ---------------------------------------------------------------------
// Row generation
// ---------------------------------------------------------------------

fn generateRowInto(target_phys: u8, logical_r: u8) void {
    var row_colors: [COLS]u8 = undefined;
    var ci: u8 = 0;
    while (ci < COLS) : (ci += 1) {
        var above1: i16 = -1;
        var above2: i16 = -1;
        if (logical_r >= 1) {
            const cell1 = cellAt(logical_r - 1, ci);
            if (cell1.state == .normal) above1 = cell1.color;
        }
        if (logical_r >= 2) {
            const cell2 = cellAt(logical_r - 2, ci);
            if (cell2.state == .normal) above2 = cell2.color;
        }

        var chosen: u8 = 0;
        var tries: u8 = 0;
        while (true) {
            chosen = @intCast(randRange(NUM_COLORS));
            var ok = true;
            if (ci >= 2 and row_colors[ci - 1] == chosen and row_colors[ci - 2] == chosen) ok = false;
            if (ok and above1 >= 0 and above2 >= 0 and above1 == chosen and above2 == chosen) ok = false;
            tries += 1;
            if (ok or tries > 20) break;
        }
        row_colors[ci] = chosen;
    }

    ci = 0;
    while (ci < COLS) : (ci += 1) {
        grid[target_phys][ci] = Cell{ .color = row_colors[ci], .state = .normal };
    }
}

fn doRise() void {
    var c: u8 = 0;
    while (c < COLS) : (c += 1) {
        if (cellAt(0, c).state != .empty) {
            game_over = true;
            return;
        }
    }
    generateRowInto(top, ROWS - 1);
    top = @intCast((@as(u16, top) + 1) % @as(u16, ROWS));

    // Logical row indices are relative to `top`, so a fixed cursor_row would
    // silently point at a different (lower) absolute row after this shift,
    // which reads as the cursor snapping down. Decrement it to keep tracking
    // the same physical row it was on, so the cursor rises with the stack
    // unless the player is actively moving it.
    if (cursor_row > 0) cursor_row -= 1;
}

fn updateRise() void {
    if (boardBusy()) return;
    rise_frame_counter += 1;
    if (rise_frame_counter >= riseSpeedFramesPerPixel()) {
        rise_frame_counter = 0;
        scroll_px += 1;
        if (scroll_px >= @as(u32, @intCast(TILE))) {
            scroll_px -= @as(u32, @intCast(TILE));
            doRise();
        }
    }
}

// ---------------------------------------------------------------------
// Game setup
// ---------------------------------------------------------------------

fn resetGame() void {
    game_over = false;
    score = 0;
    chain = 0;
    top = 0;
    scroll_px = 0;
    rise_frame_counter = 0;
    cursor_col = 2;
    cursor_row = VISIBLE_ROWS - 3;

    for (0..ROWS) |r| {
        for (0..COLS) |c| {
            grid[r][c] = Cell{};
        }
    }

    const start_rows_filled: u8 = 5;
    var r: u8 = VISIBLE_ROWS - start_rows_filled;
    while (r < ROWS) : (r += 1) {
        generateRowInto(r, r);
    }
}

// ---------------------------------------------------------------------
// Input
// ---------------------------------------------------------------------

fn justPressed(gp: u8, btn: u8) bool {
    return (gp & btn) != 0 and (prev_gamepad & btn) == 0;
}

fn moveCursor(dir: u8) void {
    if (dir == w4.BUTTON_LEFT) {
        if (cursor_col > 0) cursor_col -= 1;
    } else if (dir == w4.BUTTON_RIGHT) {
        if (cursor_col < COLS - 2) cursor_col += 1;
    } else if (dir == w4.BUTTON_UP) {
        if (cursor_row > 0) cursor_row -= 1;
    } else if (dir == w4.BUTTON_DOWN) {
        if (cursor_row < VISIBLE_ROWS - 1) cursor_row += 1;
    }
}

fn updateCursorMovement(gp: u8) void {
    const dirs = [_]u8{ w4.BUTTON_LEFT, w4.BUTTON_RIGHT, w4.BUTTON_UP, w4.BUTTON_DOWN };
    var cur_dir: u8 = 0;
    for (dirs) |d| {
        if (gp & d != 0) {
            cur_dir = d;
            break;
        }
    }
    if (cur_dir == 0) {
        held_dir = 0;
        das_counter = 0;
        return;
    }
    if (cur_dir != held_dir) {
        held_dir = cur_dir;
        das_counter = MOVE_DAS_FIRST;
        moveCursor(cur_dir);
    } else {
        if (das_counter == 0) {
            das_counter = MOVE_DAS_REPEAT;
            moveCursor(cur_dir);
        } else {
            das_counter -= 1;
        }
    }
}

fn swappable(s: CellState) bool {
    return s == .empty or s == .normal;
}

fn trySwap() void {
    const a = cellAt(cursor_row, cursor_col);
    const b = cellAt(cursor_row, cursor_col + 1);
    if (!swappable(a.state) or !swappable(b.state)) return;
    if (a.state == .empty and b.state == .empty) return;

    const a_orig = a.*;
    const b_orig = b.*;
    a.* = b_orig;
    b.* = a_orig;

    a.state = if (b_orig.state == .empty) .empty else .swapping;
    b.state = if (a_orig.state == .empty) .empty else .swapping;

    if (a.state == .swapping) {
        a.timer = SWAP_FRAMES;
        a.swap_dir = 1; // slides in from the right
    }
    if (b.state == .swapping) {
        b.timer = SWAP_FRAMES;
        b.swap_dir = -1; // slides in from the left
    }
    // No chain reset here: chain only resets once the board is fully idle
    // (see the boardBusy() check in update()). Resetting it on every swap
    // would kill "skill chains" -- setting up another match while a previous
    // one is still falling/popping should extend the same chain, not start
    // a fresh one, as long as the board never actually went idle in between.
}

// ---------------------------------------------------------------------
// Simulation: swaps, pops, landings, gravity, matching
// ---------------------------------------------------------------------

fn boardBusy() bool {
    for (0..ROWS) |lr| {
        for (0..COLS) |c| {
            const s = cellAt(@intCast(lr), @intCast(c)).state;
            if (s == .falling or s == .popping or s == .landing or s == .swapping) return true;
        }
    }
    return false;
}

fn simulate() void {
    var settled = false;

    // Progress swap / pop / landing timers.
    for (0..ROWS) |lr| {
        for (0..COLS) |c| {
            const cell = cellAt(@intCast(lr), @intCast(c));
            switch (cell.state) {
                .swapping => {
                    cell.timer -= 1;
                    if (cell.timer <= 0) {
                        cell.state = .normal;
                        cell.swap_dir = 0;
                        settled = true;
                    }
                },
                .popping => {
                    cell.timer -= 1;
                    if (cell.timer == 0) {
                        playPopTick();
                    }
                    cell.pop_group_end -= 1;
                    if (cell.pop_group_end <= 0) {
                        // Mark the vacated cell so whatever falls into it
                        // (see the gravity loop below) is recognized as a
                        // genuine chain continuation.
                        cell.* = Cell{ .chainable = true };
                    }
                },
                .landing => {
                    cell.timer -= 1;
                    if (cell.timer <= 0) {
                        cell.state = .normal;
                        settled = true;
                    }
                },
                else => {},
            }
        }
    }

    // Gravity: scan bottom-to-top per column so falls cascade within a frame.
    for (0..COLS) |ci| {
        const c: u8 = @intCast(ci);
        var r: u8 = ROWS - 1;
        while (r >= 1) : (r -= 1) {
            const below = cellAt(r, c);
            const above = cellAt(r - 1, c);
            if (below.state == .empty and above.state == .normal) {
                // Whether this fall is a chain continuation depends on
                // whether the gap it's filling came from a pop -- carried by
                // the gap's own chainable flag -- not on the falling block's
                // own (should-be-false) one. Propagated to the cell it
                // vacates too, so a block further up the column inherits it
                // when it falls through in a later frame.
                const gap_chainable = below.chainable;
                below.* = above.*;
                below.state = .falling;
                below.fall_off = TILE;
                below.chainable = gap_chainable;
                above.* = Cell{ .chainable = gap_chainable };
            }

            const cur = cellAt(r, c);
            if (cur.state == .falling) {
                cur.fall_off -= FALL_SPEED;
                if (cur.fall_off <= 0) {
                    cur.fall_off = 0;
                    if (r < ROWS - 1 and cellAt(r + 1, c).state == .empty) {
                        const next = cellAt(r + 1, c);
                        const cur_chainable = cur.chainable;
                        next.* = cur.*;
                        next.fall_off = TILE;
                        cur.* = Cell{ .chainable = cur_chainable };
                    } else {
                        // Match-checking happens once the landing bounce
                        // finishes and the cell becomes .normal again (see
                        // the .landing timer branch above) since matches are
                        // only detected among settled, non-animating cells.
                        cur.state = .landing;
                        cur.timer = LAND_FRAMES;
                    }
                }
            }
            if (r == 0) break;
        }
    }

    if (settled) {
        _ = checkMatches();
    }
}

fn checkMatches() bool {
    var settled_color: [ROWS][COLS]i16 = undefined;
    var settled_chainable: [ROWS][COLS]bool = undefined;
    for (0..ROWS) |lr| {
        for (0..COLS) |c| {
            const cell = cellAt(@intCast(lr), @intCast(c));
            settled_color[lr][c] = if (cell.state == .normal) @as(i16, cell.color) else -1;
            settled_chainable[lr][c] = cell.state == .normal and cell.chainable;
        }
    }

    var matched: [ROWS][COLS]bool = std.mem.zeroes([ROWS][COLS]bool);
    var any = false;

    for (0..ROWS) |lr| {
        var c: usize = 0;
        while (c < COLS) {
            const col_ = settled_color[lr][c];
            if (col_ < 0) {
                c += 1;
                continue;
            }
            var run_len: usize = 1;
            while (c + run_len < COLS and settled_color[lr][c + run_len] == col_) run_len += 1;
            if (run_len >= 3) {
                for (0..run_len) |k| matched[lr][c + k] = true;
                any = true;
            }
            c += run_len;
        }
    }

    for (0..COLS) |c| {
        var r: usize = 0;
        while (r < ROWS) {
            const col_ = settled_color[r][c];
            if (col_ < 0) {
                r += 1;
                continue;
            }
            var run_len: usize = 1;
            while (r + run_len < ROWS and settled_color[r + run_len][c] == col_) run_len += 1;
            if (run_len >= 3) {
                for (0..run_len) |k| matched[r + k][c] = true;
                any = true;
            }
            r += run_len;
        }
    }

    if (!any) {
        // These cells settled without matching, so their chain status is
        // spent -- a later, unrelated match involving them shouldn't be
        // credited as a chain continuation.
        for (0..ROWS) |lr| {
            for (0..COLS) |c| {
                if (settled_chainable[lr][c]) cellAt(@intCast(lr), @intCast(c)).chainable = false;
            }
        }
        return false;
    }

    // Matched blocks pop one after another rather than all at once (see
    // POP_STAGGER_FRAMES), but should all *disappear* together once their own
    // cascade finishes, so gravity affects a whole match at once rather than
    // reacting to each gap as it opens (see pop_group_end on Cell). Two
    // matches found in the same call can be unrelated (e.g. opposite corners
    // of the board), so they're grouped by 4-connectivity flood fill and
    // staggered/cleared independently rather than all sharing one timer.
    var visited: [ROWS][COLS]bool = std.mem.zeroes([ROWS][COLS]bool);
    var stack: [ROWS * COLS][2]u8 = undefined;
    var members: [ROWS * COLS][2]u8 = undefined;

    for (0..ROWS) |lr0| {
        for (0..COLS) |c0| {
            if (!matched[lr0][c0] or visited[lr0][c0]) continue;

            var stack_len: usize = 0;
            var member_count: usize = 0;
            stack[stack_len] = .{ @intCast(lr0), @intCast(c0) };
            stack_len += 1;
            visited[lr0][c0] = true;

            while (stack_len > 0) {
                stack_len -= 1;
                const pos = stack[stack_len];
                members[member_count] = pos;
                member_count += 1;
                const r = pos[0];
                const c = pos[1];
                if (r > 0 and matched[r - 1][c] and !visited[r - 1][c]) {
                    visited[r - 1][c] = true;
                    stack[stack_len] = .{ r - 1, c };
                    stack_len += 1;
                }
                if (r + 1 < ROWS and matched[r + 1][c] and !visited[r + 1][c]) {
                    visited[r + 1][c] = true;
                    stack[stack_len] = .{ r + 1, c };
                    stack_len += 1;
                }
                if (c > 0 and matched[r][c - 1] and !visited[r][c - 1]) {
                    visited[r][c - 1] = true;
                    stack[stack_len] = .{ r, c - 1 };
                    stack_len += 1;
                }
                if (c + 1 < COLS and matched[r][c + 1] and !visited[r][c + 1]) {
                    visited[r][c + 1] = true;
                    stack[stack_len] = .{ r, c + 1 };
                    stack_len += 1;
                }
            }

            // Flood-fill visits cells in an arbitrary (DFS) order; sort into
            // row-major order first so the stagger sweeps predictably
            // top-to-bottom, left-to-right instead of looking scattered.
            var oi: usize = 1;
            while (oi < member_count) : (oi += 1) {
                const key = members[oi];
                var oj: usize = oi;
                while (oj > 0 and (members[oj - 1][0] > key[0] or
                    (members[oj - 1][0] == key[0] and members[oj - 1][1] > key[1])))
                {
                    members[oj] = members[oj - 1];
                    oj -= 1;
                }
                members[oj] = key;
            }

            // A connected group is a genuine chain continuation if any of its
            // cells fell into place from an earlier break (chainable); a
            // match made purely of ordinary settled blocks isn't, even if
            // some unrelated cascade elsewhere is still busy right now. The
            // very first match of a fresh combo (chain still 0) always
            // counts, since there's nothing to "continue" yet.
            var group_chainable = false;
            for (0..member_count) |i| {
                const pos = members[i];
                if (settled_chainable[pos[0]][pos[1]]) group_chainable = true;
            }
            var multiplier: u8 = 1;
            if (chain == 0 or group_chainable) {
                chain += 1;
                multiplier = chain;
            }

            const group_end: i16 = POP_FRAMES + @as(i16, @intCast(member_count - 1)) * POP_STAGGER_FRAMES;
            for (0..member_count) |i| {
                const pos = members[i];
                const cell = cellAt(pos[0], pos[1]);
                cell.state = .popping;
                cell.timer = POP_FRAMES + @as(i16, @intCast(i)) * POP_STAGGER_FRAMES;
                cell.pop_group_end = group_end;
            }
            score += @as(u32, @intCast(member_count)) * 10 * multiplier;
            playPopSound(multiplier);
        }
    }

    // Any settled cell that had chainable set but wasn't part of a match
    // (e.g. it fell but landed somewhere that didn't complete a match) has
    // spent its chain status now that it's back to being an ordinary block.
    for (0..ROWS) |lr| {
        for (0..COLS) |c| {
            if (settled_chainable[lr][c] and !matched[lr][c]) {
                cellAt(@intCast(lr), @intCast(c)).chainable = false;
            }
        }
    }

    return true;
}

// ---------------------------------------------------------------------
// Audio
// ---------------------------------------------------------------------

fn playPopSound(multiplier: u8) void {
    const freq = 220 + @as(u32, multiplier) * 40;
    w4.Tone(freq, 8, 30, w4.TONE_PULSE1);
}

fn playPopTick() void {
    w4.Tone(660, 4, 15, w4.TONE_PULSE2);
}

fn playGameOverSound() void {
    w4.Tone(220 | (110 << 16), 40, 40, w4.TONE_TRIANGLE);
}

// ---------------------------------------------------------------------
// Rendering
// ---------------------------------------------------------------------

fn setupPalette() void {
    w4.PALETTE[0] = 0x1a1c2c; // background
    w4.PALETTE[1] = 0xf97690; // hue A: red
    w4.PALETTE[2] = 0x36e4e7; // hue B: teal (dithers with A -> purple, with C -> green)
    w4.PALETTE[3] = 0xfbef6a; // hue C: yellow
}

fn clearBackground() void {
    w4.DRAW_COLORS.* = DC_BG;
    w4.Rect(0, 0, w4.SCREEN_SIZE, w4.SCREEN_SIZE);
}

// Fills a w x h rectangle with a block color: a solid hue, or a 1px
// checkerboard dither blending two hues for colors 3-4.
fn drawColorRect(x: i32, y: i32, w: i32, h: i32, color: u8) void {
    if (w <= 0 or h <= 0) return;
    if (ditherHues(color)) |hues| {
        var dy: i32 = 0;
        while (dy < h) : (dy += 1) {
            var dx: i32 = 0;
            while (dx < w) : (dx += 1) {
                const hue = if (@mod(dx + dy, 2) == 0) hues[0] else hues[1];
                w4.DRAW_COLORS.* = HUE_DRAWCOLOR[hue];
                w4.Rect(x + dx, y + dy, 1, 1);
            }
        }
    } else {
        w4.DRAW_COLORS.* = HUE_DRAWCOLOR[color];
        w4.Rect(x, y, @intCast(w), @intCast(h));
    }
}

fn drawHueSquareCentered(x: i32, y: i32, color: u8, size: i32) void {
    if (size <= 0) return;
    const off = @divTrunc(TILE - size, 2);
    drawColorRect(x + off, y + off, size, size, color);
}

fn drawSymbolFor(color: u8, x: i32, y: i32) void {
    w4.DRAW_COLORS.* = DC_BG;
    const rows = SYMBOLS[color];
    for (rows, 0..) |row, ry| {
        for (row, 0..) |ch, rx| {
            if (ch == '#') {
                w4.Rect(x + @as(i32, @intCast(rx)), y + @as(i32, @intCast(ry)), 1, 1);
            }
        }
    }
}

// Fills a w x h block and punches its 4 corner pixels to background color --
// the same chamfer technique as the frame's rounded corners, just at a fixed
// 1px radius -- giving a subtly rounded look instead of a hard square edge.
fn drawBevelledBlock(x: i32, y: i32, w: i32, h: i32, color: u8) void {
    drawColorRect(x, y, w, h, color);
    if (w <= 2 * BEVEL_RADIUS or h <= 2 * BEVEL_RADIUS) return;
    w4.DRAW_COLORS.* = DC_BG;
    var dy: i32 = 0;
    while (dy < BEVEL_RADIUS) : (dy += 1) {
        var dx: i32 = 0;
        while (dx < BEVEL_RADIUS) : (dx += 1) {
            if (dx + dy < BEVEL_RADIUS) {
                w4.Rect(x + dx, y + dy, 1, 1);
                w4.Rect(x + w - 1 - dx, y + dy, 1, 1);
                w4.Rect(x + dx, y + h - 1 - dy, 1, 1);
                w4.Rect(x + w - 1 - dx, y + h - 1 - dy, 1, 1);
            }
        }
    }
}

fn drawNormalCell(x: i32, y: i32, color: u8) void {
    // Flush with the tile's top-left corner; the unused trailing 1px on the
    // right/bottom becomes the gap to the next tile (see BLOCK_SIZE).
    drawBevelledBlock(x, y, BLOCK_SIZE, BLOCK_SIZE, color);
    const sym_off = @divTrunc(BLOCK_SIZE - SYMBOL_SIZE, 2);
    drawSymbolFor(color, x + sym_off, y + sym_off);
}

fn drawPoppingCell(x: i32, y: i32, color: u8, timer: i16) void {
    const elapsed = POP_FRAMES - timer;
    if (elapsed < 0) {
        // Still waiting its turn in the pop cascade (see POP_STAGGER_FRAMES)
        // -- render exactly like a settled block until then.
        drawNormalCell(x, y, color);
        return;
    }
    var size: i32 = BLOCK_SIZE;
    if (elapsed < POP_FLASH_FRAMES) {
        const puls: i32 = @intCast(@mod(elapsed, 8));
        const delta: i32 = if (puls < 4) puls else 8 - puls;
        size = BLOCK_SIZE - delta;
    } else {
        const shrink_elapsed = elapsed - POP_FLASH_FRAMES;
        const shrink_total = POP_FRAMES - POP_FLASH_FRAMES;
        const remain = shrink_total - shrink_elapsed;
        size = @divTrunc(BLOCK_SIZE * remain, shrink_total);
        if (size < 0) size = 0;
    }
    drawHueSquareCentered(x, y, color, size);
}

fn drawLandingCell(x: i32, y: i32, color: u8, timer: i16) void {
    const elapsed = LAND_FRAMES - timer;
    const squash: i32 = if (elapsed < 3) (3 - @as(i32, elapsed)) * 2 else 0;
    const height = BLOCK_SIZE - squash;
    drawBevelledBlock(x, y + squash, BLOCK_SIZE, height, color);
    if (squash == 0) {
        const sym_off = @divTrunc(BLOCK_SIZE - SYMBOL_SIZE, 2);
        drawSymbolFor(color, x + sym_off, y + sym_off);
    }
}

fn drawSwappingCell(x: i32, y: i32, color: u8, timer: i16, dir: i8) void {
    const offset: i32 = @as(i32, dir) * @divTrunc(TILE * @as(i32, timer), SWAP_FRAMES);
    drawNormalCell(x + offset, y, color);
}

fn drawBoard() void {
    var lr: u8 = 0;
    while (lr < ROWS) : (lr += 1) {
        const base_y = BOARD_Y + @as(i32, lr) * TILE - @as(i32, @intCast(scroll_px));
        if (base_y <= -TILE or base_y >= w4.SCREEN_SIZE) continue;
        var c: u8 = 0;
        while (c < COLS) : (c += 1) {
            const cell = cellAt(lr, c);
            if (cell.state == .empty) continue;
            const x = BOARD_X + @as(i32, c) * TILE;
            switch (cell.state) {
                .normal => drawNormalCell(x, base_y, cell.color),
                .falling => drawNormalCell(x, base_y - cell.fall_off, cell.color),
                .popping => drawPoppingCell(x, base_y, cell.color, cell.timer),
                .landing => drawLandingCell(x, base_y, cell.color, cell.timer),
                .swapping => drawSwappingCell(x, base_y, cell.color, cell.timer, cell.swap_dir),
                .empty => {},
            }
        }
    }
}

// Frame around the playable area with a 2px-radius chamfer at each corner
// (WASM-4's rect() has no rounded-corner support, so the corners are faked
// by punching a small diagonal notch out of the frame in the background
// color).
fn drawFrame() void {
    // Pushed out from the board's own bounding box so the frame doesn't
    // overlap the edge tiles' own fill. Horizontally there's margin to
    // spare, so it's pushed out by the full frame thickness -- plus 1 extra
    // on the left, since blocks are flush with their tile's top-left corner
    // (only the right/bottom get a natural 1px gap from BLOCK_SIZE), so
    // without that extra px the left edge would sit flush against the first
    // column's fill while the right edge already clears the last column's
    // fill by a pixel. There is no vertical margin (the board fills the
    // screen height exactly), so it's pushed out by only 1px on top/bottom --
    // any more would push it fully off-screen and make it invisible rather
    // than just less overlapping.
    const push_left = FRAME_THICKNESS + 1;
    const push_right = FRAME_THICKNESS;
    const push_y = 1;
    const x = BOARD_X - push_left;
    const y = BOARD_Y - push_y;
    const w = @as(i32, COLS) * TILE + push_left + push_right;
    const h = @as(i32, VISIBLE_ROWS) * TILE + 2 * push_y;
    const t = FRAME_THICKNESS;
    const radius = FRAME_RADIUS;

    w4.DRAW_COLORS.* = DC_FRAME;
    w4.Rect(x, y, @intCast(w), @intCast(t)); // top
    w4.Rect(x, y + h - t, @intCast(w), @intCast(t)); // bottom
    w4.Rect(x, y, @intCast(t), @intCast(h)); // left
    w4.Rect(x + w - t, y, @intCast(t), @intCast(h)); // right

    w4.DRAW_COLORS.* = DC_BG;
    var dy: i32 = 0;
    while (dy < radius) : (dy += 1) {
        var dx: i32 = 0;
        while (dx < radius) : (dx += 1) {
            if (dx + dy < radius) {
                w4.Rect(x + dx, y + dy, 1, 1); // top-left
                w4.Rect(x + w - 1 - dx, y + dy, 1, 1); // top-right
                w4.Rect(x + dx, y + h - 1 - dy, 1, 1); // bottom-left
                w4.Rect(x + w - 1 - dx, y + h - 1 - dy, 1, 1); // bottom-right
            }
        }
    }
}

const CURSOR_THICKNESS: i32 = 2;
const CURSOR_PULSE_PERIOD: i32 = 30;
const CURSOR_PULSE_AMOUNT: i32 = 2;

const CURSOR_PUSH: i32 = 1;

fn drawCursor() void {
    if (game_over) return;
    const base_x = BOARD_X + @as(i32, cursor_col) * TILE;
    const base_y = BOARD_Y + @as(i32, cursor_row) * TILE - @as(i32, @intCast(scroll_px));

    // Blink by contracting slightly instead of changing color.
    const half = @divTrunc(CURSOR_PULSE_PERIOD, 2);
    const t: i32 = @intCast(@mod(frame_count, @as(u32, @intCast(CURSOR_PULSE_PERIOD))));
    const tri: i32 = if (t < half) t else CURSOR_PULSE_PERIOD - t;
    const contract = @divTrunc(tri * CURSOR_PULSE_AMOUNT, half);

    // Pushed out so the cursor straddles the boundary of its two tiles and
    // the surrounding ones, rather than tracing exactly over them. Blocks
    // are flush with their tile's top-left corner (only the right/bottom
    // get a natural 1px gap from BLOCK_SIZE), so a push of the same size on
    // every side would land right on a neighbor's fill on the right/bottom
    // but fall a pixel short into the gap on the top/left. The extra 1px on
    // top/left makes it reach the neighboring fill the same amount on every
    // side.
    const push_left = CURSOR_PUSH + 1 - contract;
    const push_top = CURSOR_PUSH + 1 - contract;
    const push_right = CURSOR_PUSH - contract;
    const push_bottom = CURSOR_PUSH - contract;
    const x = base_x - push_left;
    const y = base_y - push_top;
    const w = TILE * 2 + push_left + push_right;
    const h = TILE + push_top + push_bottom;

    w4.DRAW_COLORS.* = DC_BG << 4; // transparent fill, background-colored border
    w4.Rect(x, y, @intCast(w), @intCast(h));
    if (w > 2 and h > 2) {
        w4.Rect(x + 1, y + 1, @intCast(w - 2), @intCast(h - 2));
    }
}

fn drawPanel() void {
    w4.DRAW_COLORS.* = 0x0002;
    w4.Text("SCORE", PANEL_X, 4);
    var buf: [12]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{d}", .{score}) catch "0";
    w4.Text(s, PANEL_X, 14);

    if (chain > 1) {
        var buf2: [12]u8 = undefined;
        const s2 = std.fmt.bufPrint(&buf2, "x{d}", .{chain}) catch "";
        w4.DRAW_COLORS.* = 0x0004;
        w4.Text(s2, PANEL_X, 28);
    }
}

fn drawTitle() void {
    w4.DRAW_COLORS.* = 0x0003;
    w4.Text("PANELPON4", 40, 60);
    w4.DRAW_COLORS.* = 0x0002;
    w4.Text("PRESS X", 52, 80);
}

fn drawGameOver() void {
    w4.DRAW_COLORS.* = 0x0001;
    w4.Rect(20, 60, 120, 40);
    w4.DRAW_COLORS.* = 0x0004;
    w4.Text("GAME OVER", 32, 68);
    w4.DRAW_COLORS.* = 0x0002;
    w4.Text("PRESS X", 40, 84);
}

fn render() void {
    clearBackground();
    drawBoard();
    drawFrame();
    drawCursor();
    drawPanel();
}

// ---------------------------------------------------------------------
// WASM-4 entry points
// ---------------------------------------------------------------------

export fn start() void {
    setupPalette();
    resetGame();
}

export fn update() void {
    frame_count += 1;
    const gp = w4.GAMEPAD1.*;
    const was_game_over = game_over;

    if (!started) {
        _ = rngNext();
        clearBackground();
        drawTitle();
        if (justPressed(gp, w4.BUTTON_1)) started = true;
        prev_gamepad = gp;
        return;
    }

    if (!game_over) {
        updateCursorMovement(gp);
        if (justPressed(gp, w4.BUTTON_1)) trySwap();
        simulate();
        if (!boardBusy()) chain = 0;
        updateRise();
        if (game_over and !was_game_over) playGameOverSound();
    } else {
        if (justPressed(gp, w4.BUTTON_1)) resetGame();
    }

    render();
    if (game_over) drawGameOver();

    prev_gamepad = gp;
}
