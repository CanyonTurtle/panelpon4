// Regenerates src/logo.zig's glyph bitmaps: each letter is built from a few
// filled rectangles, then every true outer 90-degree corner still present
// after that (both orthogonal neighbors framing it empty) is rounded off --
// run `node tools/make-logo.js` and paste the printed glyphs back in.
//
// To add a glyph: add a block below with its rectangles, then add it to
// zigNames and the word-order loop.

const W = 12, H = 14;

function blank() {
  return Array.from({ length: H }, () => Array(W).fill(0));
}
function fillRect(g, x, y, w, h) {
  for (let yy = y; yy < y + h; yy++)
    for (let xx = x; xx < x + w; xx++)
      if (yy >= 0 && yy < H && xx >= 0 && xx < W) g[yy][xx] = 1;
}
function clearRect(g, x, y, w, h) {
  for (let yy = y; yy < y + h; yy++)
    for (let xx = x; xx < x + w; xx++)
      if (yy >= 0 && yy < H && xx >= 0 && xx < W) g[yy][xx] = 0;
}
function roundCorners(g, passes) {
  let cur = g;
  for (let p = 0; p < passes; p++) {
    const next = cur.map(row => row.slice());
    for (let y = 0; y < H; y++) for (let x = 0; x < W; x++) {
      if (!cur[y][x]) continue;
      const up = y > 0 && cur[y - 1][x];
      const down = y < H - 1 && cur[y + 1][x];
      const left = x > 0 && cur[y][x - 1];
      const right = x < W - 1 && cur[y][x + 1];
      if ((!up && !left) || (!up && !right) || (!down && !left) || (!down && !right)) {
        next[y][x] = 0;
      }
    }
    cur = next;
  }
  return cur;
}

const glyphs = {};
glyphs.P = (() => { const g = blank(); fillRect(g, 0, 0, 3, 14); fillRect(g, 0, 0, 12, 3); fillRect(g, 9, 0, 3, 7); fillRect(g, 0, 4, 12, 3); return g; })();
glyphs.A = (() => { const g = blank(); fillRect(g, 4, 0, 4, 3); fillRect(g, 1, 3, 4, 3); fillRect(g, 7, 3, 4, 3); fillRect(g, 0, 6, 3, 8); fillRect(g, 9, 6, 3, 8); fillRect(g, 0, 9, 12, 3); return g; })();
glyphs.N = (() => { const g = blank(); fillRect(g, 0, 0, 3, 14); fillRect(g, 9, 0, 3, 14); fillRect(g, 2, 2, 3, 3); fillRect(g, 4, 5, 3, 3); fillRect(g, 6, 8, 3, 3); fillRect(g, 8, 10, 3, 3); return g; })();
glyphs.E = (() => { const g = blank(); fillRect(g, 0, 0, 3, 14); fillRect(g, 0, 0, 12, 3); fillRect(g, 0, 5, 9, 3); fillRect(g, 0, 11, 12, 3); return g; })();
glyphs.L = (() => { const g = blank(); fillRect(g, 0, 0, 3, 14); fillRect(g, 0, 11, 12, 3); return g; })();
glyphs.O = (() => { const g = blank(); fillRect(g, 0, 0, 12, 14); clearRect(g, 3, 3, 6, 8); return g; })();
glyphs['4'] = (() => { const g = blank(); fillRect(g, 8, 0, 3, 14); fillRect(g, 0, 8, 12, 3); fillRect(g, 6, 0, 3, 3); fillRect(g, 4, 3, 3, 3); fillRect(g, 2, 6, 3, 3); return g; })();

const zigNames = { P: 'P', A: 'A', N: 'N', E: 'E', L: 'L', O: 'O', '4': 'FOUR' };
for (const [ch, raw] of Object.entries(glyphs)) {
  const fill = roundCorners(raw, 1);
  console.log(`const LOGO_${zigNames[ch]} = [LOGO_H][]const u8{`);
  for (let y = 0; y < H; y++) console.log(`    "${fill[y].map(v => v ? '#' : '.').join('')}",`);
  console.log(`};`);
}
