// A scripted walkthrough on `state.player`. X only ever means "continue
// past dialogue", never "skip" -- most steps require several reps.

const std = @import("std");
const w4 = @import("wasm4.zig");
const c = @import("constants.zig");
const s = @import("state.zig");
const input = @import("input.zig");
const sim = @import("sim.zig");
const board = @import("board.zig");
const garbage = @import("sim_garbage.zig");

const Lines = struct { line1: []const u8, line2: []const u8 };

pub const STEP_COUNT: u8 = 9;

pub fn stepNumber() u8 {
    return @as(u8, @intFromEnum(s.tutorial_step)) + 1;
}

fn target(step: s.TutorialStep) u8 {
    return switch (step) {
        .intro, .outro, .chain, .combo => 1,
        .move => 6,
        .swap => 3,
        .match => 3,
        .garbage => 2,
        .raise => 3,
    };
}

fn progressWord(step: s.TutorialStep) []const u8 {
    return switch (step) {
        .move => "MOVES",
        .swap => "SWAPS",
        .match => "MATCHES",
        .garbage => "CLEARS",
        .raise => "RAISES",
        .intro, .chain, .combo, .outro => "",
    };
}

// line1 shares its row with the top-right "N/9" counter, so it must stay
// well under ~15 chars -- line2 has the full-width row to itself.
pub fn captionLines(buf: []u8) Lines {
    // Overrides both lines for a beat after a wrong-but-scoring move (see
    // triggerRetry) -- the fixture's already been reseeded by the time this shows.
    if (retry_flash_timer > 0) return .{ .line1 = "NOT QUITE!", .line2 = "TRY AGAIN" };
    const step = s.tutorial_step;
    const line1: []const u8 = switch (step) {
        .intro => "LET'S LEARN!",
        .move => "USE ARROW KEYS",
        .swap => "X SWAPS BLOCKS",
        .match => "MATCH 3 BLOCKS",
        .combo => "MATCH 4 BLOCKS",
        .chain => "SETUP A CHAIN",
        .garbage => "CLEAR GARBAGE",
        .raise => "Z RAISES STACK",
        .outro => "YOU'RE READY!",
    };
    const line2: []const u8 = switch (step) {
        .intro => "PRESS X TO BEGIN",
        .outro => "PRESS X TO FINISH",
        .combo, .chain => "TRIGGER IT! (X)",
        else => std.fmt.bufPrint(buf, "{d} / {d} {s}", .{ progress, target(step), progressWord(step) }) catch "",
    };
    return .{ .line1 = line1, .line2 = line2 };
}

fn nextStep(step: s.TutorialStep) ?s.TutorialStep {
    return switch (step) {
        .intro => .move,
        .move => .swap,
        .swap => .match,
        .match => .combo,
        .combo => .chain,
        .chain => .garbage,
        .garbage => .raise,
        .raise => .outro,
        .outro => null,
    };
}

// Alternates between two filler colors both by row and by column, so no
// straight run of 3 is ever possible in the floor itself.
fn floorColor(row: u8, col: u8) u8 {
    return if ((row + col) % 2 == 0) 3 else 4;
}

fn fillFloor(cols: []const u8, from_row: u8, to_row: u8) void {
    for (cols) |col| {
        var row = from_row;
        while (row <= to_row) : (row += 1) {
            s.player.cellAt(row, col).* = .{ .color = floorColor(row, col), .state = .normal };
        }
    }
}

fn seedSwap() void {
    fillFloor(&.{ 2, 3 }, 17, 22);
    s.player.cellAt(16, 2).* = .{ .color = 0, .state = .normal };
    s.player.cellAt(16, 3).* = .{ .color = 1, .state = .normal };
}

// Swapping cols 2/3 completes a run of three 1's at cols 0-2.
fn seedMatch() void {
    fillFloor(&.{ 0, 1, 2, 3 }, 17, 22);
    s.player.cellAt(16, 0).* = .{ .color = 1, .state = .normal };
    s.player.cellAt(16, 1).* = .{ .color = 1, .state = .normal };
    s.player.cellAt(16, 2).* = .{ .color = 2, .state = .normal };
    s.player.cellAt(16, 3).* = .{ .color = 1, .state = .normal };
}

// Same match as above, plus a full-width garbage row dropped from the very
// top of the visible board -- gravity carries it down onto row 16's match setup, visibly falling into place.
fn seedGarbage() void {
    seedMatch();
    for (0..c.COLS) |col| {
        s.player.cellAt(c.SPAWN_ROWS, @intCast(col)).* = .{ .state = .normal, .is_garbage = true };
    }
}

// Match detection only pulls in cells that are themselves part of a genuine
// 3+ run, not just color-adjacent neighbors -- swapping cols 3/4 completes a real run of four 1's at cols 0-3.
fn seedCombo() void {
    fillFloor(&.{ 0, 1, 2, 3, 4 }, 17, 22);
    s.player.cellAt(16, 0).* = .{ .color = 1, .state = .normal };
    s.player.cellAt(16, 1).* = .{ .color = 1, .state = .normal };
    s.player.cellAt(16, 2).* = .{ .color = 1, .state = .normal };
    s.player.cellAt(16, 3).* = .{ .color = 2, .state = .normal };
    s.player.cellAt(16, 4).* = .{ .color = 1, .state = .normal };
}

// The known-good "sets off a 2-deep chain" fixture from cpu_engine_test.zig;
// the cursor already sits on the one winning swap.
fn seedChain() void {
    fillFloor(&.{ 0, 1, 2, 3 }, 22, 22);
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
}

// A tall filler stack so the first Z press visibly shifts something -- an
// empty board has nothing to show moving. Rows 10-14 stay clear as headroom.
fn seedRaise() void {
    fillFloor(&.{ 0, 1, 2, 3, 4, 5 }, 15, 22);
}

// Only real matched blocks ever carry is_garbage, so a raw scan is exact --
// used to confirm the garbage step's swap actually cleared some, not just scored.
fn countGarbage() u8 {
    var n: u8 = 0;
    for (0..c.ROWS) |lr| {
        for (0..c.COLS) |col| {
            if (s.player.cellAt(@intCast(lr), @intCast(col)).is_garbage) n += 1;
        }
    }
    return n;
}

// Cursor position and cell layout for a step's first entry. Repeats within
// a step (match/combo/chain/garbage) call the matching seed*() directly instead.
fn seedStep(step: s.TutorialStep) void {
    switch (step) {
        .intro, .move, .outro => {},
        .raise => seedRaise(),
        .swap => {
            s.player.cursor_row = 6;
            s.player.cursor_col = 2;
            seedSwap();
        },
        .match => {
            s.player.cursor_row = 6;
            s.player.cursor_col = 2;
            seedMatch();
        },
        .combo => {
            s.player.cursor_row = 6;
            s.player.cursor_col = 3;
            seedCombo();
        },
        .chain => {
            s.player.cursor_row = 10;
            s.player.cursor_col = 2;
            seedChain();
        },
        .garbage => {
            s.player.cursor_row = 6;
            s.player.cursor_col = 2;
            seedGarbage();
        },
    }
}

var progress: u8 = 0;
var last_col: u8 = 0;
var last_row: u8 = 0;
var last_score: u32 = 0;
var last_raise_elapsed: u32 = 0;
// Peak chain/combo size seen since the last reseed -- both sim fields go
// stale before this step's own boardBusy() check, so update() samples them every frame instead.
var max_chain_seen: u8 = 0;
var max_combo_seen: u8 = 0;
var last_garbage_count: u8 = 0;
// Nonzero for a short "NOT QUITE! / TRY AGAIN" caption flash (captionLines)
// after a move that scored but didn't demonstrate this step's own lesson.
const RETRY_FLASH_FRAMES: u16 = 75;
var retry_flash_timer: u16 = 0;

// pub: also used by debug.setTutorialStep, for scripted testing.
pub fn beginStep(step: s.TutorialStep) void {
    s.player = s.Board{};
    s.tutorial_step = step;
    progress = 0;
    last_col = s.player.cursor_col;
    last_row = s.player.cursor_row;
    last_score = 0;
    last_raise_elapsed = 0;
    max_chain_seen = 0;
    max_combo_seen = 0;
    retry_flash_timer = 0;
    seedStep(step);
    last_garbage_count = countGarbage();
}

pub fn begin() void {
    s.cpu = s.Board{ .rng_state = s.CPU_RNG_SEED };
    beginStep(.intro);
}

// Flashes "NOT QUITE! / TRY AGAIN" -- the caller still reseeds the fixture
// right after this, same as a successful rep would.
fn triggerRetry() void {
    retry_flash_timer = RETRY_FLASH_FRAMES;
}

// Returns true the one frame the tutorial is finished (outro's X press).
fn advance() bool {
    const next = nextStep(s.tutorial_step) orelse return true;
    beginStep(next);
    return false;
}

// Returns true the one frame the tutorial is finished.
pub fn update(gp: u8, prev_gp: u8) bool {
    const step = s.tutorial_step;
    if (step == .intro) {
        return if (input.justPressed(gp, prev_gp, w4.BUTTON_1)) advance() else false;
    }

    if (retry_flash_timer > 0) retry_flash_timer -= 1;

    const will_swap = input.justPressed(gp, prev_gp, w4.BUTTON_1) and
        input.canSwapAt(&s.player, s.player.cursor_row, s.player.cursor_col);
    input.updateCursorMovement(&s.player, &s.held_dir, &s.das_counter, &s.cursor_idle_frames, gp);
    input.updateSwap(&s.player, &s.button_pending_swap, gp, prev_gp);
    input.updateTouch();
    // Manual raise only actually does anything during its own step -- an
    // early Z press elsewhere would shift `top` and break other fixtures.
    if (step == .raise) {
        if (gp & w4.BUTTON_2 != 0) board.tryManualRaise(&s.player);
        board.updateRise(&s.player);
    }
    sim.simulate(&s.player, &s.cpu);
    // Sampled every frame -- resolveChainEnd below zeroes `chain` the instant
    // the board goes idle, before this step's own check below would see it.
    if (step == .chain and s.player.chain > max_chain_seen) max_chain_seen = s.player.chain;
    if (step == .combo and s.player.combo_display_timer > 0 and s.player.combo_display > max_combo_seen) {
        max_combo_seen = s.player.combo_display;
    }
    garbage.resolveChainEnd(&s.player, &s.cpu);
    garbage.releaseIncomingGarbage(&s.cpu);

    switch (step) {
        .move => {
            if (s.player.cursor_col != last_col or s.player.cursor_row != last_row) {
                progress += 1;
                last_col = s.player.cursor_col;
                last_row = s.player.cursor_row;
            }
        },
        .swap => {
            if (will_swap) progress += 1;
        },
        .match => {
            // Waits for the whole event to settle (not just the frame score
            // first ticks up) -- any match at all clears this step.
            if (!s.player.boardBusy() and s.player.score > last_score) {
                last_score = s.player.score;
                progress += 1;
                if (progress < target(step)) seedMatch();
            }
        },
        .combo => {
            if (!s.player.boardBusy() and s.player.score > last_score) {
                last_score = s.player.score;
                // A plain 3-match scores too but isn't a combo (real_count > 3,
                // sim_matches_resolve.is_combo) -- retry rather than credit it.
                if (max_combo_seen > 3) progress += 1 else triggerRetry();
                max_combo_seen = 0;
                if (progress < target(step)) seedCombo();
            }
        },
        .chain => {
            if (!s.player.boardBusy() and s.player.score > last_score) {
                last_score = s.player.score;
                // chain == 1 just means "one match happened" -- a real
                // chain reaction needs a second step to have fired too.
                if (max_chain_seen > 1) progress += 1 else triggerRetry();
                max_chain_seen = 0;
                if (progress < target(step)) seedChain();
            }
        },
        .garbage => {
            if (!s.player.boardBusy() and s.player.score > last_score) {
                last_score = s.player.score;
                const now = countGarbage();
                if (now < last_garbage_count) progress += 1 else triggerRetry();
                last_garbage_count = now;
                if (progress < target(step)) {
                    seedGarbage();
                    last_garbage_count = countGarbage();
                }
            }
        },
        .raise => {
            // Rising edge (0 -> nonzero), not a specific value -- updateRise
            // above can already advance elapsed past 1 within this frame.
            if (s.player.manual_raise_elapsed > 0 and last_raise_elapsed == 0) progress += 1;
            last_raise_elapsed = s.player.manual_raise_elapsed;
        },
        .intro, .outro => {},
    }

    const done = if (step == .outro)
        input.justPressed(gp, prev_gp, w4.BUTTON_1)
    else
        progress >= target(step);
    return if (done) advance() else false;
}
