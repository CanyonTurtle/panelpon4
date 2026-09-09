const builtin = @import("builtin");
const w4 = @import("wasm4.zig");
const c = @import("constants.zig");
const s = @import("state.zig");
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

// mode_select's own left/right cycling order (quick -> story -> versus ->
// wraps back to quick).
fn prevMode(m: s.GameMode) s.GameMode {
    return switch (m) {
        .quick => .versus,
        .story => .quick,
        .versus => .story,
    };
}
fn nextMode(m: s.GameMode) s.GameMode {
    return switch (m) {
        .quick => .story,
        .story => .versus,
        .versus => .quick,
    };
}

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
    board.resetSharedRows();
    board.resetGame(&s.player);
    board.resetGame(&s.cpu);
    game_modes.loadSave();
}

export fn update() void {
    s.frame_count += 1;
    const gp = w4.GAMEPAD1.*;
    const was_over = s.winner != .none;
    // Any gamepad button (a direction or X) brings the cursor back -- see
    // state.cursor_hidden and input.updateTouch, which hides it the instant
    // touch starts.
    if (gp != 0) s.cursor_hidden = false;

    // The "3 2 1 START" countdown, right after board.beginCountdown resets
    // both boards -- freezes input/simulation entirely and just renders the
    // already-reset boards underneath the overlay (render.render() reads
    // board state only, so this is a perfectly valid "about to start" frame
    // to sit on for a few seconds) until it counts down to 0.
    if (s.countdown_timer > 0) {
        s.countdown_timer -= 1;
        render.render();
        render.drawCountdown();
        if (s.countdown_timer <= 0) s.started = true;
        s.prev_gamepad = gp;
        return;
    }

    if (!s.started) {
        _ = s.player.rngNext();
        board.perturbSharedRng();
        switch (s.menu_phase) {
            .title => {
                render.drawTitleScreen();
                if (input.justPressed(gp, w4.BUTTON_1)) s.menu_phase = .mode_select;
            },
            .mode_select => {
                render.drawModeSelectScreen();
                if (input.justPressed(gp, w4.BUTTON_LEFT)) s.game_mode = prevMode(s.game_mode);
                if (input.justPressed(gp, w4.BUTTON_RIGHT)) s.game_mode = nextMode(s.game_mode);
                if (input.justPressed(gp, w4.BUTTON_1)) {
                    switch (s.game_mode) {
                        .quick, .story => s.menu_phase = .setup_character,
                        .versus => {
                            // No character/difficulty picking for versus --
                            // the opponent is a real second player, not a
                            // rolled or ramped CPU (see state.GameMode's own
                            // doc comment). Figure out once, right now,
                            // whether *this* peer's own real input is
                            // GAMEPAD2 (see wasm4.NETPLAY) -- if so, this
                            // peer needs to see itself in the main seat by
                            // swapping which board render.render() treats as
                            // "mine", since GAMEPAD1 always drives `player`
                            // and GAMEPAD2 always drives `cpu` regardless of
                            // slot (see the in-match input routing below).
                            game_modes.applyDefaultProfile();
                            const netplay = w4.NETPLAY.*;
                            const my_slot = netplay & w4.NETPLAY_PLAYER_MASK;
                            s.versus_render_swapped = (netplay & w4.NETPLAY_ACTIVE != 0) and my_slot == 1;
                            board.beginCountdown();
                        },
                    }
                }
            },
            .setup_character => {
                render.drawSetupCharacterScreen();
                if (s.setup_flash_timer > 0) {
                    // Confirmed -- ignore input and just let the flash play
                    // out (see render.drawSetupCharacterScreen) until it's
                    // done, then move on: quick match rolls the CPU's own
                    // pick (see characters.cpuPickFor) and watches it
                    // reveal; story mode's opponents are predetermined (see
                    // game_modes.storyOpponentFor), so it skips the reveal
                    // screen entirely and goes straight to picking a tier.
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
                            .versus => unreachable, // versus never reaches setup_character (see mode_select above)
                        }
                    }
                } else {
                    // Left/right cycles the player's own character -- a
                    // horizontal row reads more naturally with left/right
                    // than up/down did.
                    if (input.justPressed(gp, w4.BUTTON_LEFT)) {
                        s.player_character = (s.player_character + characters.COUNT - 1) % characters.COUNT;
                    }
                    if (input.justPressed(gp, w4.BUTTON_RIGHT)) {
                        s.player_character = (s.player_character + 1) % characters.COUNT;
                    }
                    if (input.justPressed(gp, w4.BUTTON_1)) s.setup_flash_timer = c.SETUP_FLASH_TOTAL_FRAMES;
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
                // Sets the CPU's difficulty for the whole series (see
                // state.difficulty and cpu_ai.configFor) -- revisitable here
                // again once a series concludes and this screen comes back
                // around, but fixed for the whole series in between.
                if (input.justPressed(gp, w4.BUTTON_LEFT) and s.difficulty > 1) s.difficulty -= 1;
                if (input.justPressed(gp, w4.BUTTON_RIGHT) and s.difficulty < 10) s.difficulty += 1;
                if (input.justPressed(gp, w4.BUTTON_1)) {
                    // Guarantees a clean baseline even if a story run earlier
                    // this session left its own tier's profile active (see
                    // game_modes.zig's own doc comment).
                    game_modes.applyDefaultProfile();
                    board.beginCountdown();
                }
            },
            .story_tier_select => {
                render.drawStoryTierScreen();
                // "By tradition", X Hard is never reachable by plain
                // left/right cycling (see state.StoryTier's own doc
                // comment) -- only by holding left and then pressing the
                // swap button while sitting on Hard. A fresh left-press on
                // Hard can't yet tell "just an ordinary tap toward Medium"
                // apart from "the start of that secret combo" -- committing
                // to Medium immediately (the first version of this did) means
                // the very press that was *supposed* to lead into the combo
                // already consumed itself into Medium before Z ever has a
                // chance to join, so the combo could never actually fire.
                // Instead this waits up to STORY_SECRET_GRACE_FRAMES for Z to
                // join (see state.story_left_grace_timer), committing early
                // the instant left is released without Z ever joining (so an
                // ordinary quick tap still feels instant) or once the grace
                // window itself runs out. Left from X Hard steps back out of
                // it to Hard immediately, same as arriving there -- no such
                // ambiguity going that direction.
                if (s.story_tier == .xhard) {
                    if (input.justPressed(gp, w4.BUTTON_LEFT)) s.story_tier = .hard;
                } else if (s.story_tier == .hard) {
                    if (input.justPressed(gp, w4.BUTTON_LEFT)) s.story_left_grace_timer = c.STORY_SECRET_GRACE_FRAMES;
                    if (s.story_left_grace_timer > 0) {
                        if (gp & w4.BUTTON_LEFT == 0) {
                            // Released before Z ever joined -- an ordinary tap.
                            s.story_tier = .medium;
                            s.story_left_grace_timer = 0;
                        } else if (input.justPressed(gp, w4.BUTTON_2)) {
                            s.story_tier = .xhard;
                            s.story_left_grace_timer = 0;
                        } else {
                            s.story_left_grace_timer -= 1;
                            if (s.story_left_grace_timer == 0) s.story_tier = .medium; // grace ran out, no Z -- ordinary tap
                        }
                    }
                } else if (input.justPressed(gp, w4.BUTTON_LEFT)) {
                    s.story_tier = switch (s.story_tier) {
                        .easy => .easy,
                        .medium => .easy,
                        .hard, .xhard => unreachable, // handled above
                    };
                } else if (input.justPressed(gp, w4.BUTTON_RIGHT)) {
                    s.story_tier = switch (s.story_tier) {
                        .easy => .medium,
                        .medium => .hard,
                        .hard, .xhard => unreachable, // handled above
                    };
                }
                if (input.justPressed(gp, w4.BUTTON_1)) {
                    game_modes.applyStoryProfile(s.story_tier);
                    s.difficulty = game_modes.storyDifficultyFor(s.story_tier, s.story_stage);
                    board.beginCountdown();
                }
            },
        }
        s.prev_gamepad = gp;
        return;
    }

    if (s.winner == .none) {
        input.updateCursorMovement(&s.player, &s.held_dir, &s.das_counter, &s.cursor_idle_frames, gp);
        input.updateSwap(&s.player, &s.button_pending_swap, gp);
        // Held (not just a fresh press) so the raise keeps going for as long
        // as Z stays down -- tryManualRaise already no-ops on its own while
        // still cooling down or mid-raise, so calling it every held frame
        // just means the next raise kicks off itself the instant it's
        // actually allowed to, with no extra debouncing needed here.
        if (gp & w4.BUTTON_2 != 0) board.tryManualRaise(&s.player);
        input.updateTouch();
        // Versus mode's `cpu` board is a real second player on GAMEPAD2 (see
        // state.GameMode), driven through the exact same input functions as
        // the player's own -- GAMEPAD1 always drives `player` and GAMEPAD2
        // always drives `cpu` regardless of which netplay slot is "mine"
        // (see mode_select's own versus branch above, which decides the
        // *rendering* swap instead -- this keeps the simulate/resolve/
        // release/rise call order below byte-for-byte identical on every
        // peer, which is what actually has to stay in sync for netplay).
        // Every other mode still hands `cpu` to the AI as always.
        if (s.game_mode == .versus) {
            const gp2 = w4.GAMEPAD2.*;
            input.updateCursorMovement(&s.cpu, &s.cpu_held_dir, &s.cpu_das_counter, &s.cpu_cursor_idle_frames, gp2);
            input.updateSwap(&s.cpu, &s.cpu_button_pending_swap, gp2);
            if (gp2 & w4.BUTTON_2 != 0) board.tryManualRaise(&s.cpu);
        } else {
            cpu_ai.update(&s.cpu);
        }

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
        if (s.winner != .none and !was_over) {
            audio.playGameOverSound();
            board.beginClosing();
            // Story mode plays single-game stages, not a best-of-N series --
            // see the game-over handling below, which advances/retries a
            // stage directly off `s.winner` instead. Awarding a point here
            // too would let a long run spuriously trip set_winner (the
            // best-of-POINTS_TO_WIN series-decided flag) with nothing ever
            // around to consume/reset it.
            if (s.game_mode != .story) board.awardMatchPoint(s.winner);
        }
    } else if (s.closing_timer > 0) {
        // The closing wipe (state.closing_timer) is ticked down here, before
        // any input handling -- render.render() below reads it to decide how
        // many rows to skip drawing (see render.closingWipedRows) -- so the
        // "PRESS X" restart below only ever becomes reachable once every row
        // has actually finished popping.
        s.closing_timer -= 1;
    } else {
        if (input.justPressed(gp, w4.BUTTON_1)) {
            switch (s.game_mode) {
                .story => {
                    if (s.winner == .player) {
                        s.story_stage += 1;
                        if (s.story_stage >= game_modes.STORY_STAGES) {
                            // The whole run just cleared -- see game_modes.
                            // maybeRevealXhard for the one-time hint this can
                            // earn, then back to picking a mode (not all the
                            // way to the title splash).
                            game_modes.maybeRevealXhard(s.story_tier, s.story_game_overs);
                            s.menu_phase = .mode_select;
                            s.started = false;
                        } else {
                            s.cpu_character = game_modes.storyOpponentFor(s.story_stage);
                            s.difficulty = game_modes.storyDifficultyFor(s.story_tier, s.story_stage);
                            board.beginCountdown();
                        }
                    } else {
                        // Lost (or drew) this stage -- tallies toward this
                        // run's own game-over count (see state.
                        // story_game_overs) and retries the SAME stage,
                        // never restarting the whole run from stage 1.
                        s.story_game_overs += 1;
                        board.beginCountdown();
                    }
                },
                .quick, .versus => {
                    if (s.set_winner != .none) {
                        // The series itself is decided -- back to picking a
                        // mode (see state.menu_phase) rather than straight
                        // into another countdown, with the whole series'
                        // state reset.
                        s.player_points = 0;
                        s.cpu_points = 0;
                        s.set_winner = .none;
                        s.menu_phase = .mode_select;
                        s.started = false;
                    } else {
                        board.beginCountdown();
                    }
                },
            }
            s.winner = .none;
        }
    }

    render.render();
    if (s.winner != .none and s.closing_timer <= 0) render.drawGameOver();

    s.prev_gamepad = gp;
}
