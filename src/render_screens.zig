// Pre-game/menu screens plus the match-over overlay chrome, split out of
// render.zig, which re-exports every `pub fn` here so call sites don't change.

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
const logo = @import("logo.zig");
const rcpu = @import("render_cpu.zig");

const MENU_PANEL_X: i32 = 20;
const MENU_PANEL_W: i32 = 120;

const PANEL_EASE_FRAMES: u32 = 14;
const PANEL_SLIDE_DIST: i32 = 30;

fn easeOutCubic(t: f32) f32 {
    const f = t - 1.0;
    return f * f * f + 1.0;
}

// Distance still left to slide, decelerating to 0 as menu_phase_timer
// reaches PANEL_EASE_FRAMES (see main.zig's setMenuPhase).
fn panelSlideOffset() i32 {
    if (s.menu_phase_timer >= PANEL_EASE_FRAMES) return 0;
    const t = @as(f32, @floatFromInt(s.menu_phase_timer)) / @as(f32, @floatFromInt(PANEL_EASE_FRAMES));
    const remaining = 1.0 - easeOutCubic(t);
    return @intFromFloat(@round(@as(f32, @floatFromInt(PANEL_SLIDE_DIST)) * remaining));
}

// Common backdrop; the returned Y eases in from above on every fresh
// menu_phase -- everything downstream reuses it, so the screen slides in together.
fn drawMenuPanelFill(base_y: i32, h: i32) i32 {
    bg.draw();
    const y = base_y - panelSlideOffset();
    w4.DRAW_COLORS.* = 0x0001;
    w4.Rect(MENU_PANEL_X, y, MENU_PANEL_W, @intCast(h));
    return y;
}

// A plain (unchamfered) themed border, same treatment render.drawFrame
// gives the real board -- used by setup screens to retheme to the pick.
fn drawThemedPanelBorder(x: i32, y: i32, w: i32, h: i32, char: characters.Character) void {
    const t = render.FRAME_THICKNESS;
    render.drawThemedBand(x, y, w, t, char.hues, char.border_style, true);
    render.drawThemedBand(x, y + h - t, w, t, char.hues, char.border_style, true);
    render.drawThemedBand(x, y, t, h, char.hues, char.border_style, false);
    render.drawThemedBand(x + w - t, y, t, h, char.hues, char.border_style, false);
}

// The big bubble-letter wordmark (see logo.zig) -- top few rows draw as a
// lighter "shine" tone, everything else the main fill, for a glossy look.
const LOGO_HIGHLIGHT_ROWS: usize = 4;
fn drawLogo(x0: i32, y0: i32) void {
    for (logo.WORD, 0..) |glyph, gi| {
        const gx = x0 + @as(i32, @intCast(gi)) * logo.STRIDE;
        for (glyph, 0..) |row, ry| {
            for (row, 0..) |ch, rx| {
                if (ch != '#') continue;
                w4.DRAW_COLORS.* = if (ry < LOGO_HIGHLIGHT_ROWS) 0x0003 else 0x0004;
                w4.Rect(gx + @as(i32, @intCast(rx)), y0 + @as(i32, @intCast(ry)), 1, 1);
            }
        }
    }
}

// A slow +-2px bob, integer triangle wave -- std.math.sin alone cost ~6.5KB
// of soft-float trig code here, blowing past WASM-4's 64KB cart limit.
fn titleLogoBob() i32 {
    const period: i32 = 96;
    const half = @divExact(period, 2);
    const phase: i32 = @intCast(@mod(s.frame_count, @as(u32, @intCast(period))));
    const dist = if (phase < half) phase else period - phase; // 0..half..0
    return @divTrunc(dist, 12) - 2;
}

// No panel -- s.player/s.cpu play themselves live (main.zig's updateTitleDemo),
// flanking the logo. Fixed characters, not whichever the player last picked.
const TITLE_BOARD_Y: i32 = 58;
const TITLE_BOARD_L_X: i32 = 20;
const TITLE_BOARD_R_X: i32 = 98;

pub fn drawTitleScreen() void {
    bg.draw();
    rcpu.drawMicroBoard(&s.player, characters.LIZARD_INDEX, TITLE_BOARD_L_X, TITLE_BOARD_Y);
    rcpu.drawMicroBoard(&s.cpu, characters.CROW_INDEX, TITLE_BOARD_R_X, TITLE_BOARD_Y);

    const logo_x = @divTrunc(160 - logo.TOTAL_W, 2);
    drawLogo(logo_x, 16 - panelSlideOffset() + titleLogoBob());
    w4.DRAW_COLORS.* = 0x0004;
    w4.Text("PRESS X", 52, 40);
}

// Uses the title screen's plain bezel, not a character-themed one. Order
// must match state.GameMode's up/down cycling order (main.zig) top to bottom.
const GAME_MODE_LABELS = [4][]const u8{ "TUTORIAL", "1P QUICK MATCH", "1P STORY", "2P VERSUS" };
const MODE_SELECT_PANEL_H: i32 = 114;
const MODE_LIST_STEP: i32 = 12;
fn gameModeIndex(m: s.GameMode) u8 {
    return switch (m) {
        .tutorial => 0,
        .quick => 1,
        .story => 2,
        .versus => 3,
    };
}

pub fn drawModeSelectScreen() void {
    const y = drawMenuPanelFill(30, MODE_SELECT_PANEL_H);
    drawPanelBorder(MENU_PANEL_X, y, MENU_PANEL_W, MODE_SELECT_PANEL_H);
    w4.DRAW_COLORS.* = 0x0003;
    w4.Text("SELECT MODE", 34, y + 10);

    // 22/116 wraps the longest label ("1P QUICK MATCH", 14 chars) with a
    // couple px of padding, staying inside the panel (x 20..140).
    const cur = gameModeIndex(s.game_mode);
    for (GAME_MODE_LABELS, 0..) |label, i| {
        const line_y = y + 30 + @as(i32, @intCast(i)) * MODE_LIST_STEP;
        if (i == cur) {
            cells.drawDitheredRectOutline(22, line_y - 2, 116, 10, badge.WARM_DITHER_HUES);
        }
        w4.DRAW_COLORS.* = if (i == cur) 0x0004 else 0x0002;
        w4.Text(label, 24, line_y);
    }
    w4.DRAW_COLORS.* = 0x0002;
    w4.Text("UP / DOWN", 44, y + 86);
    w4.Text("PRESS X", 52, y + 98);
}

// A manual gate ensuring the second player has actually joined before
// main.zig reads wasm4.NETPLAY -- joining mid-match would desync the peers.
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

// One filled-in segment per difficulty level (1-10).
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

// Wraps into rows of CHARS_PER_ROW (7 characters are too wide for one row);
// each row is independently centered, so a shorter final row stays centered.
const CHARS_PER_ROW: u8 = 4;
const CHAR_SLOT_GAP: i32 = 8;
const CHAR_ROW_GAP: i32 = 8;

fn charRowCount(row: u8, total: u8) u8 {
    const start = row * CHARS_PER_ROW;
    return @intCast(@min(CHARS_PER_ROW, total - start));
}

// `total` is how many portraits are actually laid out -- the full roster
// for setup_character, or just the unlocked party for drawStoryCharacterSelect.
fn charSlotPos(index: u8, total: u8) struct { x: i32, y: i32, row: u8 } {
    const row = index / CHARS_PER_ROW;
    const col = index % CHARS_PER_ROW;
    const row_w = @as(i32, charRowCount(row, total)) * rchar.W + (@as(i32, charRowCount(row, total)) - 1) * CHAR_SLOT_GAP;
    const start_x = MENU_PANEL_X + @divTrunc(MENU_PANEL_W - row_w, 2);
    const x = start_x + @as(i32, col) * (rchar.W + CHAR_SLOT_GAP);
    const y = @as(i32, row) * (rchar.H + CHAR_ROW_GAP);
    return .{ .x = x, .y = y, .row = row };
}

// Held fixed across all 3 setup steps so the panel doesn't jump around.
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

    // Every character shown at once; the current pick gets a dithered
    // outline, blinking briefly right after confirming (setup_flash_timer).
    const frame = rchar.currentFrame();
    const grid_y = y + 34;
    const flashing = s.setup_flash_timer > 0;
    const flash_on = !flashing or blinkOn(c.SETUP_FLASH_TOTAL_FRAMES - s.setup_flash_timer, c.SETUP_FLASH_TOGGLE_FRAMES);
    var last_row: u8 = 0;
    for (0..characters.COUNT) |i| {
        const idx: u8 = @intCast(i);
        const pos = charSlotPos(idx, characters.COUNT);
        const cy = grid_y + pos.y;
        last_row = pos.row;
        if (!game_modes.charUnlocked(idx)) {
            cells.drawDitheredRectOutline(pos.x, cy, rchar.W, rchar.H, badge.WARM_DITHER_HUES);
        } else {
            rchar.draw(pos.x, cy, idx, .normal, frame);
        }
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
    w4.Text("CPU CHOOSING", 32, y + 18);

    const frame = rchar.currentFrame();
    const row_y = y + 34;
    const you_x = revealSlotX(0);
    const cpu_x = revealSlotX(1);
    rchar.draw(you_x, row_y, s.player_character, .normal, frame);
    cells.drawDitheredRectOutline(you_x - 2, row_y - 2, rchar.W + 4, rchar.H + 4, badge.WARM_DITHER_HUES);

    // Spins through every character, holding each tick a little longer
    // (a slot machine slowing to a stop), landing on the real pick last.
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

// No CPU portrait: the opponent sequence is predetermined. X Hard is reached
// by hold-left+Z on HARD, hinted only once xhard_revealed says it's earned.
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

// Shown between stages whenever the party has more than one member to pick
// from (main.zig's beginStoryFlow) -- only ever offers already-freed characters.
pub fn drawStoryCharacterSelect() void {
    const y = drawMenuPanelFill(SETUP_BASE_Y, 120);
    drawThemedPanelBorder(MENU_PANEL_X, y, MENU_PANEL_W, 120, characters.ALL[s.story_select_cursor]);

    w4.DRAW_COLORS.* = 0x0003;
    w4.Text("CHOOSE YOUR", 34, y + 6);
    w4.DRAW_COLORS.* = 0x0002;
    w4.Text("FIGHTER", 52, y + 18);

    var unlocked: [characters.COUNT]u8 = undefined;
    var n: u8 = 0;
    for (0..characters.COUNT) |i| {
        if (s.story_party[i]) {
            unlocked[n] = @intCast(i);
            n += 1;
        }
    }

    const frame = rchar.currentFrame();
    const grid_y = y + 34;
    var last_row: u8 = 0;
    for (0..n) |k| {
        const idx = unlocked[k];
        const pos = charSlotPos(@intCast(k), n);
        const cy = grid_y + pos.y;
        last_row = pos.row;
        rchar.draw(pos.x, cy, idx, .normal, frame);
        if (idx == s.story_select_cursor) {
            cells.drawDitheredRectOutline(pos.x - 2, cy - 2, rchar.W + 4, rchar.H + 4, badge.WARM_DITHER_HUES);
        }
    }
    const grid_bottom = grid_y + @as(i32, last_row) * (rchar.H + CHAR_ROW_GAP) + rchar.H;

    w4.DRAW_COLORS.* = 0x0002;
    const you_label = characters.ALL[s.story_select_cursor].name;
    w4.Text(you_label, MENU_PANEL_X + @divTrunc(MENU_PANEL_W - @as(i32, @intCast(you_label.len)) * 8, 2), grid_bottom + 6);
    if (n > 1) w4.Text("<-      ->", 40, grid_bottom + 18);
    w4.Text("PRESS X", 52, grid_bottom + 30);
}

const WALK_SLIDE_START_PX: i32 = 40;

// How far the hero portrait still has to slide in, easing to 0 by
// STORY_WALK_TRANSITION_FRAMES -- plain integer math, no trig (see titleLogoBob's own note).
fn walkSlideOffset() i32 {
    if (s.story_flow_timer >= c.STORY_WALK_TRANSITION_FRAMES) return 0;
    const remaining = c.STORY_WALK_TRANSITION_FRAMES - s.story_flow_timer;
    return @intCast(remaining * @as(u32, @intCast(WALK_SLIDE_START_PX)) / c.STORY_WALK_TRANSITION_FRAMES);
}

// The walk-up-to-the-next-opponent scene: the active party member slides in
// to face the next cursed character, each speaking their own dialogue line.
pub fn drawStoryWalkTransition() void {
    const y = drawMenuPanelFill(SETUP_BASE_Y, 120);
    drawThemedPanelBorder(MENU_PANEL_X, y, MENU_PANEL_W, 120, characters.ALL[s.player_character]);

    w4.DRAW_COLORS.* = 0x0003;
    w4.Text("FREE THEM FROM", 24, y + 8);
    w4.Text("THE CURSE!", 44, y + 20);

    const frame = rchar.currentFrame();
    const row_y = y + 38;
    const hero_x = revealSlotX(0) - walkSlideOffset();
    const foe_x = revealSlotX(1);
    rchar.draw(hero_x, row_y, s.player_character, .normal, frame);
    rchar.draw(foe_x, row_y, s.cpu_character, .normal, frame);
    cells.drawDitheredRectOutline(foe_x - 2, row_y - 2, rchar.W + 4, rchar.H + 4, badge.WARM_DITHER_HUES);

    // Each speaker gets 2 lines (name, dialogue), inset to the panel's left
    // margin -- dialogue is capped at 14 chars (Character.dialogue) so it fits.
    const text_x = 24;
    const text_y = row_y + rchar.H + 8;
    w4.DRAW_COLORS.* = 0x0004;
    w4.Text(characters.ALL[s.cpu_character].name, text_x, text_y);
    w4.Text(characters.ALL[s.cpu_character].dialogue, text_x, text_y + 9);

    if (s.story_flow_timer >= c.STORY_WALK_TRANSITION_FRAMES) {
        w4.DRAW_COLORS.* = 0x0002;
        w4.Text(characters.ALL[s.player_character].name, text_x, text_y + 22);
        w4.Text(characters.ALL[s.player_character].dialogue, text_x, text_y + 31);
        w4.Text("PRESS X", 52, y + 108);
    }
}

// Two concentric dithered outlines for a raised bezel, plus a 1px background
// outline outside that so it reads clearly against whatever's behind it.
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
