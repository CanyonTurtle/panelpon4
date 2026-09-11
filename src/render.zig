// Palette/board/cursor/frame/panel and the render() dispatcher -- not unit
// tested (WASM4 host calls only); split across render_cells/render_screens/render_cpu.zig for the 500-line guideline.

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
const render_marathon = @import("render_marathon.zig");

pub const drawTitleScreen = screens.drawTitleScreen;
pub const drawModeSelectScreen = screens.drawModeSelectScreen;
pub const drawVersusConfirmScreen = screens.drawVersusConfirmScreen;
pub const drawSetupCharacterScreen = screens.drawSetupCharacterScreen;
pub const drawSetupCpuRevealScreen = screens.drawSetupCpuRevealScreen;
pub const drawSetupDifficultyScreen = screens.drawSetupDifficultyScreen;
pub const drawStoryTierScreen = screens.drawStoryTierScreen;
pub const drawStoryCharacterSelect = screens.drawStoryCharacterSelect;
pub const drawStoryWalkTransition = screens.drawStoryWalkTransition;
pub const drawGameOver = screens_game.drawGameOver;
pub const drawMarathonGameOver = screens_game.drawMarathonGameOver;
pub const drawCountdown = screens_game.drawCountdown;
pub const drawTutorialCaption = screens_game.drawTutorialCaption;

pub const FRAME_THICKNESS: i32 = 2;
const FRAME_RADIUS: i32 = 2;

fn applyPalette(p: characters.TriadicPalette) void {
    w4.PALETTE[0] = p.bg;
    w4.PALETTE[1] = p.a;
    w4.PALETTE[2] = p.b;
    w4.PALETTE[3] = p.c;
}

// Cycles the wheel while no character is locked in yet, then locks to the
// chosen character's own hue -- reskins the whole console palette per pick.
fn currentPaletteHue() f32 {
    const animating = !s.started and switch (s.menu_phase) {
        .title, .mode_select, .versus_confirm => true,
        else => false,
    };
    if (animating) return @mod(@as(f32, @floatFromInt(s.frame_count)) * 0.25, 360.0);
    return characters.ALL[s.player_character].base_hue;
}

// Called once per frame (see main.zig) -- cheap enough (4 palette writes)
// that recomputing unconditionally beats tracking exactly when it changed.
pub fn updatePalette() void {
    applyPalette(characters.triadicPalette(currentPaletteHue()));
}

// A brief flash-and-dissolve punch on every menu_phase change: solid, then
// a coarsening dithered checkerboard, drawn last to overlay the new screen.
pub fn drawMenuTransitionFlash() void {
    const t = s.menu_transition_flash;
    if (t == 0) return;
    w4.DRAW_COLORS.* = 0x0004;
    if (t >= 3) {
        w4.Rect(0, 0, w4.SCREEN_SIZE, w4.SCREEN_SIZE);
        return;
    }
    const step: i32 = if (t == 2) 4 else 8;
    const screen: i32 = @intCast(w4.SCREEN_SIZE);
    var y: i32 = 0;
    while (y < screen) : (y += 2) {
        var x: i32 = 0;
        while (x < screen) : (x += 2) {
            if (@mod(x + y, step) == 0) w4.Rect(x, y, 2, 2);
        }
    }
}

pub fn clearBackground() void {
    w4.DRAW_COLORS.* = cells.DC_BG;
    w4.Rect(0, 0, w4.SCREEN_SIZE, w4.SCREEN_SIZE);
}

// Must be computed, not SCREEN_SIZE -- board height can now differ from the
// screen. Used to skip/mask rows only partially below it (rect() can't clip mid-tile).
const BOARD_BOTTOM: i32 = c.BOARD_Y + @as(i32, c.VISIBLE_ROWS) * c.TILE;

// Rows the closing "match over" wipe has already popped (see state.closing_timer) --
// 0 while winner==.none, so this is a no-op, purely-rendering skip during ordinary gameplay.
pub fn closingWipedRows() u8 {
    if (s.winner == .none) return 0;
    const elapsed = c.CLOSING_TOTAL_FRAMES - s.closing_timer;
    if (elapsed <= 0) return 0;
    const rows = @divTrunc(elapsed, c.CLOSING_FRAMES_PER_ROW);
    return @intCast(@min(rows, c.RING_SIZE));
}

// Pixels a settled block squashes while danger_timer is running -- a
// constant squash, not another bounce, for an unmistakably different at-a-glance look.
const PANIC_SQUISH_AMOUNT: i32 = 2;

// Full-detail board rendering -- always `s.player`, at the normal board
// position/scale. See render_cpu.zig for the CPU's simplified equivalent.
fn drawBoard(b: *s.Board) void {
    var col_stressed: [c.COLS]bool = undefined;
    for (0..c.COLS) |ci| col_stressed[ci] = cells.isColumnStressed(b, @intCast(ci));
    const bounce = cells.stressBounceOffset();
    const wiped = closingWipedRows();
    // The lose timer overrides the milder per-column stress bounce: once running,
    // every settled block switches from symbol-wobble to panic-squish (see PANIC_SQUISH_AMOUNT).
    const panicking = b.danger_timer > 0;

    // Starts at SPAWN_ROWS, not 0 -- earlier rows are the offscreen garbage
    // staging area (see constants.SPAWN_ROWS/Board.physRow), never meant to be drawn.
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
                    // Only a block's symbol bounces (sym_bounce); the block itself stays put at
                    // base_y. While panicking, bounce is replaced entirely by squash -- never both nonzero.
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
            // The hidden ring-buffer row (see sim_matches.HIDDEN_ROW) gets a sparse dither
            // overlay marking it as still "arriving", clearing once a rise promotes it.
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

    // One mark per settled garbage piece, at its own pixel-space centroid, drawn as a
    // separate pass so adjacent pieces (rendered as one seamless slab) still read as distinct.
    const centers = rgarbage.pieceCenters(b, wiped);
    for (centers.items[0..centers.count]) |pc| rgarbage.drawMark(pc.x, pc.y);
}

// Covers whatever drawBoard drew below BOARD_BOTTOM -- a mid-scroll row still
// draws its whole tile height (rect() can't clip mid-tile), so this masks the overhang.
fn maskBelowBoard() void {
    const screen: i32 = @intCast(w4.SCREEN_SIZE);
    if (BOARD_BOTTOM >= screen) return; // nothing below the board to mask
    w4.DRAW_COLORS.* = cells.DC_BG;
    w4.Rect(0, BOARD_BOTTOM, @intCast(c.PANEL_X), @intCast(screen - BOARD_BOTTOM));
}

// Fills one edge band per the character's own border style (see characters.BorderStyle);
// also reused by render_screens.drawThemedPanelBorder to retheme the setup screens.
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

// Frame with a chamfered corner at each corner -- WASM-4's rect() has no
// rounded-corner support, so corners are faked by punching a notch in the background color.
fn drawFrame(character: u8) void {
    // Pushed out from the board's bounding box to avoid overlapping edge-tile fill;
    // left gets +1 extra since blocks are flush to their tile's top-left corner (no natural gap there).
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

// Distance each bracket sits beyond the block's own edge; CURSOR_OUT_BASE is the
// resting/contracted size a fresh move snaps to, breathing out to +CURSOR_OUT_PULSE while idle.
const CURSOR_OUT_BASE: i32 = 1;
const CURSOR_OUT_PULSE: i32 = 1;
const CURSOR_CORNER_LEN: i32 = 3;
// A discrete 2-frame toggle, not a smooth slide -- a gradual per-pixel slide would
// instead read as the dithered checkerboard's two hues swapping, not an actual size change.
const CURSOR_BREATHE_HOLD_FRAMES: u32 = 15;
const CURSOR_DITHER_HUES = badge.WARM_DITHER_HUES;

// 4 corner brackets (photo-tab look), not one traced box -- the classic Panel de Pon
// cursor. `out` is how far each bracket sits beyond the block's edge, centering it.
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

// Draws a cursor only for whichever board is in the main seat (see mainBoard) --
// the mini seat never gets one, and it's hidden entirely while touch input is active.
fn drawCursor(board: *s.Board, idle_frames: u32) void {
    if (s.winner != .none or touch_state.cursor_hidden) return;
    const row = board.cursor_row;
    const col = board.cursor_col;
    const base_x = c.BOARD_X + @as(i32, col) * c.TILE;
    const base_y = c.BOARD_Y + @as(i32, row) * c.TILE - @as(i32, @intCast(board.scroll_px));

    // Driven by idle_frames, not frame_count, so idle_frames==0 always snaps to the
    // contracted frame the instant it moves -- a fast player never sees it breathe.
    const expanded = @mod(@divTrunc(idle_frames, CURSOR_BREATHE_HOLD_FRAMES), 2) == 1;
    const out = if (expanded) CURSOR_OUT_BASE + CURSOR_OUT_PULSE else CURSOR_OUT_BASE;

    // Each slot's corners ride along with whatever block is actually there, so a live
    // swap visibly carries the cursor with the two blocks instead of sitting still.
    const abs_row = row + c.SPAWN_ROWS;
    const left = board.cellAt(abs_row, col);
    const right = board.cellAt(abs_row, col + 1);
    const left_offset: i32 = if (left.state == .swapping) @as(i32, left.swap_dir) * @divTrunc(c.TILE * @as(i32, left.timer), c.SWAP_FRAMES) else 0;
    const right_offset: i32 = if (right.state == .swapping) @as(i32, right.swap_dir) * @divTrunc(c.TILE * @as(i32, right.timer), c.SWAP_FRAMES) else 0;

    drawCursorCorners(base_x + left_offset, base_y, out, CURSOR_DITHER_HUES);
    drawCursorCorners(base_x + c.TILE + right_offset, base_y, out, CURSOR_DITHER_HUES);
}

// Portrait shifted down by FRAME_MARGIN so its themed frame has room above it;
// CHAR_TEXT_X is shared with badge.drawMatchPopups so the popup badge lands on the score.
const CHAR_PORTRAIT_Y: i32 = rchar.FRAME_MARGIN;
const CHAR_TEXT_X: i32 = c.PANEL_X + rchar.W + rchar.FRAME_MARGIN + 2;

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
    } else if (s.game_mode != .tutorial) {
        // No series/stage score is meaningful during the tutorial.
        badge.drawPoints(CHAR_TEXT_X, 10, points);
    }
}

// Max travel distance and start size (both shrink/grow linearly over elapsed/total,
// see state_fx.Particle) -- same style as every other timed animation here.
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

// Which Board shows in the main seat -- ordinarily `player`, but a versus peer whose
// own input is GAMEPAD2 sees `cpu` instead, so every peer sees themselves in the main seat.
fn mainBoard() *s.Board {
    return if (s.versus_render_swapped) &s.cpu else &s.player;
}
fn miniBoard() *s.Board {
    return if (s.versus_render_swapped) &s.player else &s.cpu;
}
// pub: render_screens.drawGameOverPortraits also needs this same main-seat
// character mapping.
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
    if (s.game_mode == .marathon) {
        // No opponent/panel column -- marathon's own HUD fills the recentered
        // board's freed side margins instead (render_marathon.zig).
        render_marathon.drawHud(main_board, main_char);
        drawParticles(&main_board.particles);
        return;
    }
    drawPanel(main_board, main_char, mainPoints());
    // Only drawn when main_board is really `&s.player`: its popups were spawned in this
    // full-scale coordinate system; a swapped `&s.cpu` board's popups use the micro-board system instead.
    if (main_board == &s.player) badge.drawMatchPopups(&main_board.match_popups, CHAR_TEXT_X, 10);
    drawParticles(&main_board.particles);
    // In the gutter between the main board's own frame and the panel column.
    badge.drawGarbageQueueIcons(96, c.BOARD_Y + 4, main_board);
    render_cpu.draw(miniBoard(), miniCharacter(), miniPoints());
}
