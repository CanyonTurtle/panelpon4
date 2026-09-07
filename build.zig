const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .freestanding,
    });
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseSmall });

    const exe = b.addExecutable(.{
        .name = "cart",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    exe.entry = .disabled;
    exe.rdynamic = true;
    exe.import_memory = true;
    exe.initial_memory = 65536;
    exe.max_memory = 65536;
    exe.stack_size = 14752;

    b.installArtifact(exe);

    // Unit tests run natively (not wasm32-freestanding) so `zig build test`
    // can actually execute them locally and in CI without a WASM4 host or a
    // wasm runtime. This only works because the tested modules (state,
    // board, sim) never call WASM4's extern "env" host functions themselves
    // -- see audio.zig's builtin.is_test guards, and the module comments in
    // input.zig/render.zig for the two modules deliberately left untested.
    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests.zig"),
            .target = b.graph.host,
        }),
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}
