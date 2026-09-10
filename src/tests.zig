// Root file for `zig build test`. Skips main.zig/input.zig/render.zig --
// those reach WASM4 extern "env" host calls with nothing to link natively.
test {
    _ = @import("state.zig");
    _ = @import("board.zig");
    _ = @import("sim.zig");
    _ = @import("sim_test.zig");
    _ = @import("sim_garbage_test.zig");
    _ = @import("sim_garbage_spawn_test.zig");
    _ = @import("sim_recycle_test.zig");
    _ = @import("cpu_ai.zig");
    _ = @import("cpu_engine_test.zig");
    _ = @import("cpu_engine_garbage_test.zig");
    _ = @import("garbage_pieces.zig");
    _ = @import("game_modes.zig");
}
