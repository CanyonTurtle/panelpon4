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

// One stage per character except Mermaid herself -- she's the fixed player
// character in story mode (characters.MERMAID_INDEX), never an opponent.
pub const STORY_STAGES: u8 = characters.COUNT - 1;

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

// Every character except Mermaid, in fixed order -- she's excluded from her
// own opponent cycle (see STORY_STAGES above).
pub fn storyOpponentFor(stage: u8) u8 {
    const idx = stage % STORY_STAGES;
    return if (idx < characters.MERMAID_INDEX) idx else idx + 1;
}

// How many of the traveling party's slots are currently filled.
pub fn unlockedCount(party: [characters.COUNT]bool) u8 {
    var n: u8 = 0;
    for (party) |p| {
        if (p) n += 1;
    }
    return n;
}

// Cycle to the next/previous unlocked party member, wrapping around --
// always terminates since Mermaid is never unset (main.zig's beginStoryFlow).
pub fn nextUnlocked(party: [characters.COUNT]bool, current: u8) u8 {
    var i = current;
    while (true) {
        i = (i + 1) % characters.COUNT;
        if (party[i]) return i;
    }
}

pub fn prevUnlocked(party: [characters.COUNT]bool, current: u8) u8 {
    var i = current;
    while (true) {
        i = (i + characters.COUNT - 1) % characters.COUNT;
        if (party[i]) return i;
    }
}

// Persisted via WASM-4's disk API. Byte 0 is a version tag; byte 1 packs the
// X Hard hint (top bit) and the character-unlock bitmask (bit i = ALL[i]) together.
const SAVE_VERSION: u8 = 2;
const XHARD_BIT: u8 = 0x80;
pub var xhard_revealed: bool = false;

// Mermaid alone by default.
const DEFAULT_UNLOCKED_MASK: u8 = 1 << characters.MERMAID_INDEX;
pub var unlocked_characters: u8 = DEFAULT_UNLOCKED_MASK;

// Guarded on builtin.is_test -- see audio.zig's identical Diskr/Diskw reasoning.
pub fn loadSave() void {
    if (builtin.is_test) return;
    var buf: [2]u8 = .{ 0, 0 };
    const n = w4.Diskr(&buf, buf.len);
    if (n >= 2 and buf[0] == SAVE_VERSION) {
        xhard_revealed = (buf[1] & XHARD_BIT) != 0;
        unlocked_characters = (buf[1] & ~XHARD_BIT) | DEFAULT_UNLOCKED_MASK;
    }
}

fn saveGame() void {
    if (builtin.is_test) return;
    const packed_byte = unlocked_characters | (if (xhard_revealed) XHARD_BIT else 0);
    const buf = [2]u8{ SAVE_VERSION, packed_byte };
    _ = w4.Diskw(&buf, buf.len);
}

pub fn charUnlocked(idx: u8) bool {
    return (unlocked_characters & (@as(u8, 1) << @intCast(idx))) != 0;
}

fn unlockChar(idx: u8) void {
    const bit = @as(u8, 1) << @intCast(idx);
    if (unlocked_characters & bit != 0) return; // already unlocked -- skip the disk write
    unlocked_characters |= bit;
    saveGame();
}

const ALL_UNLOCKED_MASK: u8 = (1 << characters.COUNT) - 1;

// The secret "unlock everyone" combo (main.zig's setup_character input) --
// no idempotency guard needed since it's already gated on justPressed there.
pub fn unlockAllChars() void {
    unlocked_characters = ALL_UNLOCKED_MASK;
    saveGame();
}

// Clearing story mode is the "beat the game in a certain mode" unlock --
// one character per tier, easy through X Hard.
pub fn maybeUnlockForStoryClear(tier: StoryTier) void {
    unlockChar(switch (tier) {
        .easy => characters.LIZARD_INDEX,
        .medium => characters.CLOUD_INDEX,
        .hard => characters.CROW_INDEX,
        .xhard => characters.ROBOT_INDEX,
    });
}

// A single match popping this many real blocks at once is the "big combo"
// skill unlock (state.Board.combo_display) -- unlocks Bug and Slime together.
const BIG_COMBO_THRESHOLD: u8 = 6;
pub fn maybeUnlockForCombo(combo_size: u8) void {
    if (combo_size < BIG_COMBO_THRESHOLD) return;
    unlockChar(characters.BUG_INDEX);
    unlockChar(characters.SLIME_INDEX);
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

test "storyOpponentFor cycles through every character except Mermaid, in order" {
    var seen = [_]bool{false} ** characters.COUNT;
    for (0..STORY_STAGES) |stage| {
        const opp = storyOpponentFor(@intCast(stage));
        try testing.expect(opp != characters.MERMAID_INDEX);
        seen[opp] = true;
    }
    for (0..characters.COUNT) |i| {
        try testing.expectEqual(i != characters.MERMAID_INDEX, seen[i]);
    }
}

test "unlockedCount counts true entries; next/prevUnlocked cycle and skip locked slots" {
    var party = [_]bool{false} ** characters.COUNT;
    party[characters.MERMAID_INDEX] = true;
    try testing.expectEqual(@as(u8, 1), unlockedCount(party));
    try testing.expectEqual(characters.MERMAID_INDEX, nextUnlocked(party, characters.MERMAID_INDEX));
    try testing.expectEqual(characters.MERMAID_INDEX, prevUnlocked(party, characters.MERMAID_INDEX));

    party[0] = true;
    party[3] = true;
    try testing.expectEqual(@as(u8, 3), unlockedCount(party));
    try testing.expectEqual(@as(u8, 3), nextUnlocked(party, characters.MERMAID_INDEX));
    try testing.expectEqual(@as(u8, 0), nextUnlocked(party, 3));
    try testing.expectEqual(characters.MERMAID_INDEX, nextUnlocked(party, 0));
    try testing.expectEqual(@as(u8, 0), prevUnlocked(party, characters.MERMAID_INDEX));
    try testing.expectEqual(@as(u8, 3), prevUnlocked(party, 0));
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

test "charUnlocked/unlockChar: Mermaid starts unlocked, everyone else doesn't" {
    unlocked_characters = DEFAULT_UNLOCKED_MASK;
    try testing.expect(charUnlocked(characters.MERMAID_INDEX));
    try testing.expect(!charUnlocked(characters.LIZARD_INDEX));
    unlockChar(characters.LIZARD_INDEX);
    try testing.expect(charUnlocked(characters.LIZARD_INDEX));
    try testing.expect(!charUnlocked(characters.BUG_INDEX));
    unlocked_characters = DEFAULT_UNLOCKED_MASK; // restore
}

test "unlockAllChars sets every bit" {
    unlocked_characters = DEFAULT_UNLOCKED_MASK;
    unlockAllChars();
    for (0..characters.COUNT) |i| {
        try testing.expect(charUnlocked(@intCast(i)));
    }
    unlocked_characters = DEFAULT_UNLOCKED_MASK; // restore
}

test "maybeUnlockForStoryClear maps each tier to its own character" {
    unlocked_characters = DEFAULT_UNLOCKED_MASK;
    maybeUnlockForStoryClear(.easy);
    try testing.expect(charUnlocked(characters.LIZARD_INDEX));
    try testing.expect(!charUnlocked(characters.CLOUD_INDEX));
    maybeUnlockForStoryClear(.medium);
    try testing.expect(charUnlocked(characters.CLOUD_INDEX));
    maybeUnlockForStoryClear(.hard);
    try testing.expect(charUnlocked(characters.CROW_INDEX));
    maybeUnlockForStoryClear(.xhard);
    try testing.expect(charUnlocked(characters.ROBOT_INDEX));
    unlocked_characters = DEFAULT_UNLOCKED_MASK; // restore
}

test "maybeUnlockForCombo unlocks both Bug and Slime at the threshold" {
    unlocked_characters = DEFAULT_UNLOCKED_MASK;
    maybeUnlockForCombo(BIG_COMBO_THRESHOLD - 1);
    try testing.expect(!charUnlocked(characters.BUG_INDEX));
    try testing.expect(!charUnlocked(characters.SLIME_INDEX));
    maybeUnlockForCombo(BIG_COMBO_THRESHOLD);
    try testing.expect(charUnlocked(characters.BUG_INDEX));
    try testing.expect(charUnlocked(characters.SLIME_INDEX));
    unlocked_characters = DEFAULT_UNLOCKED_MASK; // restore
}
