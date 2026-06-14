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
