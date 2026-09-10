#!/usr/bin/env node
// Captures a 160x160 screenshot of the game for the wasm4.org submission
// manual (see wasm4/manual.md and the release workflow) -- reuses
// wasm4-harness.js's pure-Node WASM4 host (no browser needed) against a
// *Debug* build of the cart, since the debugXxx exports it relies on
// (see src/debug.zig) only exist there. This build is throwaway, used only
// to render one frame; it never touches the shipped release cart.
//
// Drives the cart from the title screen through the default quick-match
// setup flow (game_mode=.quick, player_character=0, difficulty=1 are all
// already the defaults, so no left/right presses are needed -- just X at
// each of the 4 confirm points, with generous waits for the setup-character
// flash, the CPU-reveal spin, and the "3 2 1 START" countdown to play out on
// their own). Real gameplay's own rise mechanic is far too slow to fill the
// board organically in a short capture window, so once in-game, paints a
// deterministic, good-looking, non-matching pattern of blocks directly via
// the debug exports before taking the screenshot.
//
// Usage: node tools/capture-wasm4-screenshot.js <cart.wasm> <out.png>

const { loadCart } = require('./wasm4-harness.js');

async function main() {
  const [, , cartPath, outPath] = process.argv;
  if (!cartPath || !outPath) {
    console.error('Usage: node tools/capture-wasm4-screenshot.js <cart.wasm> <out.png>');
    process.exit(1);
  }

  const h = await loadCart(cartPath);
  if (!h.debug) {
    console.error(`${cartPath} has no debug exports -- build it without --release=small first.`);
    process.exit(1);
  }

  // title -> mode_select (game_mode defaults to .quick)
  h.pressButton1();
  h.step(10);
  // mode_select -> setup_character
  h.pressButton1();
  h.step(10);
  // setup_character -> confirms player_character (defaults to 0), starts
  // the confirm flash (SETUP_FLASH_TOTAL_FRAMES = 24)
  h.pressButton1();
  h.step(60);
  // setup_cpu_reveal's spin plays out on its own (CPU_REVEAL_STEPS = 10,
  // growing hold each step, ~165 frames total) -> setup_difficulty
  h.step(220);
  // setup_difficulty -> confirms difficulty (defaults to 1), starts the
  // countdown (COUNTDOWN_TOTAL_FRAMES, ~230 frames)
  h.pressButton1();
  h.step(300);

  // Real gameplay is running now (s.started == true). Paint a curated board
  // state directly rather than waiting for the (very slow) rise mechanic to
  // organically fill the screen -- see debug.setCell's own doc comment.
  // CellState.normal == 1 (see state.zig); colors are 0..NUM_COLORS-1 (5).
  const NORMAL = 1;
  const NUM_COLORS = 5;
  const VISIBLE_ROWS = 12;
  const SPAWN_ROWS = 10;
  const COLS = 6;
  const PAINT_ROWS = 8; // bottom 8 of the 12 visible rows

  function paintBoard(board) {
    for (let r = 0; r < PAINT_ROWS; r++) {
      const logicalRow = SPAWN_ROWS + (VISIBLE_ROWS - PAINT_ROWS) + r;
      for (let col = 0; col < COLS; col++) {
        // A simple diagonal-striped color cycle -- varied and colorful
        // without ever forming a run of 3, so it doesn't visually read as
        // "why hasn't this matched yet".
        const color = (col + r * 2) % NUM_COLORS;
        h.debug.setCell(board, logicalRow, col, color, NORMAL);
      }
    }
  }
  paintBoard(0); // player
  paintBoard(1); // cpu
  h.step(1); // render one frame with the painted board

  h.screenshot(outPath, 1); // scale=1 for an exact 160x160 PNG
  console.log(`Wrote ${outPath}`);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
