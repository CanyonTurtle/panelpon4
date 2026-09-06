// Minimal WASM-4 API bindings for Zig.
// See https://wasm4.org/docs/reference/functions for the full reference.

pub const SCREEN_SIZE: u32 = 160;

// -- Memory-mapped registers --------------------------------------------

pub const PALETTE: *[4]u32 = @ptrFromInt(0x04);
pub const DRAW_COLORS: *u16 = @ptrFromInt(0x14);
pub const GAMEPAD1: *const u8 = @ptrFromInt(0x16);
pub const GAMEPAD2: *const u8 = @ptrFromInt(0x17);
pub const GAMEPAD3: *const u8 = @ptrFromInt(0x18);
pub const GAMEPAD4: *const u8 = @ptrFromInt(0x19);
pub const MOUSE_X: *const i16 = @ptrFromInt(0x1a);
pub const MOUSE_Y: *const i16 = @ptrFromInt(0x1c);
pub const MOUSE_BUTTONS: *const u8 = @ptrFromInt(0x1e);
pub const SYSTEM_FLAGS: *u8 = @ptrFromInt(0x1f);
pub const FRAMEBUFFER: *[6400]u8 = @ptrFromInt(0xa0);

pub const BUTTON_1: u8 = 1;
pub const BUTTON_2: u8 = 2;
pub const BUTTON_LEFT: u8 = 16;
pub const BUTTON_RIGHT: u8 = 32;
pub const BUTTON_UP: u8 = 64;
pub const BUTTON_DOWN: u8 = 128;

pub const SYSTEM_PRESERVE_FRAMEBUFFER: u8 = 1;
pub const SYSTEM_HIDE_GAMEPAD_OVERLAY: u8 = 2;

pub const BLIT_2BPP: u32 = 1;
pub const BLIT_1BPP: u32 = 0;
pub const BLIT_FLIP_X: u32 = 2;
pub const BLIT_FLIP_Y: u32 = 4;
pub const BLIT_ROTATE: u32 = 8;

// -- Host functions --------------------------------------------------------

extern "env" fn blit(sprite: [*]const u8, x: i32, y: i32, width: u32, height: u32, flags: u32) void;
extern "env" fn blitSub(sprite: [*]const u8, x: i32, y: i32, width: u32, height: u32, srcX: u32, srcY: u32, stride: u32, flags: u32) void;
extern "env" fn line(x1: i32, y1: i32, x2: i32, y2: i32) void;
extern "env" fn hline(x: i32, y: i32, len: u32) void;
extern "env" fn vline(x: i32, y: i32, len: u32) void;
extern "env" fn oval(x: i32, y: i32, width: u32, height: u32) void;
extern "env" fn rect(x: i32, y: i32, width: u32, height: u32) void;
extern "env" fn text(str: [*]const u8, x: i32, y: i32) void;
extern "env" fn textUtf8(str: [*]const u8, byteLength: u32, x: i32, y: i32) void;
extern "env" fn tone(frequency: u32, duration: u32, volume: u32, flags: u32) void;
extern "env" fn diskr(dest: [*]u8, size: u32) u32;
extern "env" fn diskw(src: [*]const u8, size: u32) u32;
extern "env" fn trace(str: [*]const u8) void;

pub const Blit = blit;
pub const BlitSub = blitSub;
pub const Line = line;
pub const Hline = hline;
pub const Vline = vline;
pub const Oval = oval;
pub const Rect = rect;
pub const Tone = tone;
pub const Diskr = diskr;
pub const Diskw = diskw;

pub fn Text(str: []const u8, x: i32, y: i32) void {
    textUtf8(str.ptr, str.len, x, y);
}

pub fn Trace(str: [:0]const u8) void {
    trace(str.ptr);
}

pub const TONE_PULSE1: u32 = 0;
pub const TONE_PULSE2: u32 = 1;
pub const TONE_TRIANGLE: u32 = 2;
pub const TONE_NOISE: u32 = 3;
pub const TONE_MODE1: u32 = 0;
pub const TONE_MODE2: u32 = 4;
pub const TONE_MODE3: u32 = 8;
pub const TONE_MODE4: u32 = 12;
pub const TONE_PAN_LEFT: u32 = 16;
pub const TONE_PAN_RIGHT: u32 = 32;
pub const TONE_NOTE_MODE: u32 = 64;
