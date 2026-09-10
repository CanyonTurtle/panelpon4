// The pre-game/menu screens (title, mode select, versus confirm, the 3-step
// setup flow, story's own difficulty screen) and the match-over overlays
// (drawGameOver/drawStoryGameOver, plus the shared drawPanelBorder/
// drawCountdown overlay chrome). Split out of render.zig to keep that file
// under the project's ~500-line-per-file guideline -- render.zig re-exports
// every `pub fn` here (`render.drawTitleScreen`, etc.) so main.zig's call
// sites are unaffected by the split, and this file imports render.zig back
// for drawThemedBand (shared with render.drawFrame) and render_cells.zig for
// drawDitheredRectOutline.

const std = @import("std");
const c = @import("constants.zig");
const s = @import("state.zig");
const w4 = @import("wasm4.zig");
const badge = @import("render_badge.zig");
const bg = @import("render_bg.zig");
const characters = @import("characters.zig");
const rchar = @import("render_character.zig");
const game_modes = @import("game_modes.zig");
const cells = @import("render_cells.zig");
const render = @import("render.zig");

const MENU_PANEL_X: i32 = 20;
const MENU_PANEL_W: i32 = 120;

// Common backdrop for every pre-game screen: the parallaxing background
// (see render_bg.zig) plus the panel's own fill, held perfectly still --
// callers draw their own border (the title screen's neutral bezel vs. the
// setup screens' character-themed one) and content into the returned Y.
// `base_y`/`h` differ per screen (some have more to fit than others), so
// both are the caller's own choice rather than shared constants.
fn drawMenuPanelFill(base_y: i32, h: i32) i32 {
    bg.draw();
    w4.DRAW_COLORS.* = 0x0001;
    w4.Rect(MENU_PANEL_X, base_y, MENU_PANEL_W, @intCast(h));
    return base_y;
}

// A plain (unchamfered) themed border around an arbitrary panel -- used by
// the setup screens to retheme themselves to whichever character is
// currently selected, the same color+pattern treatment render.drawFrame
// gives the real game board.
fn drawThemedPanelBorder(x: i32, y: i32, w: i32, h: i32, char: characters.Character) void {
    const t = render.FRAME_THICKNESS;
    render.drawThemedBand(x, y, w, t, char.hues, char.border_style, true);
    render.drawThemedBand(x, y + h - t, w, t, char.hues, char.border_style, true);
    render.drawThemedBand(x, y, t, h, char.hues, char.border_style, false);
    render.drawThemedBand(x + w - t, y, t, h, char.hues, char.border_style, false);
}

pub fn drawTitleScreen() void {
    const y = drawMenuPanelFill(30, 100);
    drawPanelBorder(MENU_PANEL_X, y, MENU_PANEL_W, 100);
    w4.DRAW_COLORS.* = 0x0003;
    w4.Text("PANELPON4", 40, y + 24);
    w4.DRAW_COLORS.* = 0x0002;
    w4.Text("PRESS X", 52, y + 64);
}

// Right after the title, before any character/difficulty picking -- neither
// of which applies yet, so this uses the same plain (non-themed) bezel the
// title screen does, not a character-themed one. `state.GameMode`'s own
// left/right cycling order (see main.zig's prevMode/nextMode) matches this
// list's own order top to bottom.
const GAME_MODE_LABELS = [3][]const u8{ "1P STORY", "1P QUICK MATCH", "2P VERSUS" };
fn gameModeIndex(m: s.GameMode) u8 {
    return switch (m) {
        .story => 0,
        .quick => 1,
        .versus => 2,
    };
}

pub fn drawModeSelectScreen() void {
    const y = drawMenuPanelFill(30, 100);
    drawPanelBorder(MENU_PANEL_X, y, MENU_PANEL_W, 100);
    w4.DRAW_COLORS.* = 0x0003;
    w4.Text("SELECT MODE", 34, y + 12);

    const cur = gameModeIndex(s.game_mode);
    for (GAME_MODE_LABELS, 0..) |label, i| {
        const line_y = y + 34 + @as(i32, @intCast(i)) * 14;
        w4.DRAW_COLORS.* = if (i == cur) 0x0004 else 0x0002;
        w4.Text(label, 30, line_y);
    }
    w4.DRAW_COLORS.* = 0x0002;
    w4.Text("<-      ->", 40, y + 80);
    w4.Text("PRESS X", 52, y + 92);
}

// A manual gate between picking versus mode and actually starting a
// countdown (see state.MenuPhase's own doc comment on why this exists) --
// makes sure the second player has actually joined via netplay (or is ready
// on a second local controller) before `main.zig` ever reads `wasm4.NETPLAY`
// or resets the boards, since joining mid-match would desync the two peers.
pub fn drawVersusConfirmScreen() void {
    const y = drawMenuPanelFill(30, 100);
    drawPanelBorder(MENU_PANEL_X, y, MENU_PANEL_W, 100);
    w4.DRAW_COLORS.* = 0x0003;
    w4.Text("2P VERSUS", 40, y + 10);
    w4.DRAW_COLORS.* = 0x0002;
    w4.Text("CONNECT VIA", 34, y + 34);
    w4.Text("NETPLAY NOW", 34, y + 46);
    w4.Text("(OR READY P2", 30, y + 62);
    w4.Text("ON GAMEPAD 2)", 26, y + 74);
    w4.DRAW_COLORS.* = 0x0004;
    w4.Text("THEN PRESS X", 28, y + 90);
}

// One filled-in segment per difficulty level (1-10), replacing the old
// plain "LEVEL {d}" text with something that reads at a glance without
// needing to parse a number.
fn drawDifficultyBar(x: i32, y: i32) void {
    var i: u8 = 1;
    while (i <= 10) : (i += 1) {
        const px = x + @as(i32, i - 1) * 8;
        if (i <= s.difficulty) {
            w4.DRAW_COLORS.* = 0x0004;
            w4.Rect(px, y, 6, 6);
        } else {
            w4.DRAW_COLORS.* = 0x0002;
            w4.Rect(px, y, 6, 1);
            w4.Rect(px, y + 5, 6, 1);
            w4.Rect(px, y, 1, 6);
            w4.Rect(px + 5, y, 1, 6);
        }
    }
}

// Position of each portrait in the setup screen's character grid -- wraps
// into rows of CHARS_PER_ROW rather than one long line (7 characters, at
// this sprite size plus gap, are too wide for the panel to fit in a single
// row), each row independently centered in the panel's own width so a
// shorter final row (3, not 4) still sits centered under the one above it
// rather than left-aligned.
const CHARS_PER_ROW: u8 = 4;
const CHAR_SLOT_GAP: i32 = 8;
const CHAR_ROW_GAP: i32 = 8;

fn charRowCount(row: u8) u8 {
    const start = row * CHARS_PER_ROW;
    return @intCast(@min(CHARS_PER_ROW, characters.COUNT - start));
}

fn charSlotPos(index: u8) struct { x: i32, y: i32, row: u8 } {
    const row = index / CHARS_PER_ROW;
    const col = index % CHARS_PER_ROW;
    const row_w = @as(i32, charRowCount(row)) * rchar.W + (@as(i32, charRowCount(row)) - 1) * CHAR_SLOT_GAP;
    const start_x = MENU_PANEL_X + @divTrunc(MENU_PANEL_W - row_w, 2);
    const x = start_x + @as(i32, col) * (rchar.W + CHAR_SLOT_GAP);
    const y = @as(i32, row) * (rchar.H + CHAR_ROW_GAP);
    return .{ .x = x, .y = y, .row = row };
}

// The setup flow's own screen position -- held fixed across all 3 steps
// (character, CPU reveal, difficulty) so the panel doesn't jump around
// between them, just its height/content changes.
const SETUP_BASE_Y: i32 = 24;

pub fn drawSetupCharacterScreen() void {
    const y = drawMenuPanelFill(SETUP_BASE_Y, 120);
    // Retheme the panel border itself to whichever character is currently
    // selected -- "switching should retheme the setup menu".
    drawThemedPanelBorder(MENU_PANEL_X, y, MENU_PANEL_W, 120, characters.ALL[s.player_character]);

    w4.DRAW_COLORS.* = 0x0003;
    w4.Text("SETUP", 58, y + 6);
    w4.DRAW_COLORS.* = 0x0002;
    w4.Text("CHARACTER", 40, y + 18);

    // Every character is shown at once (not just the current pick) --
    // left/right cycles the player's own selection (see main.zig),
    // highlighted with a dithered outline -- solid normally, blinking on/off
    // for a moment right after confirming (see state.setup_flash_timer)
    // before moving on to watch the CPU pick its own.
    const frame = rchar.currentFrame();
    const grid_y = y + 34;
    const flashing = s.setup_flash_timer > 0;
    const flash_on = !flashing or blinkOn(c.SETUP_FLASH_TOTAL_FRAMES - s.setup_flash_timer, c.SETUP_FLASH_TOGGLE_FRAMES);
    var last_row: u8 = 0;
    for (0..characters.COUNT) |i| {
        const pos = charSlotPos(@intCast(i));
        const cy = grid_y + pos.y;
        last_row = pos.row;
        rchar.draw(pos.x, cy, @intCast(i), .normal, frame);
        if (i == s.player_character and flash_on) {
            cells.drawDitheredRectOutline(pos.x - 2, cy - 2, rchar.W + 4, rchar.H + 4, badge.WARM_DITHER_HUES);
        }
    }
    const grid_bottom = grid_y + @as(i32, last_row) * (rchar.H + CHAR_ROW_GAP) + rchar.H;

    w4.DRAW_COLORS.* = 0x0002;
    var buf: [24]u8 = undefined;
    const you_label = std.fmt.bufPrint(&buf, "YOU: {s}", .{characters.ALL[s.player_character].name}) catch "YOU";
    w4.Text(you_label, 28, grid_bottom + 6);
    if (!flashing) {
        w4.Text("<-      ->", 40, grid_bottom + 18);
        w4.Text("PRESS X", 52, grid_bottom + 30);
    }
}

// True during the "on" half of a simple on/off blink -- elapsed frames
// since some start point, toggling every `period` frames.
fn blinkOn(elapsed: u16, period: u16) bool {
    return @mod(elapsed, period * 2) < period;
}

// Left edge of one of 2 side-by-side portraits (see drawSetupCpuRevealScreen)
// -- same centered-row idea as charSlotX, just for 2 slots instead of 4.
const REVEAL_GAP: i32 = 24;
fn revealSlotX(which: u8) i32 {
    const total_w = rchar.W * 2 + REVEAL_GAP;
    const start = MENU_PANEL_X + @divTrunc(MENU_PANEL_W - total_w, 2);
    return start + @as(i32, which) * (rchar.W + REVEAL_GAP);
}

pub fn drawSetupCpuRevealScreen() void {
    const y = drawMenuPanelFill(SETUP_BASE_Y, 80);
    drawThemedPanelBorder(MENU_PANEL_X, y, MENU_PANEL_W, 80, characters.ALL[s.player_character]);

    w4.DRAW_COLORS.* = 0x0003;
    w4.Text("SETUP", 58, y + 6);
    w4.DRAW_COLORS.* = 0x0002;
    w4.Text("CPU IS CHOOSING", 26, y + 18);

    const frame = rchar.currentFrame();
    const row_y = y + 34;
    const you_x = revealSlotX(0);
    const cpu_x = revealSlotX(1);
    rchar.draw(you_x, row_y, s.player_character, .normal, frame);
    cells.drawDitheredRectOutline(you_x - 2, row_y - 2, rchar.W + 4, rchar.H + 4, badge.WARM_DITHER_HUES);

    // Spins through every character once per tick, holding each a little
    // longer than the last (see state.cpu_reveal_tick/constants.
    // CPU_REVEAL_HOLD_*), landing for good on the real pick at the final
    // tick -- a slot machine slowing to a stop rather than an instant reveal.
    const done = s.cpu_reveal_tick >= c.CPU_REVEAL_STEPS - 1;
    const spin_index: u8 = if (done) s.cpu_character else @intCast(s.cpu_reveal_tick % characters.COUNT);
    rchar.draw(cpu_x, row_y, spin_index, .normal, frame);
    cells.drawDitheredRectOutline(cpu_x - 2, row_y - 2, rchar.W + 4, rchar.H + 4, badge.WARM_DITHER_HUES);

    w4.DRAW_COLORS.* = 0x0002;
    var buf: [24]u8 = undefined;
    const you_label = std.fmt.bufPrint(&buf, "YOU: {s}", .{characters.ALL[s.player_character].name}) catch "YOU";
    w4.Text(you_label, 22, row_y + rchar.H + 8);
    w4.DRAW_COLORS.* = 0x0004;
    var buf2: [24]u8 = undefined;
    const cpu_label = if (done)
        std.fmt.bufPrint(&buf2, "CPU: {s}", .{characters.ALL[s.cpu_character].name}) catch "CPU"
    else
        "CPU: ???";
    w4.Text(cpu_label, 22, row_y + rchar.H + 20);
}

pub fn drawSetupDifficultyScreen() void {
    const y = drawMenuPanelFill(SETUP_BASE_Y, 110);
    drawThemedPanelBorder(MENU_PANEL_X, y, MENU_PANEL_W, 110, characters.ALL[s.player_character]);

    w4.DRAW_COLORS.* = 0x0003;
    w4.Text("SETUP", 58, y + 6);
    w4.DRAW_COLORS.* = 0x0002;
    w4.Text("DIFFICULTY", 40, y + 18);

    var buf: [24]u8 = undefined;
    const you_label = std.fmt.bufPrint(&buf, "YOU: {s}", .{characters.ALL[s.player_character].name}) catch "YOU";
    w4.Text(you_label, 28, y + 32);
    w4.DRAW_COLORS.* = 0x0004;
    var buf2: [24]u8 = undefined;
    const cpu_label = std.fmt.bufPrint(&buf2, "CPU: {s}", .{characters.ALL[s.cpu_character].name}) catch "CPU";
    w4.Text(cpu_label, 28, y + 44);

    w4.DRAW_COLORS.* = 0x0002;
    drawDifficultyBar(40, y + 62);
    var buf3: [24]u8 = undefined;
    // Every level runs cpu_engine's actual move search -- see
    // cpu_ai.configFor -- lower levels just listen to it far less reliably.
    const label = std.fmt.bufPrint(&buf3, "LEVEL {d}", .{s.difficulty}) catch "LEVEL ?";
    w4.Text(label, 58, y + 74);
    w4.Text("<-      ->", 40, y + 88);
    w4.Text("PRESS X", 52, y + 100);
}

const STORY_TIER_LABELS = [4][]const u8{ "EASY", "MEDIUM", "HARD", "X HARD" };

// Story mode's own difficulty screen -- no CPU portrait/name here (unlike
// drawSetupDifficultyScreen above), since the opponent sequence is
// predetermined by the run itself (see game_modes.storyOpponentFor), not
// picked or rolled. Left/right only ever cycles EASY/MEDIUM/HARD (see
// main.zig's own cycling logic) -- X Hard is "by tradition" only reachable
// by holding left and pressing Z while sitting on HARD, so it never appears
// in the ordinary cycling order, and this screen only ever hints that it
// exists (never spells out the actual input) once game_modes.xhard_revealed
// says the player has actually earned that hint.
pub fn drawStoryTierScreen() void {
    const y = drawMenuPanelFill(SETUP_BASE_Y, 110);
    drawThemedPanelBorder(MENU_PANEL_X, y, MENU_PANEL_W, 110, characters.ALL[s.player_character]);

    w4.DRAW_COLORS.* = 0x0003;
    w4.Text("STORY", 58, y + 6);
    w4.DRAW_COLORS.* = 0x0002;
    w4.Text("DIFFICULTY", 40, y + 18);

    var buf: [24]u8 = undefined;
    const you_label = std.fmt.bufPrint(&buf, "YOU: {s}", .{characters.ALL[s.player_character].name}) catch "YOU";
    w4.Text(you_label, 28, y + 32);

    w4.DRAW_COLORS.* = 0x0004;
    w4.Text(STORY_TIER_LABELS[@intFromEnum(s.story_tier)], 52, y + 50);

    w4.DRAW_COLORS.* = 0x0002;
    w4.Text("<-      ->", 40, y + 66);
    w4.Text("PRESS X", 52, y + 78);

    if (game_modes.xhard_revealed and s.story_tier == .hard) {
        w4.Text("HOLD <- + Z ...", 22, y + 96);
    }
}

// Bezeled orange border for a full-screen overlay panel (the countdown and
// match-over screens): two concentric dithered outlines for a raised bezel
// look (the same technique render.drawCursor uses), plus a 1px black
// (background) outline just outside that so the bezel itself reads clearly
// against whatever's behind the panel -- the board, mid-scroll or otherwise
// -- rather than risking blending into it the way a single flat-colored edge
// might.
pub fn drawPanelBorder(x: i32, y: i32, w: i32, h: i32) void {
    w4.DRAW_COLORS.* = cells.DC_BG;
    w4.Rect(x - 1, y - 1, @intCast(w + 2), 1);
    w4.Rect(x - 1, y + h, @intCast(w + 2), 1);
    w4.Rect(x - 1, y - 1, 1, @intCast(h + 2));
    w4.Rect(x + w, y - 1, 1, @intCast(h + 2));

    cells.drawDitheredRectOutline(x, y, w, h, badge.WARM_DITHER_HUES);
    if (w > 2 and h > 2) {
        cells.drawDitheredRectOutline(x + 1, y + 1, w - 2, h - 2, badge.WARM_DITHER_HUES);
    }
}
