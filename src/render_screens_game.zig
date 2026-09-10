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
    w4.Text("MATCH OVER", 40, 58);
    w4.Text(text, 32, 74);

    var buf: [16]u8 = undefined;
    const pts = std.fmt.bufPrint(&buf, "{d} - {d}", .{ s.player_points, s.cpu_points }) catch "";
    w4.DRAW_COLORS.* = 0x0002;
    w4.Text(pts, 64, 84);

    if (s.set_winner != .none) {
        const set_text: []const u8 = if (s.set_winner == main_side) "YOU WIN THE SET!" else "OPPONENT WINS THE SET!";
        w4.DRAW_COLORS.* = 0x0004;
        w4.Text(set_text, 8, 96);
        w4.DRAW_COLORS.* = 0x0002;
        w4.Text("PRESS X", 40, 106);
    } else {
        w4.DRAW_COLORS.* = 0x0002;
        w4.Text("PRESS X", 40, 98);
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
    const headline: []const u8 = if (!won) "GAME OVER" else if (cleared_run) "STORY CLEAR!" else "STAGE CLEAR";
    w4.Text(headline, 40, 58);

    w4.DRAW_COLORS.* = 0x0002;
    var buf: [24]u8 = undefined;
    if (!won) {
        const go = std.fmt.bufPrint(&buf, "GAME OVERS: {d}", .{s.story_game_overs}) catch "";
        w4.Text(go, 34, 76);
        w4.Text("PRESS X TO RETRY", 22, 96);
    } else if (cleared_run) {
        const stage_str = std.fmt.bufPrint(&buf, "ALL {d} CLEARED!", .{game_modes.STORY_STAGES}) catch "";
        w4.Text(stage_str, 30, 76);
        if (s.story_game_overs == 0 and s.story_tier == .hard) {
            w4.DRAW_COLORS.* = 0x0004;
            w4.Text("X HARD UNLOCKED!", 22, 88);
            w4.DRAW_COLORS.* = 0x0002;
        }
        w4.Text("PRESS X", 52, 100);
    } else {
        const stage_str = std.fmt.bufPrint(&buf, "STAGE {d}/{d} DONE", .{ s.story_stage + 1, game_modes.STORY_STAGES }) catch "";
        w4.Text(stage_str, 26, 76);
        w4.Text("PRESS X", 52, 96);
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
