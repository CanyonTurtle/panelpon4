# panelpon4

A Panel de Pon-style falling/rising block matching game for the [WASM-4](https://wasm4.org) fantasy console, written in Zig.

## Building

Requires Zig 0.16+.

```sh
zig build --release=small
```

The cart is written to `zig-out/bin/cart.wasm`.

For a debug build with safety checks enabled (bigger binary, useful while developing):

```sh
zig build
```

## Running

Install the WASM-4 CLI (requires Node/npm) and run the cart. The npm package is called `wasm4`
(it provides a `w4` command), so on a machine without it already resolved, use `-p wasm4` to be
explicit about which package to fetch:

```sh
npx --yes -p wasm4 w4 run zig-out/bin/cart.wasm
```

This serves the cart at `http://localhost:4444` and opens it in your browser, with hot-reload on rebuild.

### Standalone web bundle

To produce a single self-contained HTML file (playable offline, no server needed):

```sh
npx --yes -p wasm4 w4 bundle zig-out/bin/cart.wasm --html web/panelpon4.html --title "panelpon4"
```

## How to play

- **Arrow keys**: move the two-tile cursor.
- **X**: swap the two blocks under the cursor.
- Match 3 or more blocks of the same color/pattern in a horizontal or vertical line to pop them.
- Blocks above a pop fall and can chain into new matches for bonus score. A genuine chain ("x2", "x3", ...)
  or a combo (a single match bigger than 3 blocks, shown as a bare block count) flies a small badge into
  the score display.
- A big enough combo or chain also drops garbage onto your own board -- self-inflicted risk/reward for
  aggressive play. Garbage is inert (colorless, unswappable, unmatchable) until a match pops right next to
  it, which cracks it open into a fresh, chainable block once the whole connected pop finishes.
- A column with blocks near the top bounces in place as a warning that it's close to the rise hazard.
- The floor rises forever, faster as your score climbs. If blocks reach the top row, it's game over.
- Press **X** on the title or game-over screen to (re)start.

## Notes on the block colors

WASM-4's hardware only supports 4 simultaneous on-screen colors (the palette has exactly 4 slots), one of which is
spent on the background. That leaves 3 real hues to work with. To get 5 distinguishable block colors out of them,
2 of the 5 are drawn as a 1px checkerboard dither blending two adjacent hues, so the board reads as 3 solid colors
plus 2 dithered blends. This is a deliberate adaptation to the console's real constraints.

## Project layout

- `src/wasm4.zig` — bindings for the WASM-4 host API (drawing, input, memory-mapped registers).
- `src/constants.zig` — layout/timing constants shared across modules.
- `src/symbols.zig` — pixel-art symbol data drawn on each block color.
- `src/state.zig` — the board grid, cursor, score/chain, and all other mutable game state, plus the small
  pure helpers (ring-buffer indexing, RNG, board-busy query) that only need that state.
- `src/board.zig` — row generation, the rising floor, and (re)starting a game.
- `src/sim.zig` — the core simulation: swaps, pops, landings, gravity, matching/chaining, and garbage
  (spawning on a big combo/chain, propagation into adjacent garbage on a pop, reveal on clear) -- tests in
  the companion `src/sim_test.zig`.
- `src/audio.zig` — sound effects.
- `src/input.zig` — gamepad and touch handling (cursor movement with DAS, swap triggering).
- `src/render.zig` — most drawing: the board, cursor, panel, and title/game-over screens.
- `src/render_badge.zig` — the chain/combo popup badge, plus the shared checkerboard-blit dithering
  primitive it's built on (reusable for any future dithered-highlight effect).
- `src/debug.zig` — debug-only helpers (set up a board scenario, read back cell/chain state) for scripted
  testing; only exported as WASM functions in Debug builds (see the `comptime` block in `main.zig`) --
  `zig build --release=small` never includes this surface. Used via `tools/wasm4-harness.js`.
- `src/main.zig` — wires the above together behind the WASM-4 `start`/`update` entry points.
- `build.zig` / `build.zig.zon` — builds `src/main.zig` into a freestanding `wasm32` cart with the memory layout
  WASM-4 expects, and wires up `zig build test`.
- `tools/wasm4-harness.js` — a shared Node harness for driving a compiled cart headlessly (scripted board
  scenarios via `src/debug.zig`, screenshots, fuzzing input). See the comment at the top of the file for usage.

## Testing

`state.zig`, `board.zig`, and `sim.zig` (matching/chain logic in particular) have Zig `test` blocks —
`sim.zig`'s live in the companion `src/sim_test.zig` to keep the module itself under ~500 lines. These run
natively (not compiled into the cart) and are excluded from `input.zig`/`render.zig`, which touch WASM-4's real
host functions and only make sense under an actual WASM-4 host.

```sh
zig build test
```

This also runs in CI on every push, before the cart is built.
