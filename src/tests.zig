// Root file for `zig build test`. Deliberately does NOT import main.zig:
// main.zig's `export fn start/update` are always fully compiled (exports are
// never tree-shaken), and they reach into render.zig's WASM4 draw calls,
// which are extern "env" host functions with nothing to link against when
// running natively. Importing only the pure-logic modules below keeps this
// test binary free of that dependency -- see input.zig/render.zig's module
// comments for why those two aren't included here.
test {
    _ = @import("state.zig");
    _ = @import("board.zig");
    _ = @import("sim.zig");
    _ = @import("sim_test.zig");
    _ = @import("sim_garbage_test.zig");
    _ = @import("cpu_ai.zig");
    _ = @import("cpu_engine_test.zig");
    _ = @import("cpu_engine_garbage_test.zig");
}
