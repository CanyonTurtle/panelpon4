// Purely cosmetic per-frame effects on a Board: match-popup badges and pop
// particles. Free functions (not Board methods) since split out of state.zig.

const s = @import("state.zig");

// A floating "x2"/"5" badge: eases to the block's edge, waits for the pop
// to finish (`pop_end`), then flies to the score (render.drawMatchPopups).
pub const MATCH_POPUP_RISE: i16 = 6; // frames easing up to the block's own top edge
pub const MATCH_POPUP_RISE_PX: i32 = 3; // how far up that is -- a couple pixels, not half a tile
pub const MATCH_POPUP_FLY: i16 = 28; // frames easing from that edge into the score
pub const MAX_MATCH_POPUPS = 4;
const MATCH_POPUP_LABEL_CAP = 16;

pub const MatchPopup = struct {
    active: bool = false,
    label: [MATCH_POPUP_LABEL_CAP]u8 = undefined,
    label_len: u8 = 0,
    x: i32 = 0, // badge center, at spawn -- see sim.checkMatches for how it's picked
    y: i32 = 0, // center of the match's topmost block, at spawn
    edge_y: i32 = 0, // a couple pixels above y -- the rise phase's target, and where it waits
    pop_end: i16 = 0, // elapsed frame (this popup's own timeline) the match's pop finishes; flight starts then
    elapsed: i16 = 0,
};

// A burst from a popped block's center. `x`/`y`/`color` are fixed at spawn;
// only `elapsed` advances -- render.zig derives position/size from that.
pub const Particle = struct {
    active: bool = false,
    x: i32 = 0,
    y: i32 = 0,
    dir_x: i8 = 1, // -1/+1: which of the 4 diagonals this particle flies toward
    dir_y: i8 = 1,
    color: u8 = 0,
    elapsed: i16 = 0,
};

pub const PARTICLE_LIFE: i16 = 16; // frames a burst's particles stay alive
pub const MAX_PARTICLES = 16; // 4 per burst, room for several simultaneous pops

pub fn spawnMatchPopup(self: *s.Board, label: []const u8, x: i32, y: i32, edge_y: i32, pop_end: i16) void {
    for (&self.match_popups) |*p| {
        if (!p.active) {
            p.active = true;
            p.label_len = @intCast(@min(label.len, p.label.len));
            @memcpy(p.label[0..p.label_len], label[0..p.label_len]);
            p.x = x;
            p.y = y;
            p.edge_y = edge_y;
            p.pop_end = pop_end;
            p.elapsed = 0;
            return;
        }
    }
    // Pool full (4+ simultaneous chain/combo groups) -- drop silently.
}

pub fn tickMatchPopups(self: *s.Board) void {
    for (&self.match_popups) |*p| {
        if (!p.active) continue;
        p.elapsed += 1;
        if (p.elapsed >= p.pop_end + MATCH_POPUP_FLY) p.active = false;
    }
}

pub fn clearMatchPopups(self: *s.Board) void {
    for (&self.match_popups) |*p| p.* = .{};
}

// 4 particles, one per diagonal, from a popped block's center. Drops
// silently (like spawnMatchPopup) if the pool's already full.
pub fn spawnPopParticles(self: *s.Board, x: i32, y: i32, color: u8) void {
    const dirs = [4][2]i8{ .{ -1, -1 }, .{ 1, -1 }, .{ -1, 1 }, .{ 1, 1 } };
    for (dirs) |d| {
        for (&self.particles) |*p| {
            if (p.active) continue;
            p.active = true;
            p.x = x;
            p.y = y;
            p.dir_x = d[0];
            p.dir_y = d[1];
            p.color = color;
            p.elapsed = 0;
            break;
        }
    }
}

pub fn tickParticles(self: *s.Board) void {
    for (&self.particles) |*p| {
        if (!p.active) continue;
        p.elapsed += 1;
        if (p.elapsed >= PARTICLE_LIFE) p.active = false;
    }
}

const testing = @import("std").testing;

test "spawnMatchPopup drops silently once the pool is full" {
    var b: s.Board = .{};
    for (0..MAX_MATCH_POPUPS) |_| spawnMatchPopup(&b, "x2", 0, 0, 0, 0);
    spawnMatchPopup(&b, "x3", 1, 1, 1, 1); // pool full -- dropped, not crashed
    for (&b.match_popups) |*p| try testing.expect(p.active);
}

test "spawnPopParticles drops silently once the pool is full" {
    var b: s.Board = .{};
    for (0..MAX_PARTICLES / 4) |_| spawnPopParticles(&b, 0, 0, 0);
    spawnPopParticles(&b, 1, 1, 1); // pool full -- dropped, not crashed
    for (&b.particles) |*p| try testing.expect(p.active);
}
