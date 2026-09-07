# TODO

- Move the fuzz harnesses (currently ad hoc scripts in the dev scratchpad) into the repo (under
  `tools/`, alongside `tools/wasm4-harness.js`) and into CI: run them against the built cart on
  every push, after `zig build test`, so input-driven crashes/traps get caught automatically
  instead of only when run by hand. They should be rewritten to use `tools/wasm4-harness.js`
  (`setGamepad`/`setMouse`/`step`) instead of their own copy of the mock WASM4 env.
  - Optional follow-up: once on Zig 0.16's native fuzzing (`zig build --fuzz` /
    `std.testing.fuzz`), add a coverage-guided fuzz target for `sim.zig`'s pure logic
    (`checkMatches`/`simulate` over random grid states) as a complement -- it can reach grid
    states the dumb-random per-frame input fuzzers rarely stumble into. This would NOT replace
    the JS harnesses, since those are the only thing exercising the real compiled cart's
    WASM4 integration surface (memory-mapped gamepad/mouse registers in `input.zig`).
