// Garbage's full-detail rendering (the muted checkerboard fill and the
// linked-clump bezel look) -- split out from render.zig to keep that file
// under the project's ~500-line-per-file guideline, mirroring the
// sim.zig/sim_garbage.zig split. See render_cpu.zig for the CPU's much
// simpler micro-scale equivalent (no linked-clump bezel there).

const c = @import("constants.zig");
const s = @import("state.zig");
const w4 = @import("wasm4.zig");
const sym = @import("symbols.zig");
const pieces = @import("garbage_pieces.zig");

// Re-exported so render.zig's call site doesn't need to know this logic
// lives in its own module (split out purely so it can be unit tested
// without render_garbage.zig's own w4 dependency -- see garbage_pieces.zig's
// own doc comment).
pub const markCenters = pieces.markCenters;

// Mirrors render.zig's own DC_BG/HUE_DRAWCOLOR mapping and BLOCK_SIZE.
const DC_BG: u16 = 1;
const HUE_DRAWCOLOR = [3]u16{ 2, 3, 4 };
const BLOCK_SIZE: i32 = c.TILE - 1;

// Garbage (see Cell.is_garbage) is colorless and inert, so it renders as a
// muted background+hue checkerboard -- distinct from all 5 real block colors
// (which are either a solid hue or a hue+hue dither) -- with no symbol, so it
// reads at a glance as "not a real, matchable color".
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

// Same checkerboard, phase inverted -- a purely cosmetic "this cell is being
// processed" flash for a garbage row caught up in a pop/recycle event that
// won't actually convert or clear it (see render.drawRecyclingCell's
// !garbage_reveals branch), so a taller clump still visibly reacts the whole
// group is popping, not just the one row that's actually cracking open.
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

// Which of a garbage cell's 4 orthogonal neighbors are themselves garbage,
// still attached (see sim.zig's group-based gravity -- connected garbage
// always falls/lands in lockstep, so a neighbor in any of these states is
// guaranteed to be moving the same way this cell is, not just coincidentally
// adjacent). Used to render a connected clump as one seamless slab: no gap
// or bevel on the sides facing an attached neighbor, only on the outer
// boundary of the whole clump.
pub const Edges = struct { up: bool = false, down: bool = false, left: bool = false, right: bool = false };

fn isAttached(b: *s.Board, lr: u8, col: u8) bool {
    const cell = b.cellAt(lr, col);
    if (!cell.is_garbage) return false;
    if (cell.state == .normal or cell.state == .falling or cell.state == .landing) return true;
    // A recycling cell only still looks (and counts as) attached garbage
    // while it hasn't had its own turn yet -- see render.drawRecyclingCell,
    // including the shared pre-pop blink+pause preamble (Cell.pre_pop_timer)
    // that now comes before the reveal, in lockstep across the whole group.
    // The instant it reveals, it renders as a plain normal block, so the
    // clump it was part of should visually shrink by one cell right along
    // with it. A non-converting cell (see Cell.garbage_reveals) never
    // reaches that reveal at all, so it stays attached for the entire event.
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

// Like drawGarbageRect, but extends the fill into an attached right/down
// neighbor's tile (closing the 1px gap normal blocks leave there -- an
// attached left/up neighbor closes the gap on *its* side instead, so this
// cell doesn't need to touch its own left/top) and only bevels a corner
// where both adjacent edges are unattached -- a true exterior corner of the
// whole connected clump, not a seam between two of its own cells.
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

// A different hue than GARBAGE_HUE, solid (not checkerboarded) -- a mark
// drawn in DC_BG (like a real block's own symbol) would only actually
// change the pixels that started out teal; the half of it landing on
// already-background checkerboard squares would be invisible, breaking the
// shape up into an illegible scatter instead of one solid mark. A third,
// otherwise-unused hue reads as a clean, solid shape regardless of which
// checkerboard phase it lands on.
const MARK_HUE: u8 = 0; // red

// Draws SYM_GARBAGE_MARK at (x, y) -- the top-left of a single tile, same
// convention as render.zig's drawSymbolFor -- so a piece's center reads as a
// small solid mark, unmistakable against its checkerboard fill.
pub fn drawMark(x: i32, y: i32) void {
    w4.DRAW_COLORS.* = HUE_DRAWCOLOR[MARK_HUE];
    const rows = sym.SYM_GARBAGE_MARK;
    for (rows, 0..) |row, ry| {
        for (row, 0..) |ch, rx| {
            if (ch == '#') w4.Rect(x + @as(i32, @intCast(rx)), y + @as(i32, @intCast(ry)), 1, 1);
        }
    }
}
