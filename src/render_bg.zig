// A slow-drifting decorative background for the title/setup menu screens
// (see render.drawTitleScreen/drawSetupScreen): faint block-colored
// squares scrolling diagonally, wrapping seamlessly at the screen edge.
// Purely cosmetic -- the particle layout is generated once at compile time
// from a fixed seed, entirely independent of any gameplay RNG stream (see
// board.zig's shared row sequence), since nothing ever reads it back.

const w4 = @import("wasm4.zig");
const s = @import("state.zig");

// Mirrors render.zig's own DC_BG/HUE_DRAWCOLOR mapping.
const DC_BG: u16 = 1;
const HUE_DRAWCOLOR = [3]u16{ 2, 3, 4 };

const SCREEN: i32 = 160;
const NUM_PARTICLES = 16;
const PARTICLE_SIZE: i32 = 7;
// Frames per pixel of diagonal drift -- slow and steady, a background detail
// rather than something that draws the eye away from the menu itself.
const DRIFT_FRAMES_PER_PX: i32 = 3;

const Particle = struct { x: i32, y: i32, hue: u8 };

// A fixed, comptime-shuffled layout (same trick as render_badge.zig's own
// checkerboard bitmap) -- deterministic and free of any runtime RNG
// dependency, since this never needs to look different across sessions,
// only spread out and varied-looking within one.
const particles: [NUM_PARTICLES]Particle = blk: {
    @setEvalBranchQuota(10_000);
    var list: [NUM_PARTICLES]Particle = undefined;
    var seed: u32 = 0x9e3779b9;
    for (0..NUM_PARTICLES) |i| {
        seed ^= seed << 13;
        seed ^= seed >> 17;
        seed ^= seed << 5;
        const x = seed % @as(u32, @intCast(SCREEN));
        seed ^= seed << 13;
        seed ^= seed >> 17;
        seed ^= seed << 5;
        const y = seed % @as(u32, @intCast(SCREEN));
        seed ^= seed << 13;
        seed ^= seed >> 17;
        seed ^= seed << 5;
        const hue = seed % 3;
        list[i] = .{ .x = @intCast(x), .y = @intCast(y), .hue = @intCast(hue) };
    }
    break :blk list;
};

// A single faint speckled square -- a sparse dither (half the pixels only),
// not a solid fill, so it reads as a dim background detail rather than
// competing with foreground UI drawn in the same hues.
fn drawParticle(x: i32, y: i32, hue: u8) void {
    var dy: i32 = 0;
    while (dy < PARTICLE_SIZE) : (dy += 1) {
        var dx: i32 = 0;
        while (dx < PARTICLE_SIZE) : (dx += 1) {
            if (@mod(dx + dy, 2) != 0) continue;
            const px = x + dx;
            const py = y + dy;
            if (px < 0 or px >= SCREEN or py < 0 or py >= SCREEN) continue;
            w4.DRAW_COLORS.* = HUE_DRAWCOLOR[hue];
            w4.Rect(px, py, 1, 1);
        }
    }
}

pub fn draw() void {
    w4.DRAW_COLORS.* = DC_BG;
    w4.Rect(0, 0, SCREEN, SCREEN);

    const drift = @divTrunc(@as(i32, @intCast(s.frame_count)), DRIFT_FRAMES_PER_PX);
    const span = SCREEN + PARTICLE_SIZE;
    for (particles) |p| {
        const x = @mod(p.x + drift, span) - PARTICLE_SIZE;
        const y = @mod(p.y + drift, span) - PARTICLE_SIZE;
        drawParticle(x, y, p.hue);
    }
}
