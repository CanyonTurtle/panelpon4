const builtin = @import("builtin");
const w4 = @import("wasm4.zig");

// Guarded on builtin.is_test since these are extern "env" WASM4 host calls
// with nothing to link against when zig test runs natively.
pub fn playPopSound(multiplier: u8) void {
    if (builtin.is_test) return;
    const freq = 220 + @as(u32, multiplier) * 40;
    w4.Tone(freq, 8, 30, w4.TONE_PULSE1);
}

pub fn playPopTick() void {
    if (builtin.is_test) return;
    w4.Tone(660, 4, 15, w4.TONE_PULSE2);
}

pub fn playGameOverSound() void {
    if (builtin.is_test) return;
    w4.Tone(220 | (110 << 16), 40, 40, w4.TONE_TRIANGLE);
}
