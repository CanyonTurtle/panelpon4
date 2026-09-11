# panelpon4

A Panel de Pon-style falling/rising block matching game for the [WASM-4](https://wasm4.org) fantasy console, written in Zig.

## Building

Requires Zig 0.16+ and Node/npm (fetches [binaryen](https://github.com/WebAssembly/binaryen)'s
`wasm-opt` via `npx` to shrink the release cart further than `-OReleaseSmall` alone -- see
`build.zig`).

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

## Editing

```sh
zig build test   # run the unit test suite
zig build lint   # check file-size and comment-length house style
```

Run both before committing; CI runs the same two commands on every push. The test suite is the
source of truth for what the game actually does — game logic changes should come with a test, not
a paragraph explaining the behavior. See [Project layout](#project-layout) for where things live
and [Testing](#testing) for what's covered.

For scripted/manual testing against a real WASM-4 host, `src/debug.zig` exposes board-state
helpers (debug builds only) driven by the Node harness in `tools/wasm4-harness.js` — see that
file's header comment for usage.

## Releasing

Every push to `main` auto-deploys the standalone web build to GitHub Pages
(`.github/workflows/pages.yml`). A tagged **release** is a separate, manual
step, meant for publishing elsewhere (itch.io, [wasm4.org](https://wasm4.org/docs/guides/distribution/#publish-on-wasm4org)):

1. Bump `.version` in `build.zig.zon` and commit.
2. `git tag vX.Y.Z && git push origin vX.Y.Z` (must match the version you
   just committed -- `.github/workflows/release.yml` checks this and fails
   fast if they don't match).

That workflow (`release.yml`) builds and tests the cart, then creates a
GitHub Release for the tag with 4 attached files: `panelpon4.wasm` (the
cart), `panelpon4.html` (the standalone web bundle), and `panelpon4.png`/
`panelpon4.md` -- a title-screen screenshot and manual, captured/generated
automatically (see `tools/capture-wasm4-screenshot.js` and
`wasm4/manual.md`), in exactly the form [wasm4.org's distribution guide](https://wasm4.org/docs/guides/distribution/#publish-on-wasm4org)
expects for a PR adding a cart to `/site/static/carts` in a fork of
`aduros/wasm4` -- download the 3 files from the release and drop them in.
`panelpon4.png` is also embedded at the top of the release notes.

## How to play

Each board is the traditional Panel de Pon size, 6 columns by 12 rows. You play against an
opponent, each with a full board of your own -- yours at normal size, theirs at a simplified micro
scale in the side panel -- running the exact same rules and physics.

- **Arrow keys** move a two-tile cursor, **X** swaps the two blocks under it. **Touch/mouse** is
  swipe-only. **Z** manually raises your own floor by a row.
- Match 3+ blocks of the same color/pattern in a line to pop them; chains and combos score bonus
  points and drop garbage on the opponent. Garbage clears when a match pops next to it.
- Each board's floor rises over time, faster as score climbs; topping out loses (with a short
  forgiveness window to recover).
- Three modes, picked from the title screen: **1P story** (fixed run through every character, with
  a difficulty tier), **marathon** (solo, no opponent -- chains/combos freeze the rise for a bit
  instead of sending garbage, chasing a high score and a best-chain record), and **2P versus**
  (second controller or WASM-4 netplay).

The exact rules for matching, chaining, garbage, CPU difficulty, and scoring live in the simulation
code and its tests (see below) -- this section is deliberately just an orientation, not a spec.

## Notes on the block colors

WASM-4's hardware only supports 4 simultaneous on-screen colors, one of which is spent on the
background, leaving 3 real hues. To get 5 distinguishable block colors out of them, 2 of the 5 are
drawn as a 1px checkerboard dither blending two adjacent hues -- a deliberate adaptation to the
console's real constraints.

Those 3 hues aren't fixed: each character owns a base hue, and the other two are generated exactly
120 degrees apart on the color wheel (see `characters.triadicPalette`), so picking a character
reskins the entire console palette to a fresh triadic set instead of just recoloring a sprite. The
title/mode-select screens slowly rotate through the wheel until a character locks it in.

## Project layout

The game is organized as plain-data state plus a handful of systems that act on it, rather than
objects with behavior attached. Most game-logic modules take an explicit `*Board` to act on (never
a single implicit global), which is what lets the exact same code drive both the player's and the
CPU's board.

- **Core simulation** (pure logic, no WASM-4 calls, fully unit tested): `state.zig` (the `Board`
  struct and per-match mode state), `board.zig` (row generation, the rising floor, win/loss), and
  `sim.zig`/`sim_matches.zig`/`sim_matches_resolve.zig`/`sim_garbage.zig` (swaps, gravity, match
  detection, chain/combo scoring, garbage spawn/gravity/recycling).
- **CPU opponent**: `cpu_ai.zig` (per-difficulty config), `cpu_engine.zig`/`cpu_engine_eval.zig`/
  `cpu_engine_garbage.zig` (the move-search engine, a self-contained simulator separate from
  `sim.zig`), `cpu_grid.zig` (the engine's board snapshot type).
- **Rendering**: `render.zig` (player board, panel, screens), `render_cpu.zig` (the CPU's mini
  board), `render_cells.zig`/`render_garbage.zig`/`render_bg.zig`/`render_badge.zig`/
  `render_character.zig`/`render_screens.zig`/`render_screens_game.zig` (the pieces that split out
  of those two to stay under the file-size guideline).
- **Input**: `input.zig` -- gamepad (with DAS and one-deep swap buffering) and touch/swipe.
- **Game data & modes**: `characters.zig` (the 7 playable characters, and the triadic-palette
  math above), `symbols.zig` (block glyph art), `logo.zig` (the title screen's bubble-letter
  wordmark), `game_modes.zig` (story-mode difficulty tiers and profiles), `constants.zig` (shared
  layout/timing values), `garbage_pieces.zig` (grouping settled garbage into pieces, for marking).
- **Entry point & support**: `main.zig` (wires everything behind WASM-4's `start`/`update`),
  `audio.zig` (sound effects), `debug.zig` (debug-build-only scripted-testing hooks), `wasm4.zig`
  (host API bindings), `tests.zig` (the native test entry point).
- **Tooling**: `tools/wasm4-harness.js` (headless cart driving for screenshots/fuzzing), `tools/
  check-line-counts.sh`/`check-comment-lengths.sh` (the two `zig build lint` checks), `tools/
  poll-ci.sh` (polls GitHub Actions for a commit's run status).

## Testing

Every module above the rendering/input layer has Zig `test` blocks -- most live alongside their
module, a few (`sim.zig`, `cpu_engine.zig`, `cpu_engine_garbage.zig`, garbage spawn/recycling) live
in a companion `*_test.zig` file to keep individual files under ~500 lines. These run natively
(not compiled into the cart):

```sh
zig build test
```

`input.zig`/`render*.zig` are excluded -- they call WASM-4's real host functions and only make
sense under an actual WASM-4 host. `garbage_pieces.zig` is split out from `render_garbage.zig`
specifically so its pure grouping logic isn't subject to that exclusion.

This also runs in CI on every push, before the cart is built.
