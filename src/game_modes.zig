// The 3 top-level game modes, plus story's difficulty-profile retuning
// system (Profile/applyProfile) -- quick match/versus run the baseline.

const builtin = @import("builtin");
const c = @import("constants.zig");
const w4 = @import("wasm4.zig");
const characters = @import("characters.zig");
const s = @import("state.zig");

// GameMode/StoryTier live in state.zig alongside the rest of per-match mode
// state, rather than splitting a field from its own type across modules.
pub const StoryTier = s.StoryTier;

pub const STORY_STAGES: u8 = characters.COUNT;

// Story mode's difficulty-profile knobs, applied onto the mutable runtime
// constants in constants.zig (see its own doc comment).
const Profile = struct {
    rise_scale_pct: u32,
    pop_frames: i16,
    pre_pop_blink: i16,
    pre_pop_pause: i16,
    danger_forgiveness: u32,
};

// Today's baseline (see constants.zig's defaults) -- quick match/versus
// run this, so neither one's feel changes just because this system exists.
const DEFAULT_PROFILE = Profile{
    .rise_scale_pct = 100,
    .pop_frames = 34,
    .pre_pop_blink = 24,
    .pre_pop_pause = 12,
    .danger_forgiveness = 60,
};

// Easier tiers slow the rise/pop/forgiveness knobs, harder ones compress
// them; `xhard` pushes well past `hard` -- a genuine step up, not a re-skin.
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

// Called by quick match/versus on confirm, so an earlier story run's tier
// profile can never leak into a different mode.
pub fn applyDefaultProfile() void {
    applyProfile(DEFAULT_PROFILE);
}

pub fn applyStoryProfile(tier: StoryTier) void {
    applyProfile(profileFor(tier));
}

// Linear ramp from a tier's (lo, hi) CPU difficulty across the STORY_STAGES
// opponents. `xhard` stays flat at 10 -- brutal from the first fight, not eased in.
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

// Every character in fixed order, mirror matches included -- simpler than
// filtering the player's own pick out of the roster.
pub fn storyOpponentFor(stage: u8) u8 {
    return stage % characters.COUNT;
}

// Persisted via WASM-4's disk API: whether the X Hard hint has been shown
// (the input itself always works regardless). Byte 0 is a version tag.
const SAVE_VERSION: u8 = 1;
pub var xhard_revealed: bool = false;

// Guarded on builtin.is_test -- see audio.zig's identical Diskr/Diskw reasoning.
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

// Split out from maybeRevealXhard so this decision is unit-testable without
// exercising the real disk write (w4.Diskw has no native host to link against).
fn earnsXhardReveal(tier: StoryTier, game_overs: u32) bool {
    return tier == .hard and game_overs == 0;
}

// Idempotent: only reveals (and saves) on a clean hard-tier clear.
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

test "maybeRevealXhard is idempotent and only reveals on a clean hard clear" {
    xhard_revealed = false;
    maybeRevealXhard(.medium, 0);
    try testing.expect(!xhard_revealed);
    maybeRevealXhard(.hard, 0);
    try testing.expect(xhard_revealed);
    xhard_revealed = false; // restore so no other test sees a leftover reveal
}
