// Match-over overlays and the "3 2 1 START" countdown, split out of
// render_screens.zig; render.zig re-exports these.

const std = @import("std");
const c = @import("constants.zig");
const s = @import("state.zig");
const w4 = @import("wasm4.zig");
const rchar = @import("render_character.zig");
const game_modes = @import("game_modes.zig");
const screens = @import("render_screens.zig");
const render = @import("render.zig");

// x that centers `str` within [box_x, box_x+box_w) -- avoids hardcoded
// eyeballed positions that only fit one specific string's length.
fn centeredX(box_x: i32, box_w: i32, str: []const u8) i32 {
    return box_x + @divTrunc(box_w - @as(i32, @intCast(str.len)) * 8, 2);
}

// Winner celebrates, loser winces (idle on a draw). `won` is from the main
// side's rendering perspective, not always state.player.
fn drawGameOverPortraits(x: i32, y: i32, w: i32, won: ?bool) void {
    const frame = rchar.currentFrame();
    const main_state: rchar.CharState = if (won) |w_| (if (w_) .win else .punish) else .normal;
    const mini_state: rchar.CharState = if (won) |w_| (if (w_) .punish else .win) else .normal;
    rchar.draw(x + 4, y + 4, render.mainCharacter(), main_state, frame);
    rchar.draw(x + w - rchar.W - 4, y + 4, render.miniCharacter(), mini_state, frame);
}

// Only called once the closing wipe finishes popping every row. Story mode
// defers entirely to drawStoryGameOver below instead of a series score.
pub fn drawGameOver() void {
    if (s.game_mode == .story) return drawStoryGameOver();

    // Versus mode's main side isn't always state.player -- see
    // state.versus_render_swapped -- so compare against main_side, not .player.
    const main_side: s.Winner = if (s.versus_render_swapped) .cpu else .player;
    const text: []const u8 = switch (s.winner) {
        .draw => "DRAW",
        .none => unreachable, // drawGameOver is only ever called once winner != .none
        else => if (s.winner == main_side) "YOU WIN" else "YOU LOSE",
    };
    const x = 20;
    const y = 52;
    const w = 120;
    const h = 68;
    w4.DRAW_COLORS.* = 0x0001;
    w4.Rect(x, y, w, h);
    screens.drawPanelBorder(x, y, w, h);

    const won: ?bool = if (s.winner == .draw) null else s.winner == main_side;
    drawGameOverPortraits(x, y, w, won);

    w4.DRAW_COLORS.* = 0x0004;
    w4.Text("MATCH OVER", centeredX(x, w, "MATCH OVER"), 58);
    w4.Text(text, centeredX(x, w, text), 74);

    var buf: [16]u8 = undefined;
    const pts = std.fmt.bufPrint(&buf, "{d} - {d}", .{ s.player_points, s.cpu_points }) catch "";
    w4.DRAW_COLORS.* = 0x0002;
    w4.Text(pts, centeredX(x, w, pts), 84);

    if (s.set_winner != .none) {
        // Both must stay well under 15 chars (120px) to fit this box.
        const set_text: []const u8 = if (s.set_winner == main_side) "SET WON!" else "SET LOST!";
        w4.DRAW_COLORS.* = 0x0004;
        w4.Text(set_text, centeredX(x, w, set_text), 96);
        w4.DRAW_COLORS.* = 0x0002;
        w4.Text("PRESS X", centeredX(x, w, "PRESS X"), 106);
    } else {
        w4.DRAW_COLORS.* = 0x0002;
        w4.Text("PRESS X", centeredX(x, w, "PRESS X"), 98);
    }
}

// One stage's outcome plus the run's game-over tally, not a series score.
// xhard_revealed is already set (game_modes.maybeRevealXhard) by render time.
fn drawStoryGameOver() void {
    const won = s.winner == .player;
    const cleared_run = won and s.story_stage + 1 >= game_modes.STORY_STAGES;

    const x = 20;
    const y = 52;
    const w = 120;
    const h = 68;
    w4.DRAW_COLORS.* = 0x0001;
    w4.Rect(x, y, w, h);
    screens.drawPanelBorder(x, y, w, h);
    drawGameOverPortraits(x, y, w, won);

    w4.DRAW_COLORS.* = 0x0004;
    const headline: []const u8 = if (!won) "GAME OVER" else if (cleared_run) "CURSE BROKEN!" else "FREED!";
    w4.Text(headline, centeredX(x, w, headline), 58);

    w4.DRAW_COLORS.* = 0x0002;
    var buf: [24]u8 = undefined;
    if (!won) {
        const go = std.fmt.bufPrint(&buf, "GAME OVERS: {d}", .{s.story_game_overs}) catch "";
        w4.Text(go, centeredX(x, w, go), 76);
        w4.Text("PRESS X", centeredX(x, w, "PRESS X"), 96);
    } else if (cleared_run) {
        const stage_str = std.fmt.bufPrint(&buf, "ALL {d} CLEARED!", .{game_modes.STORY_STAGES}) catch "";
        w4.Text(stage_str, centeredX(x, w, stage_str), 76);
        if (s.story_game_overs == 0 and s.story_tier == .hard) {
            const unlocked = "X HARD OPEN!";
            w4.DRAW_COLORS.* = 0x0004;
            w4.Text(unlocked, centeredX(x, w, unlocked), 88);
            w4.DRAW_COLORS.* = 0x0002;
        }
        w4.Text("PRESS X", centeredX(x, w, "PRESS X"), 100);
    } else {
        const stage_str = std.fmt.bufPrint(&buf, "STAGE {d}/{d} DONE", .{ s.story_stage + 1, game_modes.STORY_STAGES }) catch "";
        w4.Text(stage_str, centeredX(x, w, stage_str), 76);
        w4.Text("PRESS X", centeredX(x, w, "PRESS X"), 96);
    }
}

// Marathon has no opponent, so just one (always losing-wince) portrait --
// left-aligned like drawGameOverPortraits' own left slot, clear of the headline.
fn drawMarathonPortrait(x: i32, y: i32) void {
    const frame = rchar.currentFrame();
    rchar.draw(x + 4, y + 4, s.player_character, .punish, frame);
}

// Final score/chain for this run, plus a "NEW BEST!" callout when
// state.marathon_new_best was set (main.zig, before the record updates).
pub fn drawMarathonGameOver() void {
    const x = 20;
    const y = 52;
    const w = 120;
    const h = 68;
    w4.DRAW_COLORS.* = 0x0001;
    w4.Rect(x, y, w, h);
    screens.drawPanelBorder(x, y, w, h);
    drawMarathonPortrait(x, y);

    w4.DRAW_COLORS.* = 0x0004;
    w4.Text("GAME OVER", centeredX(x, w, "GAME OVER"), 58);

    w4.DRAW_COLORS.* = 0x0002;
    var buf: [24]u8 = undefined;
    const score_str = std.fmt.bufPrint(&buf, "SCORE {d}", .{s.player.score}) catch "";
    w4.Text(score_str, centeredX(x, w, score_str), 76);

    var chain_buf: [24]u8 = undefined;
    const chain_str = std.fmt.bufPrint(&chain_buf, "BEST CHAIN x{d}", .{s.marathon_run_best_chain}) catch "";
    w4.Text(chain_str, centeredX(x, w, chain_str), 86);

    if (s.marathon_new_best) {
        w4.DRAW_COLORS.* = 0x0004;
        w4.Text("NEW BEST!", centeredX(x, w, "NEW BEST!"), 96);
        w4.DRAW_COLORS.* = 0x0002;
        w4.Text("PRESS X", centeredX(x, w, "PRESS X"), 106);
    } else {
        w4.Text("PRESS X", centeredX(x, w, "PRESS X"), 100);
    }
}

// "3 2 1 START" shown once per match (see state.countdown_timer,
// board.beginCountdown). Numbers rise then hold; START rises then blinks.
pub fn drawCountdown() void {
    const elapsed = c.COUNTDOWN_TOTAL_FRAMES - s.countdown_timer;

    var label: []const u8 = "3";
    var stage_elapsed: i32 = elapsed;
    var is_start = false;
    if (elapsed < c.COUNTDOWN_NUMBER_FRAMES) {
        label = "3";
    } else if (elapsed < c.COUNTDOWN_NUMBER_FRAMES * 2) {
        label = "2";
        stage_elapsed = elapsed - c.COUNTDOWN_NUMBER_FRAMES;
    } else if (elapsed < c.COUNTDOWN_NUMBER_FRAMES * 3) {
        label = "1";
        stage_elapsed = elapsed - c.COUNTDOWN_NUMBER_FRAMES * 2;
    } else {
        label = "START";
        stage_elapsed = elapsed - c.COUNTDOWN_NUMBER_FRAMES * 3;
        is_start = true;
    }

    var visible = true;
    var rise_offset: i32 = 0;
    if (stage_elapsed < c.COUNTDOWN_RISE_FRAMES) {
        const remain = c.COUNTDOWN_RISE_FRAMES - stage_elapsed;
        rise_offset = @divTrunc(remain * c.COUNTDOWN_RISE_PX, c.COUNTDOWN_RISE_FRAMES);
    } else if (is_start) {
        const blink_elapsed = stage_elapsed - c.COUNTDOWN_RISE_FRAMES;
        const phase = @divTrunc(blink_elapsed, c.COUNTDOWN_BLINK_HALF_FRAMES);
        visible = @mod(phase, 2) == 0;
    }
    if (!visible) return;

    const char_w: i32 = 8;
    const text_w: i32 = @as(i32, @intCast(label.len)) * char_w;
    const cx: i32 = 80; // screen center (SCREEN_SIZE/2)
    const base_y: i32 = 70;
    const y = base_y - rise_offset;
    const pad: i32 = 8;
    const box_x = cx - @divTrunc(text_w, 2) - pad;
    const box_y = y - 6;
    const box_w = text_w + 2 * pad;
    const box_h = char_w + 12;

    w4.DRAW_COLORS.* = 0x0001;
    w4.Rect(box_x, box_y, @intCast(box_w), @intCast(box_h));
    screens.drawPanelBorder(box_x, box_y, box_w, box_h);
    w4.DRAW_COLORS.* = 0x0004;
    w4.Text(label, cx - @divTrunc(text_w, 2), y);
}

const TUTORIAL_CAPTION_Y: i32 = 144; // the 16px strip below the board (BOARD_BOTTOM), never drawn into by drawBoard

// Drawn last, over the rendered frame -- same pattern as drawCountdown/
// drawGameOver above. step/total show a small progress counter.
pub fn drawTutorialCaption(line1: []const u8, line2: []const u8, step: u8, total: u8) void {
    w4.DRAW_COLORS.* = 0x0001;
    w4.Rect(0, TUTORIAL_CAPTION_Y, w4.SCREEN_SIZE, @intCast(@as(i32, @intCast(w4.SCREEN_SIZE)) - TUTORIAL_CAPTION_Y));
    w4.DRAW_COLORS.* = 0x0004;
    w4.Text(line1, 4, TUTORIAL_CAPTION_Y);
    var buf: [8]u8 = undefined;
    const progress = std.fmt.bufPrint(&buf, "{d}/{d}", .{ step, total }) catch "";
    w4.Text(progress, @as(i32, @intCast(w4.SCREEN_SIZE)) - @as(i32, @intCast(progress.len * 8)) - 4, TUTORIAL_CAPTION_Y);
    w4.DRAW_COLORS.* = 0x0002;
    w4.Text(line2, 4, TUTORIAL_CAPTION_Y + 8);
}
