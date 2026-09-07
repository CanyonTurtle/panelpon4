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

Each board is the traditional Panel de Pon size, 6 columns by 12 rows. You play against a CPU opponent,
each with your own full board -- yours at normal size on the left, the CPU's at a simplified micro scale in
the side panel. Both run the exact same rules and physics.

- **Arrow keys**: move the two-tile cursor.
- **X**: swap the two blocks under the cursor. Buffers a single press if the cursor's pair can't swap yet
  (still animating from the previous swap), firing it automatically the instant it can, so mashing X chains
  swaps at full speed instead of dropping presses that land at the wrong instant.
- **Touch/mouse**: swipe-only -- touching down targets the block under your finger directly (the cursor
  hides while you do, since you're aiming at that block, not steering a separate one -- it reappears the
  next time you press a real button); swiping left/right swaps that block with its neighbor in that
  direction, and swiping up/down retargets to the row above/below instead (there's no vertical swap).
  A continuous drag keeps swapping the same block further across the board as it travels; a tap alone does
  nothing.
- Match 3 or more blocks of the same color/pattern in a horizontal or vertical line to pop them.
- Blocks above a pop fall and can chain into new matches for bonus score. A genuine chain ("x2", "x3", ...)
  or a combo (a single match bigger than 3 blocks, shown as a bare block count) flies a small badge into
  the score display.
- A big enough combo or chain drops garbage onto the *opponent's* board -- never your own. Garbage is inert
  (colorless, unswappable, unmatchable) until a match pops right next to it, which starts *recycling* it:
  one garbage block at a time, with a short delay between each, cracks open into a fresh, plain-looking
  normal block -- no animation of its own, just an instant reveal -- so you can read the color lineup
  forming and plan your next move before the whole connected group finishes and every recycled block
  becomes active together. A connected clump of garbage falls and lands as one rigid piece (a piece
  touching down stops the whole clump at once), rendering as a single seamless bezeled slab rather than
  individual tiles.
- A column with blocks near the top bounces in place as a warning that it's close to the rise hazard.
- Each board's floor rises forever, faster as that board's own score climbs. Whoever's board tops out
  first loses (both at once is a draw).
- **Z**: manually raise your own floor by one row right away (finishes in a third of a second instead of
  waiting for the automatic pace) -- useful for deliberately forcing a rise when you want fresh blocks, or
  to bail out of a bad board shape. On a cooldown (two thirds of a second) so it can't be spammed -- hold it
  down to keep raising row after row as soon as each cooldown clears, instead of having to tap repeatedly.
- Press **X** on the title or game-over screen to (re)start.

The CPU (v1) just makes random legal swaps every so often -- it isn't yet trying to find or set up matches.

## Notes on the block colors

WASM-4's hardware only supports 4 simultaneous on-screen colors (the palette has exactly 4 slots), one of which is
spent on the background. That leaves 3 real hues to work with. To get 5 distinguishable block colors out of them,
2 of the 5 are drawn as a 1px checkerboard dither blending two adjacent hues, so the board reads as 3 solid colors
plus 2 dithered blends. This is a deliberate adaptation to the console's real constraints.

## Project layout

- `src/wasm4.zig` — bindings for the WASM-4 host API (drawing, input, memory-mapped registers).
- `src/constants.zig` — layout/timing constants shared across modules.
- `src/symbols.zig` — pixel-art symbol data drawn on each block color.
- `src/state.zig` — the `Board` struct (grid, cursor, score/chain, rise state, its own RNG stream, its own
  match-popup pool) plus its small methods (ring-buffer indexing, RNG, board-busy query), and the two live
  instances of it, `player`/`cpu`. Every other module takes an explicit `*Board` rather than reaching into
  an implicit global, so the exact same logic drives both sides of a vs-CPU match.
- `src/board.zig` — row generation, the rising floor (automatic and the Z-button manual raise), and
  (re)starting a game, each taking the `*Board` to act on.
- `src/sim.zig` — the core simulation: swaps, pops, landings, and per-cell gravity, each taking `self`
  (and, for simulate, `opponent`) -- tests in the companion `src/sim_test.zig`.
- `src/sim_matches.zig` — match detection, chain/combo scoring, and garbage spawning (re-exported from
  `sim.zig` as `checkMatches`); a big enough combo/chain on `self` spawns garbage on `opponent`, never
  `self` -- garbage is never self-inflicted in vs-CPU play.
- `src/sim_garbage.zig` — garbage's rigid-body group gravity (a connected clump falls and lands as one piece,
  computed by connectivity fresh every frame) and its spawn placement -- tests in the companion
  `src/sim_garbage_test.zig`.
- `src/cpu_ai.zig` — the CPU opponent's move picker: for now, just a random legal swap every so often (see
  `MOVE_INTERVAL`); actually seeking matches is out of scope for v1.
- `src/audio.zig` — sound effects.
- `src/input.zig` — gamepad (cursor movement with DAS, swap triggering, itself one-deep buffered -- a press
  that lands mid-swap is remembered and applied the instant it's possible) and touch (swipe-only: aims
  directly at the touched block, swipes left/right swap it, up/down retarget rows -- with its own one-deep
  input buffering so a fast continuous drag chains swaps at max speed) -- always drives `state.player`; the
  CPU has no real input (see `cpu_ai.zig`).
- `src/render.zig` — most drawing: the player's board (in full detail) at normal size, the cursor, panel,
  and title/game-over screens.
- `src/render_garbage.zig` — garbage's full-detail rendering (the muted checkerboard fill and the linked-
  clump bezel look), split out from render.zig to keep that file under the project's ~500-line guideline,
  mirroring the sim.zig/sim_garbage.zig split.
- `src/render_cpu.zig` — the CPU's side of the panel: its score/label and its board at a simplified micro
  scale (dithered colors, tiny per-color icons, smooth rise scrolling, a cursor, popping/recycling
  animation -- just abstracted down to fit: no bevels, linked-garbage slab, landing squash, or popups).
- `src/render_badge.zig` — the chain/combo popup badge, plus the shared checkerboard-blit dithering
  primitive it's built on (reusable for any future dithered-highlight effect).
- `src/debug.zig` — debug-only helpers (set up a board scenario, read back cell/chain/winner state) for
  scripted testing, each taking a `board` selector (0 = player, else = cpu); only exported as WASM functions
  in Debug builds (see the `comptime` block in `main.zig`) -- `zig build --release=small` never includes
  this surface. Used via `tools/wasm4-harness.js`.
- `src/main.zig` — wires the above together behind the WASM-4 `start`/`update` entry points: drives both
  boards' input/simulation/rise each frame, and tracks who wins once either tops out.
- `build.zig` / `build.zig.zon` — builds `src/main.zig` into a freestanding `wasm32` cart with the memory layout
  WASM-4 expects, and wires up `zig build test`.
- `tools/wasm4-harness.js` — a shared Node harness for driving a compiled cart headlessly (scripted board
  scenarios via `src/debug.zig`, screenshots, fuzzing input). See the comment at the top of the file for usage.

## Testing

`state.zig`, `board.zig`, `sim.zig`/`sim_matches.zig`/`sim_garbage.zig`, and `cpu_ai.zig` have Zig `test`
blocks — `sim.zig`'s live in the companion `src/sim_test.zig`, and garbage-specific ones in
`src/sim_garbage_test.zig`, to keep each module under ~500 lines. These run natively (not compiled into the
cart) and are excluded from `input.zig`/`render.zig`/`render_garbage.zig`/`render_cpu.zig`, which touch
WASM-4's real host functions and only make sense under an actual WASM-4 host.

```sh
zig build test
```

This also runs in CI on every push, before the cart is built.
