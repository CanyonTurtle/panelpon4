// Marathon mode's own scripted loop, split out of main.zig for file-size
// (same reasoning as tutorial.zig) -- solo, no opponent, no `s.winner`.

const w4 = @import("wasm4.zig");
const c = @import("constants.zig");
const s = @import("state.zig");
const board = @import("board.zig");
const sim = @import("sim.zig");
const input = @import("input.zig");
const audio = @import("audio.zig");
const game_modes = @import("game_modes.zig");

pub fn begin() void {
    game_modes.applyDefaultProfile();
    s.marathon_run_best_chain = 0;
    board.beginCountdown();
    c.BOARD_X = c.MARATHON_BOARD_X;
}

// Returns true once the player has confirmed leaving the game-over screen --
// main.zig then resets menu_phase, mirroring tutorial.update's own contract.
pub fn update(gp: u8, prev_gamepad: u8) bool {
    if (!s.marathon_over) {
        input.updateCursorMovement(&s.player, &s.held_dir, &s.das_counter, &s.cursor_idle_frames, gp);
        input.updateSwap(&s.player, &s.button_pending_swap, gp, prev_gamepad);
        if (gp & w4.BUTTON_2 != 0) board.tryManualRaise(&s.player);
        input.updateTouch();

        sim.simulate(&s.player, &s.cpu); // opponent unused in marathon mode (sim_matches_resolve.zig)
        board.updateRise(&s.player);
        board.updateDangerTimer(&s.player);
        if (s.player.chain > s.marathon_run_best_chain) s.marathon_run_best_chain = s.player.chain;

        if (s.player.game_over) {
            s.marathon_over = true;
            audio.playLoseJingle();
            board.beginClosing();
            game_modes.maybeUnlockForCombo(s.player.combo_display);
            // Recorded before the record itself updates -- see state.marathon_new_best.
            s.marathon_new_best = s.marathon_run_best_chain > game_modes.marathon_best_chain;
            game_modes.maybeUnlockMarathonBestChain(s.marathon_run_best_chain);
        }
        return false;
    }
    if (s.closing_timer > 0) {
        s.closing_timer -= 1;
        return false;
    }
    if (input.justPressed(gp, prev_gamepad, w4.BUTTON_1)) {
        s.marathon_over = false;
        c.BOARD_X = c.DEFAULT_BOARD_X;
        return true;
    }
    return false;
}
