/* ZUIL public C ABI — THE contract.
 *
 * This header is the single source of truth for the exported surface. Two
 * interchangeable implementations exist behind it — src/zuil.c (C, the
 * default) and src/zuil.zig (Zig) — selected with `zig build -Dimpl=...`;
 * consumers (LuaJIT FFI, ctypes, C, C++, JS/cwrap) see only these symbols and
 * must not care which implementation produced the library. Keep both
 * implementations in lockstep with this file.
 *
 * UTF-8 throughout; zuil_* snake_case; plain C types only (FFI-friendly). */
#ifndef ZUIL_H
#define ZUIL_H

#ifdef __cplusplus
extern "C" {
#endif

/* Step 0: returns the linked SDL3 version as a packed int (3.2.10 -> 3002010).
 * Exists to prove the whole build/link/FFI pipeline, nothing more. */
int zuil_sdl_version(void);

/* ---------------------------------------------------------------------------
 * M1 mechanism (desktop slice). A poll-style, callback-free surface: the
 * consumer owns the loop (frame_begin/frame_end), drawing flows through one
 * vocabulary, and input is read as a derived per-frame snapshot via accessor
 * functions (no event struct crosses the ABI yet — keeps that layout soft).
 * Coordinates and colors are floats; colors are 0..1 (love-style).
 * ------------------------------------------------------------------------- */

/* Window + frame pump. */
int  zuil_window_open(const char *title, int w, int h); /* 0 = ok, <0 = error */
void zuil_window_close(void);
int  zuil_frame_begin(void); /* pump events + rebuild snapshot; 1 = keep running */
void zuil_frame_end(void);   /* present the frame */

/* Draw vocabulary. */
void zuil_set_color(float r, float g, float b, float a);
void zuil_clear(void);
void zuil_fill_rect(float x, float y, float w, float h);
void zuil_draw_rect(float x, float y, float w, float h);
void zuil_draw_line(float x1, float y1, float x2, float y2);

/* Bitmap text — the built-in 1-bit ASCII font atlas, NOT SDL3_ttf. This is the
 * standing text mechanism (2026-06-15): a public-domain 8x8 fixed-width font is
 * baked into the binary (src/font8x8.{h,bin}), uploaded once as one tinted
 * texture, then cropped per-glyph and scaled. No external font lib, no font
 * assets — keeps deps empty (build.zig.zon), helps web/Android, fits the C-first
 * hedge. Fixed-width with uniform spacing; glyphs draw in the current
 * zuil_set_color tint and honor the translation stack. Bytes outside printable
 * ASCII (0x20..0x7E) draw a fallback box (real UTF-8 + Unicode pages are the
 * deferred next step). */
void zuil_set_font_scale(float s); /* sticky, default 1.0 (like set_color/translate) */
void zuil_draw_text(float x, float y, const char *utf8);

/* Text measurement — a first-class core responsibility, not a widget concern:
 * layout sizes content to these, and editable text uses the advance for caret
 * placement / hit-testing. All reflect the current font scale. Mechanism only —
 * the core reports metrics; user-space owns layout/caret policy. */
float zuil_text_width(const char *utf8); /* full run width at the current scale */
float zuil_text_height(void);            /* line height at the current scale */
float zuil_font_advance(void);           /* per-glyph horizontal step (uniform) */

/* Input snapshot (accessors). Buttons: 1 = left, 2 = middle, 3 = right. */
int zuil_mouse_x(void);
int zuil_mouse_y(void);
int zuil_mouse_down(int button);     /* held this frame */
int zuil_mouse_pressed(int button);  /* went down this frame (edge) */
int zuil_mouse_released(int button); /* went up this frame (edge) */
int zuil_key_pressed(int scancode);  /* SDL_Scancode pressed this frame (edge) */
int zuil_should_quit(void);          /* window close requested or Escape */

/* Clip + 2-D translation stack (translation only; no scale in this slice). */
void zuil_clip_push(float x, float y, float w, float h);
void zuil_clip_pop(void);
void zuil_push(void);                 /* save current translation */
void zuil_pop(void);                  /* restore it */
void zuil_translate(float dx, float dy);

#ifdef __cplusplus
}
#endif

#endif /* ZUIL_H */
