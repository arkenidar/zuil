//! ZUIL — Zig implementation. Twin of src/zuil.c behind the same contract;
//! the two stay in lockstep (the M1 desktop slice lives in both). Everything is
//! exported through the `include/zuil.h` contract as `export fn … callconv(.c)`,
//! which emits a plain C ABI — the LuaJIT / PUC-Lua / C consumers cannot tell it
//! isn't C.
//!
//! M1 desktop slice: a poll-style, callback-free window + draw + input
//! mechanism. The consumer owns the loop (frame_begin/frame_end); input is read
//! as a derived per-frame snapshot through accessor functions. Spike E (the
//! synthetic event struct + queue at the bottom of this file) measures the
//! raw-struct-vs-accessor cost the snapshot sidestepped — see docs/m1.md §3.
const std = @import("std");
const c = @import("cdefs");

/// Returns the linked SDL3 version as a packed int (e.g. 3.2.10 -> 3002010).
export fn zuil_sdl_version() callconv(.c) c_int {
    return c.SDL_GetVersion();
}

// --- module state (the de-facto idiomatic "core" behind the C-ABI veneer) ---

var g_win: ?*c.SDL_Window = null;
var g_ren: ?*c.SDL_Renderer = null;

// input snapshot
var g_mx: i32 = 0;
var g_my: i32 = 0;
var g_down = std.mem.zeroes([8]bool); // held this frame, indexed by button (1..3)
var g_pressed = std.mem.zeroes([8]bool); // edge: down this frame
var g_released = std.mem.zeroes([8]bool); // edge: up this frame
var g_key = std.mem.zeroes([512]bool); // edge: scancode down this frame
var g_quit: bool = false;

// translation stack (translation only — no scale in this slice)
var g_tx: f32 = 0;
var g_ty: f32 = 0;
var g_xform_stack = std.mem.zeroes([32][2]f32);
var g_xform_len: usize = 0;

// clip stack (rects already offset into device space)
var g_clip_stack = std.mem.zeroes([32]c.SDL_Rect);
var g_clip_len: usize = 0;

// current draw color, cached so draw_text can tint the (white) glyph atlas with
// the same color set_color last applied to the renderer.
var g_col = [4]u8{ 0, 0, 0, 255 };

// --- text / bitmap font ---------------------------------------------------
// The font is the public-domain 8x8 ASCII page baked at build of tools/
// gen_font8x8.py and @embedFile'd here (the C twin #includes src/font8x8.h —
// identical 768 bytes). NOT SDL3_ttf: zero extra deps, web/Android-friendly.
const font_bin = @embedFile("font8x8.bin");
const FONT_FIRST = 0x20; // first code point in the baked page
const FONT_COUNT = 96; // U+0020..U+007F (last cell is the fallback box)
const FONT_CELL = 8; // 8x8 glyph cell
const ATLAS_COLS = 16; // glyph grid: 16 x 6 = 96 cells
const ATLAS_ROWS = FONT_COUNT / ATLAS_COLS;

// One font PAGE = one glyph-grid texture. Array form from day one so the later
// big high-detail atlas can add bold/italic pages without touching draw_text;
// today only page 0 (regular) exists.
const FontPage = struct { tex: ?*c.SDL_Texture = null, cols: c_int = ATLAS_COLS };
var g_pages = [1]FontPage{.{}};
var g_font_scale: f32 = 1.0;

inline fn dx(x: f32) f32 {
    return x + g_tx;
}
inline fn dy(y: f32) f32 {
    return y + g_ty;
}

// --- window + frame pump --------------------------------------------------

export fn zuil_window_open(title: [*c]const u8, w: c_int, h: c_int) callconv(.c) c_int {
    if (!c.SDL_Init(c.SDL_INIT_VIDEO)) return -1;
    g_win = c.SDL_CreateWindow(title, w, h, 0);
    if (g_win == null) return -2;
    g_ren = c.SDL_CreateRenderer(g_win, null);
    if (g_ren == null) return -3;
    return 0;
}

export fn zuil_window_close() callconv(.c) void {
    for (&g_pages) |*pg| { // free glyph textures; nulled so they rebuild lazily
        if (pg.tex) |t| c.SDL_DestroyTexture(t);
        pg.tex = null;
    }
    if (g_ren) |r| c.SDL_DestroyRenderer(r);
    if (g_win) |win| c.SDL_DestroyWindow(win);
    g_ren = null;
    g_win = null;
    c.SDL_Quit();
}

export fn zuil_frame_begin() callconv(.c) c_int {
    // clear per-frame edges
    g_pressed = std.mem.zeroes([8]bool);
    g_released = std.mem.zeroes([8]bool);
    g_key = std.mem.zeroes([512]bool);

    var ev: c.SDL_Event = undefined;
    while (c.SDL_PollEvent(&ev)) {
        switch (ev.type) {
            c.SDL_EVENT_QUIT => g_quit = true,
            c.SDL_EVENT_MOUSE_BUTTON_DOWN => {
                const b: usize = ev.button.button;
                if (b < g_pressed.len) g_pressed[b] = true;
            },
            c.SDL_EVENT_MOUSE_BUTTON_UP => {
                const b: usize = ev.button.button;
                if (b < g_released.len) g_released[b] = true;
            },
            c.SDL_EVENT_KEY_DOWN => {
                if (!ev.key.repeat) {
                    const sc: usize = @intCast(ev.key.scancode);
                    if (sc < g_key.len) g_key[sc] = true;
                    if (ev.key.scancode == c.SDL_SCANCODE_ESCAPE) g_quit = true;
                }
            },
            else => {},
        }
    }

    // mouse position + held buttons from the current device state
    var fx: f32 = 0;
    var fy: f32 = 0;
    const mask = c.SDL_GetMouseState(&fx, &fy);
    g_mx = @intFromFloat(fx);
    g_my = @intFromFloat(fy);
    var b: u5 = 1;
    while (b <= 3) : (b += 1) {
        const bit = @as(u32, 1) << (b - 1);
        g_down[b] = (mask & bit) != 0;
    }

    return if (g_quit or g_win == null) 0 else 1;
}

export fn zuil_frame_end() callconv(.c) void {
    if (g_ren) |r| _ = c.SDL_RenderPresent(r);
}

// --- draw vocabulary ------------------------------------------------------

export fn zuil_set_color(r: f32, g: f32, b: f32, a: f32) callconv(.c) void {
    g_col = .{ to8(r), to8(g), to8(b), to8(a) }; // cache so draw_text can tint glyphs
    const ren = g_ren orelse return;
    _ = c.SDL_SetRenderDrawColor(ren, g_col[0], g_col[1], g_col[2], g_col[3]);
}

inline fn to8(v: f32) u8 {
    return @intFromFloat(std.math.clamp(v, 0.0, 1.0) * 255.0);
}

export fn zuil_clear() callconv(.c) void {
    if (g_ren) |r| _ = c.SDL_RenderClear(r);
}

export fn zuil_fill_rect(x: f32, y: f32, w: f32, h: f32) callconv(.c) void {
    const ren = g_ren orelse return;
    var rect = c.SDL_FRect{ .x = dx(x), .y = dy(y), .w = w, .h = h };
    _ = c.SDL_RenderFillRect(ren, &rect);
}

export fn zuil_draw_rect(x: f32, y: f32, w: f32, h: f32) callconv(.c) void {
    const ren = g_ren orelse return;
    var rect = c.SDL_FRect{ .x = dx(x), .y = dy(y), .w = w, .h = h };
    _ = c.SDL_RenderRect(ren, &rect);
}

export fn zuil_draw_line(x1: f32, y1: f32, x2: f32, y2: f32) callconv(.c) void {
    const ren = g_ren orelse return;
    _ = c.SDL_RenderLine(ren, dx(x1), dy(y1), dx(x2), dy(y2));
}

// --- bitmap text ----------------------------------------------------------

// Build page 0's glyph-grid texture once (lazy: needs the renderer). White ink
// + alpha so draw_text can tint it via color/alpha mod; BLEND so the
// transparent background shows through. Recreatable: window_close nulls it.
fn ensureAtlas() void {
    const ren = g_ren orelse return;
    if (g_pages[0].tex != null) return;

    const W = ATLAS_COLS * FONT_CELL; // 128
    const H = ATLAS_ROWS * FONT_CELL; // 48
    var px = std.mem.zeroes([W * H]u32); // RGBA32; white=0xFFFFFFFF, bg=0 (endian-agnostic)
    var i: usize = 0;
    while (i < FONT_COUNT) : (i += 1) {
        const gx = (i % ATLAS_COLS) * FONT_CELL;
        const gy = (i / ATLAS_COLS) * FONT_CELL;
        var row: usize = 0;
        while (row < FONT_CELL) : (row += 1) {
            const bits = font_bin[i * FONT_CELL + row];
            var col: u3 = 0;
            while (true) : (col += 1) {
                if ((bits >> col) & 1 != 0) // bit col (LSB) = leftmost column
                    px[(gy + row) * W + gx + col] = 0xFFFFFFFF;
                if (col == FONT_CELL - 1) break;
            }
        }
    }

    const tex = c.SDL_CreateTexture(ren, c.SDL_PIXELFORMAT_RGBA32, c.SDL_TEXTUREACCESS_STATIC, W, H) orelse return;
    _ = c.SDL_UpdateTexture(tex, null, &px, W * @sizeOf(u32));
    _ = c.SDL_SetTextureBlendMode(tex, c.SDL_BLENDMODE_BLEND);
    g_pages[0].tex = tex;
}

// Map a byte to its cell index, falling back to the box (last cell) for
// non-printable / non-ASCII (real UTF-8 decoding is the deferred next step).
inline fn cellIndex(ch: u8) usize {
    if (ch >= FONT_FIRST and ch <= 0x7E) return ch - FONT_FIRST;
    return FONT_COUNT - 1; // U+007F slot = fallback box
}

export fn zuil_set_font_scale(s: f32) callconv(.c) void {
    g_font_scale = s;
}

export fn zuil_draw_text(x: f32, y: f32, utf8: [*c]const u8) callconv(.c) void {
    const ren = g_ren orelse return;
    if (utf8 == null) return;
    ensureAtlas();
    const page = g_pages[0];
    const tex = page.tex orelse return;

    // Tint the white glyphs with the current draw color.
    _ = c.SDL_SetTextureColorMod(tex, g_col[0], g_col[1], g_col[2]);
    _ = c.SDL_SetTextureAlphaMod(tex, g_col[3]);

    const adv = @as(f32, FONT_CELL) * g_font_scale;
    const dim = @as(f32, FONT_CELL) * g_font_scale;
    var pen = x;
    var p: usize = 0;
    while (utf8[p] != 0) : (p += 1) {
        const ci = cellIndex(utf8[p]);
        const cgx: f32 = @floatFromInt((ci % ATLAS_COLS) * FONT_CELL);
        const cgy: f32 = @floatFromInt((ci / ATLAS_COLS) * FONT_CELL);
        var src = c.SDL_FRect{ .x = cgx, .y = cgy, .w = FONT_CELL, .h = FONT_CELL };
        var dst = c.SDL_FRect{ .x = dx(pen), .y = dy(y), .w = dim, .h = dim };
        _ = c.SDL_RenderTexture(ren, tex, &src, &dst);
        pen += adv;
    }
}

// --- text measurement (mechanism; user-space owns layout/caret policy) ----

inline fn glyphCount(utf8: [*c]const u8) usize {
    if (utf8 == null) return 0;
    var n: usize = 0;
    while (utf8[n] != 0) : (n += 1) {} // byte count for now; same when UTF-8 lands
    return n;
}

export fn zuil_font_advance() callconv(.c) f32 {
    return @as(f32, FONT_CELL) * g_font_scale; // the one true horizontal step
}

export fn zuil_text_width(utf8: [*c]const u8) callconv(.c) f32 {
    return @as(f32, @floatFromInt(glyphCount(utf8))) * zuil_font_advance();
}

export fn zuil_text_height() callconv(.c) f32 {
    return @as(f32, FONT_CELL) * g_font_scale;
}

// --- input snapshot accessors --------------------------------------------

export fn zuil_mouse_x() callconv(.c) c_int {
    return g_mx;
}
export fn zuil_mouse_y() callconv(.c) c_int {
    return g_my;
}
export fn zuil_mouse_down(button: c_int) callconv(.c) c_int {
    return boolBit(idx(button, &g_down));
}
export fn zuil_mouse_pressed(button: c_int) callconv(.c) c_int {
    return boolBit(idx(button, &g_pressed));
}
export fn zuil_mouse_released(button: c_int) callconv(.c) c_int {
    return boolBit(idx(button, &g_released));
}
export fn zuil_key_pressed(scancode: c_int) callconv(.c) c_int {
    if (scancode < 0 or scancode >= @as(c_int, g_key.len)) return 0;
    return boolBit(g_key[@intCast(scancode)]);
}
export fn zuil_should_quit() callconv(.c) c_int {
    return boolBit(g_quit);
}

inline fn boolBit(v: bool) c_int {
    return if (v) 1 else 0;
}
inline fn idx(button: c_int, arr: *const [8]bool) bool {
    if (button < 0 or button >= 8) return false;
    return arr[@intCast(button)];
}

// --- clip + translation stacks -------------------------------------------

export fn zuil_clip_push(x: f32, y: f32, w: f32, h: f32) callconv(.c) void {
    const ren = g_ren orelse return;
    var rect = c.SDL_Rect{
        .x = @intFromFloat(dx(x)),
        .y = @intFromFloat(dy(y)),
        .w = @intFromFloat(w),
        .h = @intFromFloat(h),
    };
    // intersect with the current clip (if any) so nesting behaves
    if (g_clip_len > 0) {
        var out = c.SDL_Rect{ .x = 0, .y = 0, .w = 0, .h = 0 };
        _ = c.SDL_GetRectIntersection(&rect, &g_clip_stack[g_clip_len - 1], &out);
        rect = out;
    }
    if (g_clip_len < g_clip_stack.len) {
        g_clip_stack[g_clip_len] = rect;
        g_clip_len += 1;
    }
    _ = c.SDL_SetRenderClipRect(ren, &rect);
}

export fn zuil_clip_pop() callconv(.c) void {
    const ren = g_ren orelse return;
    if (g_clip_len > 0) g_clip_len -= 1;
    if (g_clip_len > 0) {
        _ = c.SDL_SetRenderClipRect(ren, &g_clip_stack[g_clip_len - 1]);
    } else {
        _ = c.SDL_SetRenderClipRect(ren, null);
    }
}

export fn zuil_push() callconv(.c) void {
    if (g_xform_len < g_xform_stack.len) {
        g_xform_stack[g_xform_len] = .{ g_tx, g_ty };
        g_xform_len += 1;
    }
}

export fn zuil_pop() callconv(.c) void {
    if (g_xform_len > 0) {
        g_xform_len -= 1;
        g_tx = g_xform_stack[g_xform_len][0];
        g_ty = g_xform_stack[g_xform_len][1];
    }
}

export fn zuil_translate(ddx: f32, ddy: f32) callconv(.c) void {
    g_tx += ddx;
    g_ty += ddy;
}

// --- Spike E: synthetic event queue + read faces (no SDL) -----------------
// Twin of src/zuil.c's Spike E block: a bounded in-process queue drained with
// NO SDL in the path, exposed through both a raw struct (the out param) and the
// accessor face (the latch) so one round-trip is read either way and timed.
// Single-threaded for the measurement; the thread-safe SDL substrate is M1.5.
const EVQ_CAP = 64; // bounded; post fails fast when full (events.md §3)
const EVPAYLOAD_CAP = 256; // max bytes copied per message event

// extern: this is THE C-ABI struct (matches include/zuil.h ZuilEvent by layout —
// 4 c_int + one pointer; the pointer is the only width-varying field).
const ZuilEvent = extern struct {
    type: c_int,
    a: c_int,
    b: c_int,
    c: c_int,
    payload: ?[*]const u8,
};

const EvSlot = struct {
    type: c_int = 0,
    a: c_int = 0,
    b: c_int = 0,
    c: c_int = 0,
    payload_len: c_int = 0,
    payload: [EVPAYLOAD_CAP]u8 = std.mem.zeroes([EVPAYLOAD_CAP]u8),
};

var g_evq = std.mem.zeroes([EVQ_CAP]EvSlot); // ring buffer
var g_evq_head: usize = 0;
var g_evq_count: usize = 0;
var g_ev_latch: EvSlot = .{}; // the one event the accessor face reads
var g_ev_have: bool = false;

export fn zuil_test_emit(ev_type: c_int, a: c_int, b: c_int, cc: c_int, payload: ?[*]const u8, payload_len: c_int) callconv(.c) c_int {
    if (g_evq_count >= EVQ_CAP) return -1; // full: fail fast, never block
    var n: usize = if (payload_len > 0) @intCast(payload_len) else 0;
    if (n > EVPAYLOAD_CAP) return -2; // oversized payload: reject
    if (payload == null) n = 0;
    const tail = (g_evq_head + g_evq_count) % EVQ_CAP;
    const s = &g_evq[tail];
    s.type = ev_type;
    s.a = a;
    s.b = b;
    s.c = cc;
    s.payload_len = @intCast(n);
    if (n > 0) @memcpy(s.payload[0..n], payload.?[0..n]);
    g_evq_count += 1;
    return 0;
}

export fn zuil_event_poll(out: ?*ZuilEvent) callconv(.c) c_int {
    if (g_evq_count == 0) {
        g_ev_have = false;
        return 0;
    }
    g_ev_latch = g_evq[g_evq_head]; // copy slot -> latch: borrow source for accessors
    g_evq_head = (g_evq_head + 1) % EVQ_CAP;
    g_evq_count -= 1;
    g_ev_have = true;
    if (out) |o| {
        o.type = g_ev_latch.type;
        o.a = g_ev_latch.a;
        o.b = g_ev_latch.b;
        o.c = g_ev_latch.c;
        o.payload = if (g_ev_latch.payload_len != 0) &g_ev_latch.payload else null;
    }
    return 1;
}

export fn zuil_event_type() callconv(.c) c_int {
    return if (g_ev_have) g_ev_latch.type else 0;
}
export fn zuil_event_a() callconv(.c) c_int {
    return if (g_ev_have) g_ev_latch.a else 0;
}
export fn zuil_event_b() callconv(.c) c_int {
    return if (g_ev_have) g_ev_latch.b else 0;
}
export fn zuil_event_c() callconv(.c) c_int {
    return if (g_ev_have) g_ev_latch.c else 0;
}
export fn zuil_event_payload() callconv(.c) ?[*]const u8 {
    return if (g_ev_have and g_ev_latch.payload_len != 0) &g_ev_latch.payload else null;
}
export fn zuil_event_payload_len() callconv(.c) c_int {
    return if (g_ev_have) g_ev_latch.payload_len else 0;
}
export fn zuil_event_struct_size() callconv(.c) c_int {
    return @intCast(@sizeOf(ZuilEvent));
}
export fn zuil_event_struct_align() callconv(.c) c_int {
    return @intCast(@alignOf(ZuilEvent));
}
