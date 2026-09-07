// Shared harness for driving a compiled WASM-4 cart headlessly from Node, for
// scripted test scenarios, screenshots, and fuzzing. Faithfully reimplements
// just enough of the WASM4 host API to make rendering (rect/blit/text) and
// input (gamepad/mouse) behave the same as a real WASM4 runtime -- blit in
// particular is a direct port of WASM4's own reference implementation
// (runtimes/native/src/framebuffer.c), so 1BPP/2BPP sprites and DRAW_COLORS
// indirection work exactly as they would in-browser.
//
// Usage:
//   const { loadCart, BUTTON_1 } = require('./tools/wasm4-harness.js');
//   const h = await loadCart('zig-out/bin/cart.wasm'); // calls start() for you
//   h.pressButton1();             // get past the title screen
//   h.debug.clearBoard();         // only available on a Debug build (src/debug.zig)
//   h.debug.setCell(5, 0, 1, 1);
//   h.step(10);
//   h.screenshot('/tmp/out.png');
//
// A release build (`zig build --release=small`) has no debug exports, so
// `h.debug` is `undefined` there -- check before using it.

const fs = require('fs');
const zlib = require('zlib');

const SCREEN = 160;
const DRAW_COLORS_ADDR = 0x14;
const PALETTE_ADDR = 0x04;
const FRAMEBUFFER_ADDR = 0xa0;
const GAMEPAD1_ADDR = 0x16;
const MOUSE_X_ADDR = 0x1a;
const MOUSE_Y_ADDR = 0x1c;
const MOUSE_BUTTONS_ADDR = 0x1e;

const BUTTON_1 = 1, BUTTON_2 = 2, BUTTON_LEFT = 16, BUTTON_RIGHT = 32, BUTTON_UP = 64, BUTTON_DOWN = 128;
const MOUSE_LEFT = 1, MOUSE_RIGHT = 2, MOUSE_MIDDLE = 4;

// ---- Minimal PNG encoder (no dependencies) --------------------------------

function crc32(buf) {
  let c;
  const table = crc32.table || (crc32.table = (() => {
    const t = [];
    for (let n = 0; n < 256; n++) {
      c = n;
      for (let k = 0; k < 8; k++) c = c & 1 ? (0xedb88320 ^ (c >>> 1)) : (c >>> 1);
      t[n] = c >>> 0;
    }
    return t;
  })());
  let crc = 0xffffffff;
  for (let i = 0; i < buf.length; i++) crc = table[(crc ^ buf[i]) & 0xff] ^ (crc >>> 8);
  return (crc ^ 0xffffffff) >>> 0;
}

function chunk(type, data) {
  const len = Buffer.alloc(4);
  len.writeUInt32BE(data.length, 0);
  const typeData = Buffer.concat([Buffer.from(type, 'ascii'), data]);
  const crc = Buffer.alloc(4);
  crc.writeUInt32BE(crc32(typeData), 0);
  return Buffer.concat([len, typeData, crc]);
}

function encodePNG(width, height, rgba) {
  const sig = Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]);
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(width, 0);
  ihdr.writeUInt32BE(height, 4);
  ihdr[8] = 8; // bit depth
  ihdr[9] = 6; // color type RGBA
  const stride = width * 4;
  const raw = Buffer.alloc((stride + 1) * height);
  for (let y = 0; y < height; y++) {
    raw[y * (stride + 1)] = 0; // filter: none
    rgba.copy(raw, y * (stride + 1) + 1, y * stride, y * stride + stride);
  }
  const idat = zlib.deflateSync(raw);
  return Buffer.concat([sig, chunk('IHDR', ihdr), chunk('IDAT', idat), chunk('IEND', Buffer.alloc(0))]);
}

// ---- Cart loading ----------------------------------------------------

async function loadCart(wasmPath) {
  const bytes = fs.readFileSync(wasmPath);
  const memory = new WebAssembly.Memory({ initial: 1, maximum: 1 });
  const mem8 = new Uint8Array(memory.buffer);
  const view = new DataView(memory.buffer);

  function paletteColor(slot) {
    const v = view.getUint32(PALETTE_ADDR + slot * 4, true);
    return [(v >> 16) & 0xff, (v >> 8) & 0xff, v & 0xff];
  }

  function setPixel(x, y, colorIdx) {
    if (x < 0 || x >= SCREEN || y < 0 || y >= SCREEN) return;
    const idx = y * 40 + (x >> 2);
    const shift = (x & 3) * 2;
    const addr = FRAMEBUFFER_ADDR + idx;
    let byte = mem8[addr];
    byte = (byte & ~(0b11 << shift)) | ((colorIdx & 0b11) << shift);
    mem8[addr] = byte;
  }

  // Fill/stroke semantics ported from WASM4's framebufferRect: DRAW_COLORS
  // color1 fills, color2 strokes a 1px border (0 in either nibble means
  // "don't draw that part"). hline/vline/oval all reuse this as a rough
  // approximation -- close enough for verifying position/extent, not
  // pixel-perfect ellipses.
  function doRect(x, y, w, h) {
    const dc = view.getUint16(DRAW_COLORS_ADDR, true);
    const color1 = dc & 0xf, color2 = (dc >> 4) & 0xf;
    for (let yy = y; yy < y + h; yy++) {
      for (let xx = x; xx < x + w; xx++) {
        const onEdge = xx === x || xx === x + w - 1 || yy === y || yy === y + h - 1;
        if (onEdge && color2 !== 0) setPixel(xx, yy, color2 - 1);
        else if (color1 !== 0) setPixel(xx, yy, color1 - 1);
      }
    }
  }

  // Faithful port of WASM4's framebufferBlit (runtimes/native/src/framebuffer.c):
  // sprite bits are a continuous MSB-first bitstream (bitIndex = sy*stride+sx,
  // shift = 7-(bitIndex&7) for 1BPP), the resulting value indexes into
  // DRAW_COLORS (bit/value 0 -> color1, 1 -> color2, etc.), and a DRAW_COLORS
  // nibble of 0 means transparent (skip the pixel).
  function doBlit(spritePtr, dstX, dstY, width, height, srcX, srcY, srcStride, flags) {
    const bpp2 = (flags & 1) !== 0;
    let flipX = (flags & 2) !== 0;
    const flipY = (flags & 4) !== 0;
    const rotate = (flags & 8) !== 0;
    const colors = view.getUint16(DRAW_COLORS_ADDR, true);

    let clipXMin, clipYMin, clipXMax, clipYMax;
    if (rotate) {
      flipX = !flipX;
      clipXMin = Math.max(0, dstY) - dstY;
      clipYMin = Math.max(0, dstX) - dstX;
      clipXMax = Math.min(width, SCREEN - dstY);
      clipYMax = Math.min(height, SCREEN - dstX);
    } else {
      clipXMin = Math.max(0, dstX) - dstX;
      clipYMin = Math.max(0, dstY) - dstY;
      clipXMax = Math.min(width, SCREEN - dstX);
      clipYMax = Math.min(height, SCREEN - dstY);
    }

    for (let y = clipYMin; y < clipYMax; y++) {
      for (let x = clipXMin; x < clipXMax; x++) {
        const tx = dstX + (rotate ? y : x);
        const ty = dstY + (rotate ? x : y);
        const sx = srcX + (flipX ? width - x - 1 : x);
        const sy = srcY + (flipY ? height - y - 1 : y);

        let colorIdx;
        const bitIndex = sy * srcStride + sx;
        if (bpp2) {
          const byte = mem8[spritePtr + (bitIndex >> 2)];
          colorIdx = (byte >> (6 - ((bitIndex & 3) << 1))) & 0x3;
        } else {
          const byte = mem8[spritePtr + (bitIndex >> 3)];
          colorIdx = (byte >> (7 - (bitIndex & 7))) & 0x1;
        }
        const paletteDc = (colors >> (colorIdx << 2)) & 0xf;
        if (paletteDc !== 0) setPixel(tx, ty, (paletteDc - 1) & 0x3);
      }
    }
  }

  // Approximate: draws a dim tick per character so text position/extent is
  // visible in a screenshot, rather than rendering WASM4's actual font
  // glyphs (not worth porting for a test harness -- string *content* is
  // better verified with a Zig unit test than a screenshot anyway).
  function doText(x, y, len, color1) {
    if (color1 === 0) return;
    for (let i = 0; i < len; i++) {
      for (let yy = 0; yy < 8; yy += 3) setPixel(x + i * 8 + 1, y + yy, color1 - 1);
    }
  }

  const env = {
    memory,
    blit: (p, x, y, w, h, flags) => doBlit(p, x, y, w, h, 0, 0, w, flags),
    blitSub: (p, x, y, w, h, sx, sy, stride, flags) => doBlit(p, x, y, w, h, sx, sy, stride, flags),
    line() {},
    hline: (x, y, len) => doRect(x, y, len, 1),
    vline: (x, y, len) => doRect(x, y, 1, len),
    oval: (x, y, w, h) => doRect(x, y, w, h),
    rect: (x, y, w, h) => doRect(x, y, w, h),
    textUtf8: (ptr, len, x, y) => doText(x, y, len, view.getUint16(DRAW_COLORS_ADDR, true) & 0xf),
    tone() {},
    diskr: () => 0,
    diskw: () => 0,
    trace() {},
  };

  const { instance } = await WebAssembly.instantiate(bytes, { env });
  const e = instance.exports;
  e.start();

  function setGamepad(mask) { mem8[GAMEPAD1_ADDR] = mask; }
  function setMouse(x, y, buttonsMask) {
    view.setInt16(MOUSE_X_ADDR, x, true);
    view.setInt16(MOUSE_Y_ADDR, y, true);
    mem8[MOUSE_BUTTONS_ADDR] = buttonsMask || 0;
  }
  function step(n = 1, gamepad = 0) {
    for (let i = 0; i < n; i++) { setGamepad(gamepad); e.update(); }
  }
  // Presses then releases BUTTON_1 for one frame each -- gets past the title
  // screen, or performs a swap/confirm when already in play.
  function pressButton1() {
    setGamepad(BUTTON_1); e.update();
    setGamepad(0); e.update();
  }
  // region: optional {x, y, w, h} in screen pixels to crop before scaling --
  // handy for zooming into a small UI element (like a badge) at a large
  // scale without producing a huge full-screen image.
  function screenshot(path, scale = 3, region) {
    const rx = region ? region.x : 0, ry = region ? region.y : 0;
    const rw = region ? region.w : SCREEN, rh = region ? region.h : SCREEN;
    const outW = rw * scale, outH = rh * scale;
    const rgba = Buffer.alloc(outW * outH * 4);
    for (let y = 0; y < rh; y++) {
      for (let x = 0; x < rw; x++) {
        const sx0 = rx + x, sy0 = ry + y;
        const idx = sy0 * 40 + (sx0 >> 2);
        const shift = (sx0 & 3) * 2;
        const colorIdx = (mem8[FRAMEBUFFER_ADDR + idx] >> shift) & 0b11;
        const [r, g, b] = paletteColor(colorIdx);
        for (let sy = 0; sy < scale; sy++) {
          for (let sx = 0; sx < scale; sx++) {
            const ox = x * scale + sx, oy = y * scale + sy;
            const o = (oy * outW + ox) * 4;
            rgba[o] = r; rgba[o + 1] = g; rgba[o + 2] = b; rgba[o + 3] = 255;
          }
        }
      }
    }
    fs.writeFileSync(path, encodePNG(outW, outH, rgba));
    return path;
  }

  // The debugXxx exports only exist on a Debug build (see src/debug.zig) --
  // exposed here as `.debug` only when present, so scripts can branch on
  // `if (h.debug)` rather than crashing against a release build.
  const debug = e.debugClearBoard ? {
    clearBoard: () => e.debugClearBoard(),
    setCell: (row, col, color, state) => e.debugSetCell(row, col, color, state),
    setCursor: (col, row) => e.debugSetCursor(col, row),
    getChain: () => e.debugGetChain(),
    getCellInfo: (row, col) => e.debugGetCellInfo(row, col),
  } : undefined;

  return { e, mem8, view, memory, setGamepad, setMouse, step, pressButton1, screenshot, debug };
}

module.exports = {
  loadCart,
  BUTTON_1, BUTTON_2, BUTTON_LEFT, BUTTON_RIGHT, BUTTON_UP, BUTTON_DOWN,
  MOUSE_LEFT, MOUSE_RIGHT, MOUSE_MIDDLE,
};
