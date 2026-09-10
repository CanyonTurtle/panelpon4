// Shared harness for driving a compiled WASM-4 cart headlessly from Node, for
// scripted test scenarios, screenshots, and fuzzing. Faithfully reimplements
// just enough of the WASM4 host API to make rendering (rect/blit/text) and
// input (gamepad/mouse) behave the same as a real WASM4 runtime -- blit and
// text are direct ports of WASM4's own reference implementation (runtimes/
// native/src/framebuffer.c, including its actual font, see FONT below), so
// 1BPP/2BPP sprites, real glyphs, and DRAW_COLORS indirection all work
// exactly as they would in-browser -- screenshots show real, readable text,
// so text layout bugs (overflow, overlap) are visible here too.
//
// Usage:
//   const { loadCart, BUTTON_1 } = require('./tools/wasm4-harness.js');
//   const h = await loadCart('zig-out/bin/cart.wasm'); // calls start() for you
//   h.pressButton1();             // get past the title screen
//   h.debug.clearBoard();         // only available on a Debug build (src/debug.zig)
//   h.debug.setCell(0, 5, 0, 1, 1); // board 0 = player, 1 = cpu
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

// WASM4's actual 8x8 1BPP system font, vendored byte-for-byte from
// runtimes/native/src/framebuffer.c (aduros/wasm4, as of commit 82e4dcd6,
// 2024-05-13) -- 224 glyphs (char codes 32-255), 8 bytes each, one row per
// byte MSB-first. Lets screenshots show real, readable menu text instead of
// a tick-per-character placeholder, so text layout bugs (overflow, overlap)
// are actually visible here instead of only in a real WASM4 host.
const FONT = Buffer.from(
  '///////////Hx8fPz//P/5OTk///////kwGTk5MBk//vgy+D6QPv/51bN+/ZtXP/jycnjyUzgf/Pz8////////Pnz8/P5/P/n8/n' +
  '5+fPn///k8cBx5P////n54Hn5//////////Pz5////+B////////////z8///fv379+/f//Hszk5OZvH/+fH5+fn54H/gznxw4cf' +
  'Af+B8+fD+TmD/+PDkzMB8/P/Az8D+fk5g//Dnz8DOTmD/wE58+fPz8//hzsbh2F5g/+DOTmB+fOH///Pz//Pz////8/P/8/Pn//z' +
  '58+fz+fz////Af8B////n8/n8+fPn/+DATnzx//H/4N9RVVBf4P/x5M5OQE5Of8DOTkDOTkD/8OZPz8/mcP/BzM5OTkzB/8BPz8D' +
  'Pz8B/wE/PwM/Pz//wZ8/MTmZwf85OTkBOTk5/4Hn5+fn54H/+fn5+fk5g/85MycPByMx/5+fn5+fn4H/OREBASk5Of85GQkBITE5' +
  '/4M5OTk5OYP/Azk5OQM/P/+DOTk5ITOF/wM5OTEHIzH/hzM/g/k5g/+B5+fn5+fn/zk5OTk5OYP/OTk5EYPH7/85OSkBARE5/zkR' +
  'g8eDETn/mZmZw+fn5/8B8ePHjx8B/8PPz8/Pz8P/f7/f7/f7/f+H5+fn5+eH/8eT/////////////////wHv9///////////g/mB' +
  'OYH/Pz8DOTk5g////4E/Pz+B//n5gTk5OYH///+DOQE/g//x54Hn5+fn////gTk5gfmDPz8DOTk5Of/n/8fn5+eB//P/4/Pz8/OH' +
  'Pz8xAwcjMf/H5+fn5+eB////A0lJSUn///8DOTk5Of///4M5OTmD////Azk5Az8///+BOTmB+fn//5GPn5+f////gz+D+QP/5+eB' +
  '5+fn5////zk5OTmB////mZmZw+f///9JSUlJgf///zkBxwE5////OTk5gfmD//8B48ePAf/z5+fP5+fz/+fn5+fn5+f/n8/P58/P' +
  'n////49F4///////////k5P/gykpESkpg/+DOQkRITmD//////////////////////+DESF9IRGD/4MRCX0JEYP/gxE5VRERg/+D' +
  'ERFVORGD////////////////////////////////////////////////////////////////////////////////////////////' +
  '////////////////////////////////////////////////////////////////////////////////////////////////////' +
  '////////////////////////////////////////////////////////////////////////////5//n58fHx//vgykvKYPv/8OZ' +
  'nwOfnwH//6Xb29ul//+ZmcOB54Hn/+fn5//n5+f/w5mH2+GZw/+T/////////8O9Zl5eZr3Dh8OTw///////yZMnk8n/////gfn5' +
  '///////////////DvUZaRlq9w4P/////////79fv///////n54Hn5/+B/8fz58P/////w+fzx//////37///////////MzMzMwk/' +
  'wZW1lcH19f/////Pz/////////////fP58fnw//////Hk5PH//////8nk8mTJ///vTu3rdmxff+9O7ep3btx/x271y3ZsX3/x//H' +
  'nzkBg//f78eTOQE5//fvx5M5ATn/x5PHkzkBOf/Lp8eTOQE5/5P/x5M5ATn/79fHkzkBOf/BhychBych/8OZPz+Zw/fP3+8BPwM/' +
  'Af/37wE/Az8B/8eTAT8DPwH/k/8BPwM/Af/v94Hn5+eB//fvgefn54H/58OB5+fngf+Z/4Hn5+eB/4eTmQmZk4f/y6cZCQEhMf/f' +
  '74M5OTmD//fvgzk5OYP/x5ODOTk5g//Lp4M5OTmD/5P/gzk5OYP//7vX79e7//+DOTEpGTmD/9/vOTk5OYP/9+85OTk5g//Hk/85' +
  'OTmD/5P/OTk5OYP/9++ZmcPn5/8/Azk5OQM//8OZmZOZiZP/3++D+YE5gf/374P5gTmB/8eTg/mBOYH/y6eD+YE5gf+T/4P5gTmB' +
  '/+/Xg/mBOYH///+D6YEvg////4E/P4H3z9/vgzkBP4P/9++DOQE/g//Hk4M5AT+D/5P/gzkBP4P/3+//x+fngf/37//H5+eB/8eT' +
  '/8fn54H/k//H5+fngf+bh2eDOTmD/8unAzk5OTn/3++DOTk5g//374M5OTmD/8eTgzk5OYP/y6eDOTk5g/+T/4M5OTmD///n/4H/' +
  '5/////+DMSkZg//f7zk5OTmB//fvOTk5OYH/x5P/OTk5gf+T/zk5OTmB//fvOTk5gfmDPz8DOTkDPz+T/zk5OYH5gw==',
  'base64'
);

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

  // Draws one 8x8 1BPP glyph from FONT, byte-for-byte the same unpacking as
  // doBlit's 1BPP branch (bit 0 -> DRAW_COLORS low nibble, bit 1 -> high
  // nibble -- 0 in either means transparent), just reading FONT instead of
  // wasm memory since the font isn't part of the cart's own linear memory.
  function blitGlyph(code, dstX, dstY, colors) {
    const srcY = (code - 32) * 8;
    for (let row = 0; row < 8; row++) {
      const ty = dstY + row;
      if (ty < 0 || ty >= SCREEN) continue;
      const byte = FONT[srcY + row];
      for (let col = 0; col < 8; col++) {
        const tx = dstX + col;
        if (tx < 0 || tx >= SCREEN) continue;
        const bit = (byte >> (7 - col)) & 1;
        const paletteDc = (colors >> (bit << 2)) & 0xf;
        if (paletteDc !== 0) setPixel(tx, ty, (paletteDc - 1) & 0x3);
      }
    }
  }

  // Faithful port of WASM4's framebufferTextUtf8 (runtimes/native/src/
  // framebuffer.c): despite the name, it walks raw bytes (32-255 -> a glyph,
  // 10 -> newline, anything else just advances the cursor), not a real UTF-8
  // decode -- multi-byte sequences render as individual mis-glyphed bytes in
  // the real runtime too, so this matches rather than "fixes" that.
  function doText(ptr, len, x, y, colors) {
    let currentX = x;
    for (let i = 0; i < len; i++) {
      const code = mem8[ptr + i];
      if (code === 10) {
        y += 8;
        currentX = x;
        continue;
      }
      if (code >= 32 && code <= 255) blitGlyph(code, currentX, y, colors);
      currentX += 8;
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
    textUtf8: (ptr, len, x, y) => doText(ptr, len, x, y, view.getUint16(DRAW_COLORS_ADDR, true)),
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
  // `if (h.debug)` rather than crashing against a release build. Every
  // function (other than clearBoard, which resets both) takes a `board`
  // selector: 0 = player, anything else = cpu (see src/debug.zig).
  const debug = e.debugClearBoard ? {
    clearBoard: () => e.debugClearBoard(),
    setCell: (board, row, col, color, state) => e.debugSetCell(board, row, col, color, state),
    setCursor: (board, col, row) => e.debugSetCursor(board, col, row),
    getChain: (board) => e.debugGetChain(board),
    getCellInfo: (board, row, col) => e.debugGetCellInfo(board, row, col),
    // 0 = none, 1 = player, 2 = cpu, 3 = draw (see state.Winner)
    getWinner: () => e.debugGetWinner(),
    getCursorPos: (board) => {
      const v = e.debugGetCursorPos(board);
      return { col: v & 0xff, row: (v >> 8) & 0xff };
    },
    setGameOver: (board, over) => e.debugSetGameOver(board, over ? 1 : 0),
    // 0=intro, 1=move, 2=swap, 3=match, 4=chain, 5=garbage, 6=raise, 7=outro
    setTutorialStep: (step) => e.debugSetTutorialStep(step),
    // 0=title, 1=mode_select, 2=setup_character, 3=setup_cpu_reveal,
    // 4=setup_difficulty, 5=story_tier_select, 6=versus_confirm (state.MenuPhase)
    setMenuPhase: (phase) => e.debugSetMenuPhase(phase),
    // 0=none, 1=character_select, 2=walk_transition (state.StoryFlowStep)
    setStoryFlowStep: (step) => e.debugSetStoryFlowStep(step),
  } : undefined;

  return { e, mem8, view, memory, setGamepad, setMouse, step, pressButton1, screenshot, debug };
}

module.exports = {
  loadCart,
  BUTTON_1, BUTTON_2, BUTTON_LEFT, BUTTON_RIGHT, BUTTON_UP, BUTTON_DOWN,
  MOUSE_LEFT, MOUSE_RIGHT, MOUSE_MIDDLE,
};
