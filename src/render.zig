// Palette setup, the in-game board/cursor/frame/panel, and the render()
// dispatcher. Not unit tested -- everything here bottoms out in WASM4's
// extern draw calls, which only make sense under an actual WASM4 host.
//
// The player's board renders in full detail (bevel, symbols, dither,
// linked-garbage bezel) at its normal size via drawBoard/drawCursor, always
// on `s.player`. The CPU's board shares the exact same simulation but is
// drawn at a simplified micro scale by the companion render_cpu.zig. The
// single-cell drawing primitives (color fills, dithering, per-CellState cell
// drawers) live in render_cells.zig; the pre-game menu/setup screens live in
// render_screens.zig; and the match-over overlays plus the countdown live in
// the companion render_screens_game.zig -- all split out, along with
// render_cpu.zig, to keep this file under the project's ~500-line-per-file
// guideline. This file re-exports both screens files' public screen-drawing
// functions below so main.zig's `render.drawXScreen()` call sites are
// unaffected by that split.

const std = @import("std");
const c = @import("constants.zig");
const s = @import("state.zig");
const fx = @import("state_fx.zig");
const touch_state = @import("state_touch.zig");
const w4 = @import("wasm4.zig");
const badge = @import("render_badge.zig");
const render_cpu = @import("render_cpu.zig");
const rgarbage = @import("render_garbage.zig");
const characters = @import("characters.zig");
const rchar = @import("render_character.zig");
const game_modes = @import("game_modes.zig");
const cells = @import("render_cells.zig");
const screens = @import("render_screens.zig");
const screens_game = @import("render_screens_game.zig");

pub const drawTitleScreen = screens.drawTitleScreen;
pub const drawModeSelectScreen = screens.drawModeSelectScreen;
pub const drawVersusConfirmScreen = screens.drawVersusConfirmScreen;
pub const drawSetupCharacterScreen = screens.drawSetupCharacterScreen;
pub const drawSetupCpuRevealScreen = screens.drawSetupCpuRevealScreen;
pub const drawSetupDifficultyScreen = screens.drawSetupDifficultyScreen;
pub const drawStoryTierScreen = screens.drawStoryTierScreen;
pub const drawGameOver = screens_game.drawGameOver;
pub const drawCountdown = screens_game.drawCountdown;

// Blocks have no border color of their own anymore: just a 1px background
// corner-bevel and a 1px background gap between tiles (see
// render_cells.BLOCK_SIZE), plus a symbol drawn in the background color so
// shapes stay distinguishable even without color.
pub const FRAME_THICKNESS: i32 = 2;
const FRAME_RADIUS: i32 = 2;

pub fn setupPalette() void {
    w4.PALETTE[0] = 0x1a1c2c; // background
    w4.PALETTE[1] = 0xf97690; // hue A: red
    w4.PALETTE[2] = 0x36e4e7; // hue B: teal (dithers with A -> purple, with C -> green)
    w4.PALETTE[3] = 0xfbef6a; // hue C: yellow
}

pub fn clearBackground() void {
    w4.DRAW_COLORS.* = cells.DC_BG;
    w4.Rect(0, 0, w4.SCREEN_SIZE, w4.SCREEN_SIZE);
}

// The board's own visible area ends here vertically -- VISIBLE_ROWS*TILE no
// longer happens to equal SCREEN_SIZE now that the board isn't always
// exactly as tall as the screen, so this can't just be WASM4's SCREEN_SIZE
// anymore. Used both to skip rows that are entirely below it (drawBoard)
// and to mask over the bit of any row that's only *partially* below it
// (maskBelowBoard) -- WASM4's rect() has no clip-region support, so a row
// that's mid-scroll and still partly in bounds draws its *entire* tile
// height regardless of where board_bottom falls across it.
const BOARD_BOTTOM: i32 = c.BOARD_Y + @as(i32, c.VISIBLE_ROWS) * c.TILE;

// How many rows (from the ceiling down) the closing "match over" wipe has
// already popped -- see state.closing_timer/board.beginClosing, ticked down
// once per frame in main.zig once `winner` leaves .none. `.none` outside
// that window keeps this permanently 0, so drawBoard/drawMicroBoard's own
// wipe check below is a no-op during ordinary gameplay. Purely a rendering
// skip -- nothing here ever touches either Board's actual grid, so there's
// no risk of this interfering with (or surviving past) the match itself.
pub fn closingWipedRows() u8 {
    if (s.winner == .none) return 0;
    const elapsed = c.CLOSING_TOTAL_FRAMES - s.closing_timer;
    if (elapsed <= 0) return 0;
    const rows = @divTrunc(elapsed, c.CLOSING_FRAMES_PER_ROW);
    return @intCast(@min(rows, c.RING_SIZE));
}

// How many pixels shorter a settled real block renders while the board's
// own lose timer (Board.danger_timer) is actually running -- see
// drawBoard's `panicking` check. A constant squash rather than another
// animated bounce: the point is a plain, unmistakably different look from
// the ordinary ambient stress bounce, read at a glance rather than timed
// against.
const PANIC_SQUISH_AMOUNT: i32 = 2;

// Full-detail board rendering -- always `s.player`, at the normal board
// position/scale. See render_cpu.zig for the CPU's simplified equivalent.
fn drawBoard(b: *s.Board) void {
    var col_stressed: [c.COLS]bool = undefined;
    for (0..c.COLS) |ci| col_stressed[ci] = cells.isColumnStressed(b, @intCast(ci));
    const bounce = cells.stressBounceOffset();
    const wiped = closingWipedRows();
    // The lose timer (see board.updateDangerTimer) is a strictly more
    // urgent warning than the ordinary per-column stress bounce above --
    // once it's actually running, every settled real block switches from
    // wobbling its symbol to rendering panic-squished instead (see
    // PANIC_SQUISH_AMOUNT), a clearer "the clock is now really running"
    // affordance than the milder ambient bounce.
    const panicking = b.danger_timer > 0;

    // Starts at SPAWN_ROWS, not 0 -- rows before that are the offscreen
    // garbage staging area (see constants.SPAWN_ROWS/Board.physRow), never
    // meant to be drawn at all.
    var lr: u8 = c.SPAWN_ROWS;
    while (lr < c.ROWS) : (lr += 1) {
        if (lr - c.SPAWN_ROWS < wiped) continue; // already "popped" by the closing wipe
        const base_y = c.BOARD_Y + @as(i32, lr - c.SPAWN_ROWS) * c.TILE - @as(i32, @intCast(b.scroll_px));
        if (base_y + c.TILE <= c.BOARD_Y or base_y >= BOARD_BOTTOM) continue;
        var col: u8 = 0;
        while (col < c.COLS) : (col += 1) {
            const cell = b.cellAt(lr, col);
            const x = c.BOARD_X + @as(i32, col) * c.TILE;
            switch (cell.state) {
                .normal => {
                    // Only a settled real block's *symbol* bounces (see
                    // drawNormalCell's sym_bounce) -- the block itself, and
                    // garbage (which has no symbol), stay put at base_y, so
                    // nothing keyed to a block's actual position (like the
                    // hidden row's dither overlay below) ever falls out of
                    // sync with it. While panicking, the bounce is replaced
                    // entirely by a squash (see drawNormalCell's squash) --
                    // the two are mutually exclusive, never both nonzero.
                    if (cell.is_garbage) {
                        rgarbage.drawLinked(x, base_y, rgarbage.edgesAt(b, lr, col));
                    } else if (panicking) {
                        cells.drawNormalCell(x, base_y, cell.color, 0, PANIC_SQUISH_AMOUNT);
                    } else {
                        const sym_bounce = if (col_stressed[col]) bounce else 0;
                        cells.drawNormalCell(x, base_y, cell.color, sym_bounce, 0);
                    }
                },
                .falling => {
                    const y = base_y - cell.fall_off;
                    if (cell.is_garbage) rgarbage.drawLinked(x, y, rgarbage.edgesAt(b, lr, col)) else cells.drawNormalCell(x, y, cell.color, 0, 0);
                },
                .popping => cells.drawPoppingCell(x, base_y, cell.color, cell.timer, cell.pre_pop_timer),
                .recycling => cells.drawRecyclingCell(x, base_y, cell.color, cell.timer, rgarbage.edgesAt(b, lr, col), cell.pre_pop_timer, cell.garbage_reveals),
                .landing => cells.drawLandingCell(x, base_y, cell.color, cell.timer, cell.is_garbage, rgarbage.edgesAt(b, lr, col)),
                .swapping => cells.drawSwappingCell(x, base_y, cell.color, cell.timer, cell.swap_dir),
                .empty => {},
            }
            // The one hidden ring-buffer row (see sim_matches.HIDDEN_ROW):
            // not yet promoted into the lowest accessible row, so a sparse
            // dither overlay marks the whole row as still "arriving" --
            // clearing the instant a rise actually promotes it (at which
            // point this same content renders one `lr` lower and no longer
            // matches this check at all).
            if (lr == c.ROWS - 1) {
                var dy: i32 = 0;
                while (dy < c.TILE) : (dy += 1) {
                    var dx: i32 = 0;
                    while (dx < c.TILE) : (dx += 1) {
                        if (@mod(dx + dy, 2) != 0) continue;
                        w4.DRAW_COLORS.* = cells.DC_BG;
                        w4.Rect(x + dx, base_y + dy, 1, 1);
                    }
                }
            }
        }
    }

    // One mark per settled garbage piece, at its own true pixel-space
    // centroid (see garbage_pieces.pieceCenters) -- drawn as its own pass,
    // on top of everything above, since a centroid can straddle several
    // cells rather than belonging to any single one of them. Lets two
    // different pieces resting against each other, rendered as one seamless
    // slab with no visible seam (see rgarbage.drawLinked), still read as
    // visually distinct blocks instead of one bigger one. Passed the same
    // `wiped` count as the main loop above, so a piece's mark shrinks in
    // sync with the closing wipe and disappears entirely once the match is
    // over, rather than lingering over a board the wipe has already cleared.
    const centers = rgarbage.pieceCenters(b, wiped);
    for (centers.items[0..centers.count]) |pc| rgarbage.drawMark(pc.x, pc.y);
}

// Covers over whatever drawBoard just drew below BOARD_BOTTOM -- a row
// mid-scroll can be only partly in bounds, but still draws its whole tile
// height regardless (see BOARD_BOTTOM's comment), so without this the
// incoming row would visibly poke out past the frame's bottom edge instead
// of staying hidden until it's actually risen into view. A plain
// background-colored fill is enough since it's the exact same color the
// rest of the screen outside the board already is.
fn maskBelowBoard() void {
    const screen: i32 = @intCast(w4.SCREEN_SIZE);
    if (BOARD_BOTTOM >= screen) return; // nothing below the board to mask
    w4.DRAW_COLORS.* = cells.DC_BG;
    w4.Rect(0, BOARD_BOTTOM, @intCast(c.PANEL_X), @intCast(screen - BOARD_BOTTOM));
}

// Fills one edge band of the frame (a w x h strip, `horizontal` true for
// the top/bottom bands where the pattern repeats along x, false for
// left/right where it repeats along y) according to the current player's
// chosen character's own border style (see characters.BorderStyle) --
// "their own style of menu border for the main frame". A two-hue character
// dithers between its pair everywhere the style would otherwise show a
// single solid hue. Also used by render_screens.drawThemedPanelBorder to
// retheme the setup screens the same way.
pub fn drawThemedBand(x: i32, y: i32, w: i32, h: i32, hues: [2]u8, style: characters.BorderStyle, horizontal: bool) void {
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
            w4.DRAW_COLORS.* = cells.HUE_DRAWCOLOR[hues[hue_idx]];
            const px = if (horizontal) x + i else x + j;
            const py = if (horizontal) y + j else y + i;
            w4.Rect(px, py, 1, 1);
        }
    }
}

// Frame around the playable area with a 2px-radius chamfer at each corner
// (WASM-4's rect() has no rounded-corner support, so the corners are faked
// by punching a small diagonal notch out of the frame in the background
// color).
fn drawFrame(character: u8) void {
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
    const x = c.BOARD_X - push_left;
    const y = c.BOARD_Y - push_y;
    const w = @as(i32, c.COLS) * c.TILE + push_left + push_right;
    const h = @as(i32, c.VISIBLE_ROWS) * c.TILE + 2 * push_y;
    const t = FRAME_THICKNESS;
    const radius = FRAME_RADIUS;

    const char = characters.ALL[character];
    drawThemedBand(x, y, w, t, char.hues, char.border_style, true); // top
    drawThemedBand(x, y + h - t, w, t, char.hues, char.border_style, true); // bottom
    drawThemedBand(x, y, t, h, char.hues, char.border_style, false); // left
    drawThemedBand(x + w - t, y, t, h, char.hues, char.border_style, false); // right

    w4.DRAW_COLORS.* = cells.DC_BG;
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

// How far each bracket sits beyond the block's own edge (not the tile's --
// the block is flush with the tile's top-left corner, see
// render_cells.BLOCK_SIZE, so a bracket centered on the block is offset the
// same amount on every side regardless). CURSOR_OUT_BASE is the resting/
// contracted distance -- the default look, and what a fresh move snaps back
// to; while idling, it breathes out to CURSOR_OUT_BASE + CURSOR_OUT_PULSE
// and back (see drawCursor) rather than sitting at a fixed size the whole
// time.
const CURSOR_OUT_BASE: i32 = 1;
const CURSOR_OUT_PULSE: i32 = 1;
const CURSOR_CORNER_LEN: i32 = 3;
// A discrete 2-frame animation (contracted/expanded), not a smooth
// interpolation -- the same idiom as every other animation in the game
// (see render_character.currentFrame), holding each state for this many
// engine frames before toggling to the other. A gradual per-pixel slide
// instead reads as the dithered checkerboard's two hues swapping in place
// (since which hue lands on a given pixel depends on its absolute
// position -- see render_cells.plotDithered) rather than an actual size
// change.
const CURSOR_BREATHE_HOLD_FRAMES: u32 = 15;
const CURSOR_DITHER_HUES = badge.WARM_DITHER_HUES;

// One tile's own 4 corner brackets -- like a photo mounted by its own four
// corner tabs, not a single box traced around it (the classic Panel de Pon
// cursor look). `x`/`y` is the block's own top-left corner (== the tile's,
// since the block is flush with it); `out` is how far the bracket sits
// beyond the block's edge on every side, so it's centered on the block.
fn drawCursorCorners(x: i32, y: i32, out: i32, hues: [2]u8) void {
    const x0 = x - out;
    const y0 = y - out;
    const x1 = x + cells.BLOCK_SIZE - 1 + out;
    const y1 = y + cells.BLOCK_SIZE - 1 + out;
    var i: i32 = 0;
    while (i < CURSOR_CORNER_LEN) : (i += 1) {
        cells.plotDithered(x0 + i, y0, hues); // top-left
        cells.plotDithered(x0, y0 + i, hues);
        cells.plotDithered(x1 - i, y0, hues); // top-right
        cells.plotDithered(x1, y0 + i, hues);
        cells.plotDithered(x0 + i, y1, hues); // bottom-left
        cells.plotDithered(x0, y1 - i, hues);
        cells.plotDithered(x1 - i, y1, hues); // bottom-right
        cells.plotDithered(x1, y1 - i, hues);
    }
}

// Always whichever board is rendered in the main, full-detail seat (see
// render()'s own main_board/mainIdleFrames -- ordinarily `player`, but in
// versus mode (see state.versus_render_swapped) a peer whose own real input
// is GAMEPAD2 sees `cpu` there instead, since every peer wants to see
// *themselves* in the main seat regardless of which struct their own real
// presses happen to land in). Whichever board is rendered in the *mini*
// seat never gets a cursor of its own to show -- true for the actual CPU
// (no real input to reflect) and, as a deliberate scope cut, also true for
// versus mode's other real player (their own screen shows their own cursor
// just fine on their own copy of the cart; this peer's own view of them
// stays exactly as simple as the existing CPU mini-view always was). Hidden
// while touch is the active input method (see state.cursor_hidden) --
// swipes move it relative to wherever it already is rather than aiming at a
// touched tile, so there's nothing the player needs to see it for.
fn drawCursor(board: *s.Board, idle_frames: u32) void {
    if (s.winner != .none or touch_state.cursor_hidden) return;
    const row = board.cursor_row;
    const col = board.cursor_col;
    const base_x = c.BOARD_X + @as(i32, col) * c.TILE;
    const base_y = c.BOARD_Y + @as(i32, row) * c.TILE - @as(i32, @intCast(board.scroll_px));

    // Breathe by alternating between two discrete sizes (contracted at
    // CURSOR_OUT_BASE, expanded at CURSOR_OUT_BASE + CURSOR_OUT_PULSE) --
    // driven by idle_frames (time since the cursor last actually moved), not
    // raw frame_count, so idle_frames == 0 always lands on the contracted
    // frame: the cursor snaps to it the instant it moves, and only starts
    // alternating again once it's been sitting there for a whole
    // CURSOR_BREATHE_HOLD_FRAMES -- a fast-playing player never sees it
    // breathe at all.
    const expanded = @mod(@divTrunc(idle_frames, CURSOR_BREATHE_HOLD_FRAMES), 2) == 1;
    const out = if (expanded) CURSOR_OUT_BASE + CURSOR_OUT_PULSE else CURSOR_OUT_BASE;

    // Rather than staying pinned to the two static grid tiles, each slot's
    // corners ride along with whatever block is actually there right now --
    // so a live swap (see CellState.swapping/drawSwappingCell's identical
    // offset formula) visibly carries the cursor along with the two blocks
    // as they trade places, instead of the cursor sitting still while the
    // blocks slide underneath it.
    const abs_row = row + c.SPAWN_ROWS;
    const left = board.cellAt(abs_row, col);
    const right = board.cellAt(abs_row, col + 1);
    const left_offset: i32 = if (left.state == .swapping) @as(i32, left.swap_dir) * @divTrunc(c.TILE * @as(i32, left.timer), c.SWAP_FRAMES) else 0;
    const right_offset: i32 = if (right.state == .swapping) @as(i32, right.swap_dir) * @divTrunc(c.TILE * @as(i32, right.timer), c.SWAP_FRAMES) else 0;

    drawCursorCorners(base_x + left_offset, base_y, out, CURSOR_DITHER_HUES);
    drawCursorCorners(base_x + c.TILE + right_offset, base_y, out, CURSOR_DITHER_HUES);
}

// Where the player's own portrait sits -- shifted down from the screen's
// very top edge by rchar.FRAME_MARGIN so its themed frame (rchar.drawFrame)
// has room above it, rather than being pushed off-screen. CHAR_TEXT_X is
// shared with render()'s own badge.drawMatchPopups call below, so the flying
// match-popup badge and the score digits it lands on agree on where the
// score actually is.
const CHAR_PORTRAIT_Y: i32 = rchar.FRAME_MARGIN;
const CHAR_TEXT_X: i32 = c.PANEL_X + rchar.W + rchar.FRAME_MARGIN + 2;

// The main (full-detail) side's own character portrait, framed in their
// chosen character's own theme (see rchar.drawFrame) and animated per
// render_character.zig, plus score/points squeezed in beside it. The old
// static yellow "COMBO"/"xN" chain callout that used to sit below the
// portrait is gone -- the flying match-popup badge (badge.drawMatchPopups,
// now landing right here for both sides) already communicates the same
// thing, and the character's own combo/win bounce (see rchar.bounceOffset)
// reinforces it further, so keeping a second static text readout around
// just ate space for no benefit. Story mode shows its own stage counter
// where the best-of-N series pips normally go, since a story stage is a
// single game, not a series (see main.zig).
fn drawPanel(board: *s.Board, character: u8, points: u8) void {
    rchar.drawFrame(c.PANEL_X, CHAR_PORTRAIT_Y, character);
    rchar.draw(c.PANEL_X, CHAR_PORTRAIT_Y, character, rchar.stateFor(board), rchar.currentFrame());

    w4.DRAW_COLORS.* = 0x0002;
    var buf: [12]u8 = undefined;
    const score_str = std.fmt.bufPrint(&buf, "{d}", .{board.score}) catch "0";
    w4.Text(score_str, CHAR_TEXT_X, 2);
    if (s.game_mode == .story) {
        var buf2: [12]u8 = undefined;
        const stage_str = std.fmt.bufPrint(&buf2, "{d}/{d}", .{ s.story_stage + 1, game_modes.STORY_STAGES }) catch "";
        w4.Text(stage_str, CHAR_TEXT_X, 10);
    } else {
        badge.drawPoints(CHAR_TEXT_X, 10, points);
    }
}

// How far a particle travels from its spawn point by the end of its life,
// and how big it starts out (shrinking to nothing by the same point) -- see
// state_fx.Particle/state_fx.spawnPopParticles. Linear growth/shrink, same
// integer-elapsed-over-total style as every other timed animation here
// (e.g. render_cells.drawSwappingCell's slide) rather than anything
// fancier.
const PARTICLE_MAX_DIST: i32 = 10;
const PARTICLE_START_SIZE: i32 = 3;

fn drawParticles(particles: []const fx.Particle) void {
    for (particles) |p| {
        if (!p.active) continue;
        const dist = @divTrunc(PARTICLE_MAX_DIST * @as(i32, p.elapsed), fx.PARTICLE_LIFE);
        const size = PARTICLE_START_SIZE - @divTrunc(PARTICLE_START_SIZE * @as(i32, p.elapsed), fx.PARTICLE_LIFE);
        if (size <= 0) continue;
        const x = p.x + @as(i32, p.dir_x) * dist - @divTrunc(size, 2);
        const y = p.y + @as(i32, p.dir_y) * dist - @divTrunc(size, 2);
        const hue = if (p.color < 3) p.color else cells.DITHER_HUES[p.color - 3][0];
        w4.DRAW_COLORS.* = cells.HUE_DRAWCOLOR[hue];
        w4.Oval(x, y, @intCast(size), @intCast(size));
    }
}

// Which Board/character/points/idle-frames this peer's own "main", full-
// detail seat actually shows -- ordinarily always `player`'s own (every mode
// but versus, and even versus itself for the netplay host/GAMEPAD1 side, or
// local same-console play), but a versus peer whose own real input is
// GAMEPAD2 (see state.versus_render_swapped, decided once in main.zig right
// as a versus match's countdown begins) sees `cpu` there instead -- every
// peer wants to see *themselves* in the main seat, not always whichever
// struct GAMEPAD1's input happens to land in (see input routing in
// main.zig's own update(), which stays fixed regardless: this swap is a
// rendering-only decision, so the simulation's own call order never changes
// between peers).
fn mainBoard() *s.Board {
    return if (s.versus_render_swapped) &s.cpu else &s.player;
}
fn miniBoard() *s.Board {
    return if (s.versus_render_swapped) &s.player else &s.cpu;
}
// pub: render_screens.drawGameOverPortraits also needs to know which
// character is on which side, from this same rendering-main-seat
// perspective.
pub fn mainCharacter() u8 {
    return if (s.versus_render_swapped) s.cpu_character else s.player_character;
}
pub fn miniCharacter() u8 {
    return if (s.versus_render_swapped) s.player_character else s.cpu_character;
}
fn mainPoints() u8 {
    return if (s.versus_render_swapped) s.cpu_points else s.player_points;
}
fn miniPoints() u8 {
    return if (s.versus_render_swapped) s.player_points else s.cpu_points;
}
fn mainIdleFrames() u32 {
    return if (s.versus_render_swapped) s.cpu_cursor_idle_frames else s.cursor_idle_frames;
}

pub fn render() void {
    const main_board = mainBoard();
    const main_char = mainCharacter();
    clearBackground();
    drawBoard(main_board);
    maskBelowBoard();
    drawFrame(main_char);
    drawCursor(main_board, mainIdleFrames());
    drawPanel(main_board, main_char, mainPoints());
    // Only drawn when the main board really is `&s.player`: its own popups
    // are always spawned in this full-scale coordinate system by
    // sim_matches.checkMatches (checked there by that same pointer
    // identity). A versus peer whose own real input is GAMEPAD2 sees `&s.
    // cpu` rendered here instead (see mainBoard/state.versus_render_swapped)
    // -- that board's own popups were spawned in the *other* (micro-board)
    // coordinate system instead, which would land them somewhere nonsensical
    // at full scale, so this just silently skips the flourish there rather
    // than drawing it in the wrong place (see render_cpu.draw's identical
    // guard on the mini side).
    if (main_board == &s.player) badge.drawMatchPopups(&main_board.match_popups, CHAR_TEXT_X, 10);
    drawParticles(&main_board.particles);
    // In the gutter between the main board's own frame and the panel column.
    badge.drawGarbageQueueIcons(96, c.BOARD_Y + 4, main_board);
    render_cpu.draw(miniBoard(), miniCharacter(), miniPoints());
}
