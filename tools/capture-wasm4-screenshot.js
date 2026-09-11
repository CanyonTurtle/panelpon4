#!/usr/bin/env node
// Captures the 160x160 title-screen screenshot used both as the
// wasm4.org submission image and the release notes' hero image (see
// wasm4/manual.md and the release workflow) -- reuses wasm4-harness.js's
// pure-Node WASM4 host (no browser needed). No debug exports or button
// presses needed: main.zig's updateTitleDemo plays both boards against
// each other via cpu_ai the moment the cart boots, so this runs fine
// against the actual release cart. Stepping forward a few seconds first
// gives the attract-mode boards (and the bubble-letter logo's bob, see
// render_screens.zig's titleLogoBob) something more lively to show off
// than an empty frame-0 board.
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
  // Let attract-mode play out a few seconds so both boards have pieces on
  // them and a match or two has happened, rather than shooting frame 0.
  h.step(260);
  h.screenshot(outPath, 1); // scale=1 for an exact 160x160 PNG
  console.log(`Wrote ${outPath}`);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
