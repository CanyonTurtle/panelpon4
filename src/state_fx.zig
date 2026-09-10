// Purely cosmetic per-frame effects layered on top of a Board: the small
// floating chain/combo match-popup badges, and the burst of particles a
// popped real block spawns. Split out of state.zig to keep that file under
// the project's ~500-line-per-file guideline. Nothing here affects gameplay
// -- these are free functions taking `self: *Board` as their first
// parameter (rather than Board methods, since Zig methods must live in the
// type's own file), cleared along with everything else on reset.

const s = @import("state.zig");

// A small floating text badge (an orange-dithered block with black text)
// that appears at a chain-or-combo match's location, then flies to the score
// display. Purely cosmetic -- spawned by sim.checkMatches (text like "x2" or
// "5", pre-rendered into `label` there so this module and render.zig stay
// agnostic of what the text actually says), advanced once per frame by
// tickMatchPopups (called from sim.simulate), and drawn by
// render.drawMatchPopups.
//
// Three phases: it eases up just a couple pixels from the center of the
// match's topmost block (`x`/`y` below) to that block's own top edge
// (`edge_y`) -- a small hop meant to catch the eye right at the match, not
// travel anywhere -- then waits there until the match's own pop animation
// actually finishes (`pop_end`, in the same elapsed-frame timeline as this
// popup), then flies from there into the score display. See
// render.drawMatchPopups for the actual interpolation.
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

// A short burst of small particles flying diagonally outward from a real
// block's own center the instant it's actually removed (see sim.simulate's
// just_cleared handling) -- a bit of impact feedback for a satisfying-
// feeling pop. Purely cosmetic, exactly like MatchPopup above: nothing here
// affects gameplay, and it's cleared along with everything else on reset.
// `x`/`y` (the spawn origin, in pixel space) and `color` never change after
// spawn -- only `elapsed` advances (see tickParticles) -- render.zig derives
// each particle's actual on-screen position and size from that and its own
// fixed diagonal direction.
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
    // Pool full -- would need 4+ simultaneous chain/combo groups landing in
    // the same frame. Silently drop rather than crash; missing one flourish
    // is harmless.
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

// One small burst of 4 particles, one per diagonal direction, flying
// outward from (x, y) -- a popped real block's own center, in pixel
// space. Silently drops whichever particles don't fit if the pool's
// already full (see spawnMatchPopup's identical reasoning) -- missing a
// few sparks during an enormous simultaneous multi-pop is harmless.
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
