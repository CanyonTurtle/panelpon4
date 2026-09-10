// SFX plus a tiny procedural music engine -- no track is ever stored as a
// note sequence, just a hash-driven scale-degree picked fresh every beat.

const builtin = @import("builtin");
const w4 = @import("wasm4.zig");
const s = @import("state.zig");

// Guarded on builtin.is_test since these are extern "env" WASM4 host calls
// with nothing to link against when zig test runs natively.
pub fn playPopSound(multiplier: u8) void {
    if (builtin.is_test) return;
    const freq = 220 + @as(u32, multiplier) * 40;
    w4.Tone(freq, 8, 14, w4.TONE_PULSE1);
}

pub fn playPopTick() void {
    if (builtin.is_test) return;
    w4.Tone(660, 4, 7, w4.TONE_PULSE2);
}

pub fn playWinJingle() void {
    if (builtin.is_test) return;
    w4.Tone(392 | (784 << 16), 18 | (10 << 8), 20, w4.TONE_TRIANGLE);
}

pub fn playLoseJingle() void {
    if (builtin.is_test) return;
    w4.Tone(220 | (110 << 16), 40, 18, w4.TONE_TRIANGLE);
}

// A short upward chirp -- every menu_phase change gets one (see main.setMenuPhase).
pub fn playTransitionJingle() void {
    if (builtin.is_test) return;
    w4.Tone(440 | (660 << 16), 6, 10, w4.TONE_PULSE1 | w4.TONE_MODE2);
}

// A minor pentatonic, two octaves -- the only "data" here; which degree
// plays, when, and how high all come from hashing the beat counter instead.
const SCALE = [10]u32{ 220, 262, 294, 330, 392, 440, 523, 587, 659, 784 };

// Cheap integer mix (Knuth multiplicative + xorshift) -- turns a beat index
// and a per-track seed into a deterministic but scattered-looking value.
fn hash(x: u32) u32 {
    var h = x *% 2654435761;
    h ^= h >> 15;
    h *%= 2246822519;
    h ^= h >> 13;
    return h;
}

const BEAT_FRAMES: u32 = 14;

// One beat of a procedurally-generated track: `seed` gives each context its
// own melodic identity from the same formula, `channel`/`mode` its own timbre.
fn playBeat(seed: u32, channel: u32, mode: u32, vol: u32) void {
    const beat = s.frame_count / BEAT_FRAMES;
    if (s.frame_count % BEAT_FRAMES != 0) return;
    const h = hash(beat *% 3 +% seed);
    // Rest on roughly a quarter of beats -- an unbroken stream of notes
    // reads as noise, not a melody.
    if (h % 4 == 0) return;
    const degree = (h >> 4) % SCALE.len;
    const octave_up = (h >> 10) & 1;
    const freq = SCALE[degree] << @intCast(octave_up);
    w4.Tone(freq, BEAT_FRAMES + 4, vol, channel | mode);
}

// Called once per frame (see main.zig) -- cheap enough (one hash, maybe one
// Tone call) that gating it any more precisely isn't worth the extra code.
pub fn updateMusic() void {
    if (builtin.is_test) return;
    if (s.winner != .none) return; // the win/lose jingle owns this moment instead
    if (!s.started) {
        playBeat(0x9e3779b1, w4.TONE_TRIANGLE, w4.TONE_MODE1, 9);
        return;
    }
    if (s.game_mode == .tutorial) {
        playBeat(0x85ebca6b, w4.TONE_PULSE1, w4.TONE_MODE3, 8);
        return;
    }
    playBeat(0xc2b2ae35, w4.TONE_PULSE2, w4.TONE_MODE2, 8);
}
