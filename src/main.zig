const builtin = @import("builtin");
const w4 = @import("wasm4.zig");
const s = @import("state.zig");
const board = @import("board.zig");
const sim = @import("sim.zig");
const input = @import("input.zig");
const cpu_ai = @import("cpu_ai.zig");
const render = @import("render.zig");
const audio = @import("audio.zig");
const debug = @import("debug.zig");

// Debug-only WASM exports (see debug.zig) for tools/wasm4-harness.js to
// drive: only compiled into Debug builds, so `zig build --release=small`
// still exports just start/update.
comptime {
    if (builtin.mode == .Debug) {
        @export(&debug.clearBoard, .{ .name = "debugClearBoard" });
        @export(&debug.setCell, .{ .name = "debugSetCell" });
        @export(&debug.setCursor, .{ .name = "debugSetCursor" });
        @export(&debug.getChain, .{ .name = "debugGetChain" });
        @export(&debug.getCellInfo, .{ .name = "debugGetCellInfo" });
        @export(&debug.getWinner, .{ .name = "debugGetWinner" });
        @export(&debug.getCursorPos, .{ .name = "debugGetCursorPos" });
    }
}

export fn start() void {
    render.setupPalette();
    board.resetGame(&s.player);
    board.resetGame(&s.cpu);
}

export fn update() void {
    s.frame_count += 1;
    const gp = w4.GAMEPAD1.*;
    const was_over = s.winner != .none;
    // Any gamepad button (a direction or X) brings the cursor back -- see
    // state.cursor_hidden and input.updateTouch, which hides it the instant
    // touch starts.
    if (gp != 0) s.cursor_hidden = false;

    if (!s.started) {
        _ = s.player.rngNext();
        render.clearBackground();
        render.drawTitle();
        if (input.justPressed(gp, w4.BUTTON_1)) s.started = true;
        s.prev_gamepad = gp;
        return;
    }

    if (s.winner == .none) {
        input.updateCursorMovement(gp);
        if (input.justPressed(gp, w4.BUTTON_1)) sim.trySwap(&s.player);
        input.updateTouch();
        cpu_ai.update(&s.cpu);

        sim.simulate(&s.player, &s.cpu);
        sim.simulate(&s.cpu, &s.player);
        if (!s.player.boardBusy()) s.player.chain = 0;
        if (!s.cpu.boardBusy()) s.cpu.chain = 0;
        board.updateRise(&s.player);
        board.updateRise(&s.cpu);

        // Whoever's board tops out first loses -- see board.doRise. Both on
        // the same frame (only possible if both happen to rise into a
        // topped-out state simultaneously) is a draw.
        if (s.player.game_over and s.cpu.game_over) {
            s.winner = .draw;
        } else if (s.player.game_over) {
            s.winner = .cpu;
        } else if (s.cpu.game_over) {
            s.winner = .player;
        }
        if (s.winner != .none and !was_over) audio.playGameOverSound();
    } else {
        if (input.justPressed(gp, w4.BUTTON_1)) {
            board.resetGame(&s.player);
            board.resetGame(&s.cpu);
            s.winner = .none;
        }
    }

    render.render();
    if (s.winner != .none) render.drawGameOver();

    s.prev_gamepad = gp;
}
