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

Install the WASM-4 CLI (requires Node/npm) and run the cart:

```sh
npx w4 run zig-out/bin/cart.wasm
```

This serves the cart at `http://localhost:4444` and opens it in your browser, with hot-reload on rebuild.

### Standalone web bundle

To produce a single self-contained HTML file (playable offline, no server needed):

```sh
npx w4 bundle zig-out/bin/cart.wasm --html web/panelpon4.html --title "panelpon4"
```

## How to play

- **Arrow keys**: move the two-tile cursor.
- **X**: swap the two blocks under the cursor.
- Match 3 or more blocks of the same color/pattern in a horizontal or vertical line to pop them.
- Blocks above a pop fall and can chain into new matches for bonus score.
- The floor rises forever, faster as your score climbs. If blocks reach the top row, it's game over.
- Press **X** on the title or game-over screen to (re)start.

## Notes on the block colors

WASM-4's hardware only supports 4 simultaneous on-screen colors (the palette has exactly 4 slots), one of which is
spent on the background. That leaves 3 real hues to work with. To get 5 distinguishable block colors out of them,
2 of the 5 are drawn as a 1px checkerboard dither blending two adjacent hues, so the board reads as 3 solid colors
plus 2 dithered blends. This is a deliberate adaptation to the console's real constraints.

## Project layout

- `src/wasm4.zig` — bindings for the WASM-4 host API (drawing, input, memory-mapped registers).
- `src/main.zig` — game logic: the rising ring-buffered board, gravity/falling, matching, swap/pop/landing
  animations, rendering, and the WASM-4 `start`/`update` entry points.
- `build.zig` / `build.zig.zon` — builds `src/main.zig` into a freestanding `wasm32` cart with the memory layout
  WASM-4 expects.
