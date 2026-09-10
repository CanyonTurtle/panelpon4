// A scripted walkthrough on `state.player`; `state.cpu` stays idle except
// to receive demo garbage. Each step seeds a layout, advances on its own action or X.

const std = @import("std");
const w4 = @import("wasm4.zig");
const c = @import("constants.zig");
const s = @import("state.zig");
const input = @import("input.zig");
const sim = @import("sim.zig");
const board = @import("board.zig");
const garbage = @import("sim_garbage.zig");

const no_settled: [c.ROWS][c.COLS]bool = std.mem.zeroes([c.ROWS][c.COLS]bool);

const Lines = struct { line1: []const u8, line2: []const u8 };

fn lines(step: s.TutorialStep) Lines {
    return switch (step) {
        .intro => .{ .line1 = "WELCOME TO PANELPON4", .line2 = "PRESS X TO BEGIN" },
        .move => .{ .line1 = "ARROWS MOVE CURSOR", .line2 = "MOVE, THEN PRESS X" },
        .swap => .{ .line1 = "X SWAPS TWO BLOCKS", .line2 = "TRY IT, THEN PRESS X" },
        .match => .{ .line1 = "MATCH 3 IN A ROW", .line2 = "OR COLUMN TO CLEAR" },
        .chain => .{ .line1 = "CHAIN MATCHES FOR", .line2 = "BONUS POINTS! TRY X" },
        .garbage => .{ .line1 = "GARBAGE BLOCKS ARE", .line2 = "INERT. MATCH NEARBY" },
        .raise => .{ .line1 = "Z RAISES YOUR STACK", .line2 = "TRY PRESSING Z" },
        .outro => .{ .line1 = "YOU'RE READY TO PLAY", .line2 = "PRESS X TO FINISH" },
    };
}

pub fn captionLines() Lines {
    return lines(s.tutorial_step);
}

pub const STEP_COUNT: u8 = 8;

pub fn stepNumber() u8 {
    return @as(u8, @intFromEnum(s.tutorial_step)) + 1;
}

fn nextStep(step: s.TutorialStep) ?s.TutorialStep {
    return switch (step) {
        .intro => .move,
        .move => .swap,
        .swap => .match,
        .match => .chain,
        .chain => .garbage,
        .garbage => .raise,
        .raise => .outro,
        .outro => null,
    };
}

// Whether the step's own taught action has happened yet, independent of the
// always-available X-press skip.
fn actionDone(step: s.TutorialStep) bool {
    return switch (step) {
        .move => s.player.cursor_col != s.tutorial_step_start_col or s.player.cursor_row != s.tutorial_step_start_row,
        .match, .chain, .garbage => s.player.score > 0,
        .raise => s.player.manual_raise_elapsed > 0,
        .intro, .swap, .outro => false,
    };
}

// Cells use the same absolute logical rows as sim_test.zig/cpu_engine_test.zig's
// own known-good fixtures -- cursor_row/col are visible-relative (0 = ceiling).
fn seedStep(step: s.TutorialStep) void {
    switch (step) {
        .intro, .move, .outro, .raise => {},
        .swap => {
            s.player.cursor_row = 6;
            s.player.cursor_col = 2;
            s.player.cellAt(6 + c.SPAWN_ROWS, 2).* = .{ .color = 0, .state = .normal };
            s.player.cellAt(6 + c.SPAWN_ROWS, 3).* = .{ .color = 1, .state = .normal };
        },
        .match => {
            s.player.cursor_row = 6;
            s.player.cursor_col = 2;
            s.player.cellAt(6 + c.SPAWN_ROWS, 0).* = .{ .color = 1, .state = .normal };
            s.player.cellAt(6 + c.SPAWN_ROWS, 1).* = .{ .color = 1, .state = .normal };
            s.player.cellAt(6 + c.SPAWN_ROWS, 2).* = .{ .color = 2, .state = .normal };
            s.player.cellAt(6 + c.SPAWN_ROWS, 3).* = .{ .color = 1, .state = .normal };
        },
        .chain => {
            // The exact "sets off a 2-deep chain" fixture from cpu_engine_test.zig;
            // the cursor already sits on the one winning swap.
            s.player.cursor_row = 10;
            s.player.cursor_col = 2;
            s.player.cellAt(18, 0).* = .{ .color = 3, .state = .normal };
            s.player.cellAt(19, 0).* = .{ .color = 3, .state = .normal };
            s.player.cellAt(20, 0).* = .{ .color = 0, .state = .normal };
            s.player.cellAt(21, 0).* = .{ .color = 3, .state = .normal };
            s.player.cellAt(20, 1).* = .{ .color = 0, .state = .normal };
            s.player.cellAt(21, 1).* = .{ .color = 4, .state = .normal };
            s.player.cellAt(20, 2).* = .{ .color = 2, .state = .normal };
            s.player.cellAt(21, 2).* = .{ .color = 1, .state = .normal };
            s.player.cellAt(20, 3).* = .{ .color = 0, .state = .normal };
            s.player.cellAt(21, 3).* = .{ .color = 4, .state = .normal };
        },
        .garbage => {
            // Already a complete match -- pops on its own, pulling the
            // touching garbage cell into recycling, without needing a swap.
            s.player.cellAt(6 + c.SPAWN_ROWS, 0).* = .{ .color = 1, .state = .normal };
            s.player.cellAt(6 + c.SPAWN_ROWS, 1).* = .{ .color = 1, .state = .normal };
            s.player.cellAt(6 + c.SPAWN_ROWS, 2).* = .{ .color = 1, .state = .normal };
            s.player.cellAt(6 + c.SPAWN_ROWS, 3).* = .{ .state = .normal, .is_garbage = true };
            _ = sim.checkMatches(&s.player, &s.cpu, no_settled);
        },
    }
}

pub fn begin() void {
    s.player = s.Board{};
    s.cpu = s.Board{ .rng_state = s.CPU_RNG_SEED };
    s.tutorial_step = .intro;
    s.tutorial_step_start_col = s.player.cursor_col;
    s.tutorial_step_start_row = s.player.cursor_row;
}

// Returns true the one frame the tutorial is finished (outro's X press).
pub fn update(gp: u8, prev_gp: u8) bool {
    input.updateCursorMovement(&s.player, &s.held_dir, &s.das_counter, &s.cursor_idle_frames, gp);
    input.updateSwap(&s.player, &s.button_pending_swap, gp, prev_gp);
    if (gp & w4.BUTTON_2 != 0) board.tryManualRaise(&s.player);
    input.updateTouch();
    sim.simulate(&s.player, &s.cpu);
    garbage.resolveChainEnd(&s.player, &s.cpu);
    garbage.releaseIncomingGarbage(&s.cpu);

    if (!(actionDone(s.tutorial_step) or input.justPressed(gp, prev_gp, w4.BUTTON_1))) return false;

    const next = nextStep(s.tutorial_step) orelse return true;
    s.player = s.Board{};
    s.tutorial_step = next;
    s.tutorial_step_start_col = s.player.cursor_col;
    s.tutorial_step_start_row = s.player.cursor_row;
    seedStep(next);
    return false;
}
