const builtin = @import("builtin");
const w4 = @import("wasm4.zig");
const s = @import("state.zig");
const board = @import("board.zig");
const sim = @import("sim.zig");
const garbage = @import("sim_garbage.zig");
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
        @export(&debug.setGarbageCell, .{ .name = "debugSetGarbageCell" });
        @export(&debug.setCursor, .{ .name = "debugSetCursor" });
        @export(&debug.getChain, .{ .name = "debugGetChain" });
        @export(&debug.getScore, .{ .name = "debugGetScore" });
        @export(&debug.getCellInfo, .{ .name = "debugGetCellInfo" });
        @export(&debug.getWinner, .{ .name = "debugGetWinner" });
        @export(&debug.getCursorPos, .{ .name = "debugGetCursorPos" });
        @export(&debug.getScrollPx, .{ .name = "debugGetScrollPx" });
        @export(&debug.getDifficulty, .{ .name = "debugGetDifficulty" });
        @export(&debug.setDifficulty, .{ .name = "debugSetDifficulty" });
        @export(&debug.getManualRaiseElapsed, .{ .name = "debugGetManualRaiseElapsed" });
        @export(&debug.getDangerTimer, .{ .name = "debugGetDangerTimer" });
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
        // Sets the CPU's difficulty for the whole match (see state.difficulty
        // and cpu_ai.configFor) -- there's no menu to revisit it later, so
        // this is the only place it's adjustable.
        if (input.justPressed(gp, w4.BUTTON_LEFT) and s.difficulty > 1) s.difficulty -= 1;
        if (input.justPressed(gp, w4.BUTTON_RIGHT) and s.difficulty < 10) s.difficulty += 1;
        if (input.justPressed(gp, w4.BUTTON_1)) s.started = true;
        s.prev_gamepad = gp;
        return;
    }

    if (s.winner == .none) {
        input.updateCursorMovement(gp);
        input.updateSwap(gp);
        // Held (not just a fresh press) so the raise keeps going for as long
        // as Z stays down -- tryManualRaise already no-ops on its own while
        // still cooling down or mid-raise, so calling it every held frame
        // just means the next raise kicks off itself the instant it's
        // actually allowed to, with no extra debouncing needed here.
        if (gp & w4.BUTTON_2 != 0) board.tryManualRaise(&s.player);
        input.updateTouch();
        cpu_ai.update(&s.cpu);

        sim.simulate(&s.player, &s.cpu);
        sim.simulate(&s.cpu, &s.player);
        // Seals and hands off each board's own concluded chain garbage to
        // the *other* board's incoming queue (also resets .chain, replacing
        // the plain "if idle, reset" check this used to be -- see
        // sim_garbage.resolveChainEnd), then drains each board's own
        // incoming queue once it's idle (sim_garbage.releaseIncomingGarbage)
        // -- together, garbage from either side never lands while a match
        // or chain is still resolving on the sending board OR the
        // receiving one.
        garbage.resolveChainEnd(&s.player, &s.cpu);
        garbage.resolveChainEnd(&s.cpu, &s.player);
        garbage.releaseIncomingGarbage(&s.player);
        garbage.releaseIncomingGarbage(&s.cpu);
        board.updateRise(&s.player);
        board.updateRise(&s.cpu);
        board.updateDangerTimer(&s.player);
        board.updateDangerTimer(&s.cpu);

        // Whoever's board tops out first loses -- see board.updateDangerTimer.
        // Both on the same frame (only possible if both happen to top out on
        // the exact same frame) is a draw.
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
