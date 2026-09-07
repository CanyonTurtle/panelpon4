const w4 = @import("wasm4.zig");
const s = @import("state.zig");
const board = @import("board.zig");
const sim = @import("sim.zig");
const input = @import("input.zig");
const render = @import("render.zig");
const audio = @import("audio.zig");

export fn start() void {
    render.setupPalette();
    board.resetGame();
}

export fn update() void {
    s.frame_count += 1;
    const gp = w4.GAMEPAD1.*;
    const was_game_over = s.game_over;

    if (!s.started) {
        _ = s.rngNext();
        render.clearBackground();
        render.drawTitle();
        if (input.justPressed(gp, w4.BUTTON_1)) s.started = true;
        s.prev_gamepad = gp;
        return;
    }

    if (!s.game_over) {
        input.updateCursorMovement(gp);
        if (input.justPressed(gp, w4.BUTTON_1)) sim.trySwap();
        input.updateTouch();
        sim.simulate();
        if (!s.boardBusy()) s.chain = 0;
        board.updateRise();
        if (s.game_over and !was_game_over) audio.playGameOverSound();
    } else {
        if (input.justPressed(gp, w4.BUTTON_1)) board.resetGame();
    }

    render.render();
    if (s.game_over) render.drawGameOver();

    s.prev_gamepad = gp;
}
