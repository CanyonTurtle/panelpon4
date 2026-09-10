// Garbage's full-detail rendering (checkerboard fill, linked-clump bezel),
// split out from render.zig, mirroring the sim.zig/sim_garbage.zig split.

const c = @import("constants.zig");
const s = @import("state.zig");
const w4 = @import("wasm4.zig");
const pieces = @import("garbage_pieces.zig");

// Re-exported so callers don't need to know this lives in its own module
// (split out so it's unit-testable without this file's w4 dependency).
pub const pieceCenters = pieces.pieceCenters;
pub const PieceCenter = pieces.PieceCenter;

// Mirrors render.zig's own DC_BG/HUE_DRAWCOLOR mapping and BLOCK_SIZE.
const DC_BG: u16 = 1;
const HUE_DRAWCOLOR = [3]u16{ 2, 3, 4 };
const BLOCK_SIZE: i32 = c.TILE - 1;

// Garbage is colorless/inert, so it renders as a muted checkerboard with no
// symbol -- visually distinct from all 5 real block colors at a glance.
const GARBAGE_HUE: u8 = 1; // teal; arbitrary, just needs to look muted/inert next to DC_BG

pub fn drawGarbageRect(x: i32, y: i32, w: i32, h: i32) void {
    if (w <= 0 or h <= 0) return;
    var dy: i32 = 0;
    while (dy < h) : (dy += 1) {
        var dx: i32 = 0;
        while (dx < w) : (dx += 1) {
            w4.DRAW_COLORS.* = if (@mod(dx + dy, 2) == 0) DC_BG else HUE_DRAWCOLOR[GARBAGE_HUE];
            w4.Rect(x + dx, y + dy, 1, 1);
        }
    }
}

// Same checkerboard, phase inverted -- a cosmetic "still processing" flash
// for a garbage row caught in a pop event that won't itself convert/clear.
fn drawGarbageRectFlash(x: i32, y: i32, w: i32, h: i32) void {
    if (w <= 0 or h <= 0) return;
    var dy: i32 = 0;
    while (dy < h) : (dy += 1) {
        var dx: i32 = 0;
        while (dx < w) : (dx += 1) {
            w4.DRAW_COLORS.* = if (@mod(dx + dy, 2) == 0) HUE_DRAWCOLOR[GARBAGE_HUE] else DC_BG;
            w4.Rect(x + dx, y + dy, 1, 1);
        }
    }
}

// Which of a garbage cell's 4 neighbors are still attached -- renders a
// connected clump as one seamless slab, bevelled only on its outer edge.
pub const Edges = struct { up: bool = false, down: bool = false, left: bool = false, right: bool = false };

fn isAttached(b: *s.Board, lr: u8, col: u8) bool {
    const cell = b.cellAt(lr, col);
    if (!cell.is_garbage) return false;
    if (cell.state == .normal or cell.state == .falling or cell.state == .landing) return true;
    // A recycling cell counts as attached only until its own reveal turn --
    // a non-converting cell never reaches that reveal, so stays attached.
    if (cell.state == .recycling) return !cell.garbage_reveals or cell.pre_pop_timer > 0 or c.POP_FRAMES - cell.timer < 0;
    return false;
}

pub fn edgesAt(b: *s.Board, lr: u8, col: u8) Edges {
    var e = Edges{};
    if (lr > 0) e.up = isAttached(b, lr - 1, col);
    if (lr + 1 < c.ROWS) e.down = isAttached(b, lr + 1, col);
    if (col > 0) e.left = isAttached(b, lr, col - 1);
    if (col + 1 < c.COLS) e.right = isAttached(b, lr, col + 1);
    return e;
}

// Extends the fill into an attached right/down tile; bevels a corner only
// where both adjacent edges are unattached (a true exterior corner).
pub fn drawLinked(x: i32, y: i32, edges: Edges) void {
    const w: i32 = if (edges.right) BLOCK_SIZE + 1 else BLOCK_SIZE;
    const h: i32 = if (edges.down) BLOCK_SIZE + 1 else BLOCK_SIZE;
    drawGarbageRect(x, y, w, h);
    w4.DRAW_COLORS.* = DC_BG;
    if (!edges.up and !edges.left) w4.Rect(x, y, 1, 1);
    if (!edges.up and !edges.right) w4.Rect(x + w - 1, y, 1, 1);
    if (!edges.down and !edges.left) w4.Rect(x, y + h - 1, 1, 1);
    if (!edges.down and !edges.right) w4.Rect(x + w - 1, y + h - 1, 1, 1);
}

// Like drawLinked, but with the flashing (phase-inverted) fill -- see
// drawGarbageRectFlash.
pub fn drawLinkedFlash(x: i32, y: i32, edges: Edges) void {
    const w: i32 = if (edges.right) BLOCK_SIZE + 1 else BLOCK_SIZE;
    const h: i32 = if (edges.down) BLOCK_SIZE + 1 else BLOCK_SIZE;
    drawGarbageRectFlash(x, y, w, h);
    w4.DRAW_COLORS.* = DC_BG;
    if (!edges.up and !edges.left) w4.Rect(x, y, 1, 1);
    if (!edges.up and !edges.right) w4.Rect(x + w - 1, y, 1, 1);
    if (!edges.down and !edges.left) w4.Rect(x, y + h - 1, 1, 1);
    if (!edges.down and !edges.right) w4.Rect(x + w - 1, y + h - 1, 1, 1);
}

// A filled oval, not a bitmap -- a bitmap would only flip its own already-
// teal pixels, scattering into an illegible shape against the checkerboard.
const MARK_DIAMETER: i32 = 5;

// Centered on (x, y), a pixel-space point, not necessarily a cell's center.
pub fn drawMark(x: i32, y: i32) void {
    w4.DRAW_COLORS.* = DC_BG;
    const r = @divTrunc(MARK_DIAMETER, 2);
    w4.Oval(x - r, y - r, @intCast(MARK_DIAMETER), @intCast(MARK_DIAMETER));
}
