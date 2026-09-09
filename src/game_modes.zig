// The 3 top-level game modes (see state.game_mode, chosen on the mode-select
// screen right after the title): 1P story, 1P quick match, and 2P versus
// (local same-console 2-controller play, or remote via WASM-4's own netplay
// -- see main.zig, which is the only thing that differs between the two:
// this module and everything downstream of it doesn't know or care which).
//
// Also home to the difficulty-profile system that lets story mode retune
// "stack rise speed, pop delay, and top loss timer" per tier (see Profile/
// applyProfile) -- quick match and versus always run the untouched baseline
// (`.default`), so their feel is completely unchanged from before this
// module existed.

const builtin = @import("builtin");
const c = @import("constants.zig");
const w4 = @import("wasm4.zig");
const characters = @import("characters.zig");
const s = @import("state.zig");

// GameMode/StoryTier themselves live in state.zig (see s.GameMode/s.StoryTier)
// -- state.zig is the game's plain-data model layer, and every OTHER piece
// of per-match mode state (s.game_mode, s.story_tier, s.story_stage, s.
// story_game_overs) already lives there, so the enums those fields are typed
// as belong there too rather than splitting "the data" and "its own type"
// across two modules.
pub const StoryTier = s.StoryTier;

pub const STORY_STAGES: u8 = characters.COUNT;

// Story mode's own difficulty-profile knobs, applied to the shared runtime
// constants (see constants.zig's own doc comment on why POP_FRAMES etc. are
// `var`s) -- `rise_scale_pct` feeds constants.RISE_SPEED_SCALE_PCT directly;
// the rest are copied straight into their matching constants field.
const Profile = struct {
    rise_scale_pct: u32,
    pop_frames: i16,
    pre_pop_blink: i16,
    pre_pop_pause: i16,
    danger_forgiveness: u32,
};

// Exactly today's baseline values (see constants.zig's own defaults) --
// quick match and versus mode both run this, so neither one's feel changes
// even slightly just because this system exists.
const DEFAULT_PROFILE = Profile{
    .rise_scale_pct = 100,
    .pop_frames = 34,
    .pre_pop_blink = 24,
    .pre_pop_pause = 12,
    .danger_forgiveness = 60,
};

// Easier tiers get a slower rise, a longer pop/pre-pop delay (more time to
// actually read what just happened before it clears), and a longer top-loss
// forgiveness window; harder tiers compress all three. `xhard` pushes every
// knob well past `hard` rather than just repeating it -- it's meant to be a
// genuine step up, not a re-skin.
fn profileFor(tier: StoryTier) Profile {
    return switch (tier) {
        .easy => .{ .rise_scale_pct = 140, .pop_frames = 44, .pre_pop_blink = 30, .pre_pop_pause = 18, .danger_forgiveness = 90 },
        .medium => DEFAULT_PROFILE,
        .hard => .{ .rise_scale_pct = 75, .pop_frames = 26, .pre_pop_blink = 18, .pre_pop_pause = 8, .danger_forgiveness = 45 },
        .xhard => .{ .rise_scale_pct = 55, .pop_frames = 20, .pre_pop_blink = 12, .pre_pop_pause = 6, .danger_forgiveness = 30 },
    };
}

fn applyProfile(p: Profile) void {
    c.RISE_SPEED_SCALE_PCT = p.rise_scale_pct;
    c.POP_FRAMES = p.pop_frames;
    c.PRE_POP_BLINK_FRAMES = p.pre_pop_blink;
    c.PRE_POP_PAUSE_FRAMES = p.pre_pop_pause;
    c.PRE_POP_TOTAL_FRAMES = p.pre_pop_blink + p.pre_pop_pause;
    c.DANGER_FORGIVENESS_FRAMES = p.danger_forgiveness;
}

// Quick match (on confirming a difficulty) and versus (on confirming from
// the mode-select screen) both call this to guarantee a clean baseline --
// otherwise a story run earlier in the same session would leave its own
// tier's profile still active.
pub fn applyDefaultProfile() void {
    applyProfile(DEFAULT_PROFILE);
}

pub fn applyStoryProfile(tier: StoryTier) void {
    applyProfile(profileFor(tier));
}

// Linear ramp from a tier's own (lo, hi) CPU difficulty (see cpu_ai.configFor,
// 1-10) across the STORY_STAGES opponents, stage 0 landing on `lo` and the
// last stage on `hi`. `xhard` is deliberately flat at the very top instead of
// ramping -- it's supposed to be brutal from the first opponent on, not eased
// into.
pub fn storyDifficultyFor(tier: StoryTier, stage: u8) u8 {
    const lo: u8, const hi: u8 = switch (tier) {
        .easy => .{ 1, 3 },
        .medium => .{ 3, 6 },
        .hard => .{ 6, 9 },
        .xhard => return 10,
    };
    const span: u32 = hi - lo;
    const step: u32 = @as(u32, @min(stage, STORY_STAGES - 1)) * span / (STORY_STAGES - 1);
    return @intCast(lo + step);
}

// The opponent roster order for story mode: every character, in a fixed
// sequence -- including a "mirror match" against whichever look the player
// themselves picked, if it comes up, same as any other stage. Simpler and
// more predictable than filtering the player's own pick out (which would
// leave story mode one stage short, or need a stand-in opponent for it).
pub fn storyOpponentFor(stage: u8) u8 {
    return stage % characters.COUNT;
}

// Persisted across sessions via WASM-4's disk API (a single fixed-format
// blob, well under its 1024-byte cap) -- just whether the secret X Hard
// input has ever been revealed to this player (see StoryTier's own doc
// comment: the input itself always works regardless of this, this only
// gates the on-screen *hint* that it exists). Byte 0 is a version tag so a
// future save format change can tell an old save apart rather than
// misreading it.
const SAVE_VERSION: u8 = 1;
pub var xhard_revealed: bool = false;

// Guarded on builtin.is_test -- see audio.zig's identical reasoning: these
// are WASM4 `extern "env"` host functions with nothing to link against when
// `zig build test` runs natively.
pub fn loadSave() void {
    if (builtin.is_test) return;
    var buf: [2]u8 = .{ 0, 0 };
    const n = w4.Diskr(&buf, buf.len);
    if (n >= 2 and buf[0] == SAVE_VERSION) {
        xhard_revealed = buf[1] != 0;
    }
}

fn saveGame() void {
    if (builtin.is_test) return;
    const buf = [2]u8{ SAVE_VERSION, if (xhard_revealed) 1 else 0 };
    _ = w4.Diskw(&buf, buf.len);
}

// Whether finishing a story run under these conditions earns the reveal --
// split out from maybeRevealXhard below purely so this decision can be unit
// tested without also exercising the real disk write (see this file's own
// tests: nothing in this module's test suite may call an actual w4.Diskw/
// Diskr host function, since the native `zig build test` binary has no real
// WASM4 host to satisfy those `extern "env"` calls -- see debug.zig/input.
// zig/render.zig's own identical reasoning for why they carry no tests).
fn earnsXhardReveal(tier: StoryTier, game_overs: u32) bool {
    return tier == .hard and game_overs == 0;
}

// Called once a story run actually clears its final stage -- reveals the
// hint for good (idempotent: saving again once already revealed is harmless,
// just skipped) if this run beat `hard` specifically without a single game
// over (see state.story_game_overs, tallied across the whole run).
pub fn maybeRevealXhard(tier: StoryTier, game_overs: u32) void {
    if (xhard_revealed or !earnsXhardReveal(tier, game_overs)) return;
    xhard_revealed = true;
    saveGame();
}

const testing = @import("std").testing;

test "storyDifficultyFor ramps from lo to hi across the story stages, xhard flat at 10" {
    try testing.expectEqual(@as(u8, 1), storyDifficultyFor(.easy, 0));
    try testing.expectEqual(@as(u8, 3), storyDifficultyFor(.easy, STORY_STAGES - 1));
    try testing.expectEqual(@as(u8, 3), storyDifficultyFor(.medium, 0));
    try testing.expectEqual(@as(u8, 6), storyDifficultyFor(.medium, STORY_STAGES - 1));
    try testing.expectEqual(@as(u8, 6), storyDifficultyFor(.hard, 0));
    try testing.expectEqual(@as(u8, 9), storyDifficultyFor(.hard, STORY_STAGES - 1));
    try testing.expectEqual(@as(u8, 10), storyDifficultyFor(.xhard, 0));
    try testing.expectEqual(@as(u8, 10), storyDifficultyFor(.xhard, STORY_STAGES - 1));
}

test "storyOpponentFor cycles through every character in order" {
    for (0..STORY_STAGES) |stage| {
        try testing.expectEqual(@as(u8, @intCast(stage)), storyOpponentFor(@intCast(stage)));
    }
}

test "applyDefaultProfile and applyStoryProfile actually retune the shared constants, restoring cleanly" {
    applyDefaultProfile();
    try testing.expectEqual(@as(i16, 34), c.POP_FRAMES);
    try testing.expectEqual(@as(u32, 100), c.RISE_SPEED_SCALE_PCT);

    applyStoryProfile(.hard);
    try testing.expectEqual(@as(i16, 26), c.POP_FRAMES);
    try testing.expectEqual(@as(i16, 18), c.PRE_POP_BLINK_FRAMES);
    try testing.expectEqual(@as(i16, 8), c.PRE_POP_PAUSE_FRAMES);
    try testing.expectEqual(@as(i16, 26), c.PRE_POP_TOTAL_FRAMES);
    try testing.expectEqual(@as(u32, 45), c.DANGER_FORGIVENESS_FRAMES);
    try testing.expectEqual(@as(u32, 75), c.RISE_SPEED_SCALE_PCT);

    // Restore the baseline so no other test in the same binary run ever sees
    // a leftover non-default profile (see this module's own doc comment).
    applyDefaultProfile();
    try testing.expectEqual(@as(i16, 34), c.POP_FRAMES);
    try testing.expectEqual(@as(i16, 24), c.PRE_POP_BLINK_FRAMES);
    try testing.expectEqual(@as(i16, 12), c.PRE_POP_PAUSE_FRAMES);
    try testing.expectEqual(@as(i16, 36), c.PRE_POP_TOTAL_FRAMES);
    try testing.expectEqual(@as(u32, 60), c.DANGER_FORGIVENESS_FRAMES);
    try testing.expectEqual(@as(u32, 100), c.RISE_SPEED_SCALE_PCT);
}

test "earnsXhardReveal only for a clean (zero game-over) hard clear" {
    try testing.expect(!earnsXhardReveal(.medium, 0)); // wrong tier
    try testing.expect(!earnsXhardReveal(.hard, 1)); // had a game over
    try testing.expect(!earnsXhardReveal(.xhard, 0)); // wrong tier (already the top)
    try testing.expect(earnsXhardReveal(.hard, 0));
}
