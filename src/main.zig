const builtin = @import("builtin");
const w4 = @import("wasm4.zig");
const c = @import("constants.zig");
const s = @import("state.zig");
const touch_state = @import("state_touch.zig");
const board = @import("board.zig");
const sim = @import("sim.zig");
const garbage = @import("sim_garbage.zig");
const input = @import("input.zig");
const cpu_ai = @import("cpu_ai.zig");
const render = @import("render.zig");
const audio = @import("audio.zig");
const debug = @import("debug.zig");
const characters = @import("characters.zig");
const game_modes = @import("game_modes.zig");
const tutorial = @import("tutorial.zig");

// mode_select's own up/down cycling order, top to bottom: quick -> story ->
// tutorial -> versus -> wraps back to quick (must match its displayed order).
fn prevMode(m: s.GameMode) s.GameMode {
    return switch (m) {
        .quick => .versus,
        .story => .quick,
        .tutorial => .story,
        .versus => .tutorial,
    };
}
fn nextMode(m: s.GameMode) s.GameMode {
    return switch (m) {
        .quick => .story,
        .story => .tutorial,
        .tutorial => .versus,
        .versus => .quick,
    };
}

// Debug-only WASM exports (see debug.zig) for the JS test harness to drive;
// only compiled into Debug builds, so a release build stays minimal.
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
    board.resetSharedRows();
    board.resetGame(&s.player);
    board.resetGame(&s.cpu);
    game_modes.loadSave();
}

export fn update() void {
    s.frame_count += 1;
    const gp = w4.GAMEPAD1.*;
    // Read every frame regardless of mode so cpu_prev_gamepad's "was this
    // just pressed" history stays accurate across countdown/menu screens too.
    const gp2 = w4.GAMEPAD2.*;
    const was_over = s.winner != .none;
    // Any gamepad button brings the cursor back (see input.updateTouch,
    // which hides it the instant touch starts).
    if (gp != 0) touch_state.cursor_hidden = false;

    // Freezes input/simulation entirely and just renders the already-reset
    // boards underneath the countdown overlay until it counts down to 0.
    if (s.countdown_timer > 0) {
        s.countdown_timer -= 1;
        render.render();
        render.drawCountdown();
        if (s.countdown_timer <= 0) s.started = true;
        s.prev_gamepad = gp;
        s.cpu_prev_gamepad = gp2;
        return;
    }

    // Tutorial runs its own scripted loop entirely, bypassing the win/lose,
    // versus, and story branches below (see tutorial.zig).
    if (s.started and s.game_mode == .tutorial) {
        render.render();
        const lines = tutorial.captionLines();
        render.drawTutorialCaption(lines.line1, lines.line2, tutorial.stepNumber(), tutorial.STEP_COUNT);
        if (tutorial.update(gp, s.prev_gamepad)) {
            s.started = false;
            s.menu_phase = .mode_select;
        }
        s.prev_gamepad = gp;
        s.cpu_prev_gamepad = gp2;
        return;
    }

    if (!s.started) {
        _ = s.player.rngNext();
        board.perturbSharedRng();
        switch (s.menu_phase) {
            .title => {
                render.drawTitleScreen();
                if (input.justPressed(gp, s.prev_gamepad, w4.BUTTON_1)) s.menu_phase = .mode_select;
            },
            .mode_select => {
                render.drawModeSelectScreen();
                if (input.justPressed(gp, s.prev_gamepad, w4.BUTTON_UP)) s.game_mode = prevMode(s.game_mode);
                if (input.justPressed(gp, s.prev_gamepad, w4.BUTTON_DOWN)) s.game_mode = nextMode(s.game_mode);
                if (input.justPressed(gp, s.prev_gamepad, w4.BUTTON_1)) {
                    switch (s.game_mode) {
                        .quick, .story => s.menu_phase = .setup_character,
                        // Versus skips character/difficulty picking; confirm
                        // screen comes first since netplay handshakes outside the cart.
                        .versus => s.menu_phase = .versus_confirm,
                        // Tutorial skips setup and the countdown entirely --
                        // it seeds its own scripted board state directly.
                        .tutorial => {
                            tutorial.begin();
                            s.started = true;
                        },
                    }
                }
            },
            .versus_confirm => {
                render.drawVersusConfirmScreen();
                if (input.justPressed(gp, s.prev_gamepad, w4.BUTTON_1)) {
                    // Reads NETPLAY once, at confirm, to decide which board
                    // is "mine" (GAMEPAD1 always drives `player` regardless).
                    game_modes.applyDefaultProfile();
                    const netplay = w4.NETPLAY.*;
                    const my_slot = netplay & w4.NETPLAY_PLAYER_MASK;
                    s.versus_render_swapped = (netplay & w4.NETPLAY_ACTIVE != 0) and my_slot == 1;
                    board.beginCountdown();
                }
            },
            .setup_character => {
                render.drawSetupCharacterScreen();
                if (s.setup_flash_timer > 0) {
                    // Confirmed -- let the flash play out, then: quick mode
                    // reveals a rolled CPU pick; story skips to tier select.
                    s.setup_flash_timer -= 1;
                    if (s.setup_flash_timer == 0) {
                        switch (s.game_mode) {
                            .quick => {
                                s.cpu_character = characters.cpuPickFor(s.player_character, s.player.rngNext());
                                s.cpu_reveal_tick = 0;
                                s.cpu_reveal_timer = c.CPU_REVEAL_HOLD_BASE;
                                s.menu_phase = .setup_cpu_reveal;
                            },
                            .story => {
                                s.story_stage = 0;
                                s.story_game_overs = 0;
                                s.cpu_character = game_modes.storyOpponentFor(0);
                                s.menu_phase = .story_tier_select;
                            },
                            // Neither ever reaches setup_character (see mode_select above).
                            .tutorial, .versus => unreachable,
                        }
                    }
                } else {
                    if (input.justPressed(gp, s.prev_gamepad, w4.BUTTON_LEFT)) {
                        s.player_character = (s.player_character + characters.COUNT - 1) % characters.COUNT;
                    }
                    if (input.justPressed(gp, s.prev_gamepad, w4.BUTTON_RIGHT)) {
                        s.player_character = (s.player_character + 1) % characters.COUNT;
                    }
                    if (input.justPressed(gp, s.prev_gamepad, w4.BUTTON_1)) s.setup_flash_timer = c.SETUP_FLASH_TOTAL_FRAMES;
                }
            },
            .setup_cpu_reveal => {
                render.drawSetupCpuRevealScreen();
                // No input here -- the spin always plays out in full (see
                // state.cpu_reveal_tick/cpu_reveal_timer) before moving on.
                s.cpu_reveal_timer -= 1;
                if (s.cpu_reveal_timer == 0) {
                    s.cpu_reveal_tick += 1;
                    if (s.cpu_reveal_tick >= c.CPU_REVEAL_STEPS) {
                        s.menu_phase = .setup_difficulty;
                    } else {
                        s.cpu_reveal_timer = c.CPU_REVEAL_HOLD_BASE + s.cpu_reveal_tick * c.CPU_REVEAL_HOLD_GROWTH;
                    }
                }
            },
            .setup_difficulty => {
                render.drawSetupDifficultyScreen();
                // Fixed for the whole series; revisitable only once a
                // series concludes and this screen comes back around.
                if (input.justPressed(gp, s.prev_gamepad, w4.BUTTON_LEFT) and s.difficulty > 1) s.difficulty -= 1;
                if (input.justPressed(gp, s.prev_gamepad, w4.BUTTON_RIGHT) and s.difficulty < 10) s.difficulty += 1;
                if (input.justPressed(gp, s.prev_gamepad, w4.BUTTON_1)) {
                    // Guarantees a clean baseline even if a story run earlier
                    // this session left its own tier's profile active.
                    game_modes.applyDefaultProfile();
                    board.beginCountdown();
                }
            },
            .story_tier_select => {
                render.drawStoryTierScreen();
                // X Hard is a secret combo: hold left then press Z while on
                // Hard within the grace window; a plain tap commits to Medium.
                if (s.story_tier == .xhard) {
                    if (input.justPressed(gp, s.prev_gamepad, w4.BUTTON_LEFT)) s.story_tier = .hard;
                } else if (s.story_tier == .hard) {
                    if (input.justPressed(gp, s.prev_gamepad, w4.BUTTON_LEFT)) s.story_left_grace_timer = c.STORY_SECRET_GRACE_FRAMES;
                    if (s.story_left_grace_timer > 0) {
                        if (gp & w4.BUTTON_LEFT == 0) {
                            // Released before Z ever joined -- an ordinary tap.
                            s.story_tier = .medium;
                            s.story_left_grace_timer = 0;
                        } else if (input.justPressed(gp, s.prev_gamepad, w4.BUTTON_2)) {
                            s.story_tier = .xhard;
                            s.story_left_grace_timer = 0;
                        } else {
                            s.story_left_grace_timer -= 1;
                            if (s.story_left_grace_timer == 0) s.story_tier = .medium; // grace ran out, no Z -- ordinary tap
                        }
                    }
                } else if (input.justPressed(gp, s.prev_gamepad, w4.BUTTON_LEFT)) {
                    s.story_tier = switch (s.story_tier) {
                        .easy => .easy,
                        .medium => .easy,
                        .hard, .xhard => unreachable, // handled above
                    };
                } else if (input.justPressed(gp, s.prev_gamepad, w4.BUTTON_RIGHT)) {
                    s.story_tier = switch (s.story_tier) {
                        .easy => .medium,
                        .medium => .hard,
                        .hard, .xhard => unreachable, // handled above
                    };
                }
                if (input.justPressed(gp, s.prev_gamepad, w4.BUTTON_1)) {
                    game_modes.applyStoryProfile(s.story_tier);
                    s.difficulty = game_modes.storyDifficultyFor(s.story_tier, s.story_stage);
                    board.beginCountdown();
                }
            },
        }
        s.prev_gamepad = gp;
        s.cpu_prev_gamepad = gp2;
        return;
    }

    if (s.winner == .none) {
        input.updateCursorMovement(&s.player, &s.held_dir, &s.das_counter, &s.cursor_idle_frames, gp);
        input.updateSwap(&s.player, &s.button_pending_swap, gp, s.prev_gamepad);
        // Checked every held frame; tryManualRaise's own no-op while
        // cooling down or mid-raise handles debouncing, so this needs none.
        if (gp & w4.BUTTON_2 != 0) board.tryManualRaise(&s.player);
        input.updateTouch();
        // GAMEPAD1/GAMEPAD2 always drive player/cpu regardless of netplay
        // slot; only rendering swaps, keeping sim order identical for sync.
        if (s.game_mode == .versus) {
            input.updateCursorMovement(&s.cpu, &s.cpu_held_dir, &s.cpu_das_counter, &s.cpu_cursor_idle_frames, gp2);
            input.updateSwap(&s.cpu, &s.cpu_button_pending_swap, gp2, s.cpu_prev_gamepad);
            if (gp2 & w4.BUTTON_2 != 0) board.tryManualRaise(&s.cpu);
        } else {
            cpu_ai.update(&s.cpu);
        }

        sim.simulate(&s.player, &s.cpu);
        sim.simulate(&s.cpu, &s.player);
        // Hands off concluded chain garbage to the other board's incoming
        // queue, then drains it once idle -- never lands mid-resolve.
        garbage.resolveChainEnd(&s.player, &s.cpu);
        garbage.resolveChainEnd(&s.cpu, &s.player);
        garbage.releaseIncomingGarbage(&s.player);
        garbage.releaseIncomingGarbage(&s.cpu);
        board.updateRise(&s.player);
        board.updateRise(&s.cpu);
        board.updateDangerTimer(&s.player);
        board.updateDangerTimer(&s.cpu);

        if (s.player.game_over and s.cpu.game_over) {
            s.winner = .draw;
        } else if (s.player.game_over) {
            s.winner = .cpu;
        } else if (s.cpu.game_over) {
            s.winner = .player;
        }
        if (s.winner != .none and !was_over) {
            audio.playGameOverSound();
            board.beginClosing();
            // Story mode plays single-game stages, not a best-of-N series;
            // awarding a point here would spuriously trip set_winner.
            if (s.game_mode != .story) board.awardMatchPoint(s.winner);
        }
    } else if (s.closing_timer > 0) {
        // Ticked down before input handling so render.render() below can
        // use the updated value the same frame.
        s.closing_timer -= 1;
    } else {
        if (input.justPressed(gp, s.prev_gamepad, w4.BUTTON_1)) {
            switch (s.game_mode) {
                .story => {
                    if (s.winner == .player) {
                        s.story_stage += 1;
                        if (s.story_stage >= game_modes.STORY_STAGES) {
                            // Whole run cleared: reveal the X Hard hint if
                            // earned, then back to mode select.
                            game_modes.maybeRevealXhard(s.story_tier, s.story_game_overs);
                            s.menu_phase = .mode_select;
                            s.started = false;
                        } else {
                            s.cpu_character = game_modes.storyOpponentFor(s.story_stage);
                            s.difficulty = game_modes.storyDifficultyFor(s.story_tier, s.story_stage);
                            board.beginCountdown();
                        }
                    } else {
                        // Lost/drew the stage: tally game_overs and retry
                        // the SAME stage, never restarting the whole run.
                        s.story_game_overs += 1;
                        board.beginCountdown();
                    }
                },
                .quick, .versus => {
                    if (s.set_winner != .none) {
                        // Series decided: back to mode select instead of
                        // another countdown, with series state reset.
                        s.player_points = 0;
                        s.cpu_points = 0;
                        s.set_winner = .none;
                        s.menu_phase = .mode_select;
                        s.started = false;
                    } else {
                        board.beginCountdown();
                    }
                },
                // Tutorial never sets s.winner -- it exits via its own
                // early-return branch in update(), never reaching here.
                .tutorial => unreachable,
            }
            s.winner = .none;
        }
    }

    render.render();
    if (s.winner != .none and s.closing_timer <= 0) render.drawGameOver();

    s.prev_gamepad = gp;
    s.cpu_prev_gamepad = gp2;
}
