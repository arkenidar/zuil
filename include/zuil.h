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
 * standing text mechanism (2026-06-15): a fixed-width font is baked into the
 * binary (src/font_atlas.{h,bin}, real TTF faces rendered 1-bit), uploaded once
 * per style page as one tinted texture, then cropped per-glyph and scaled. No
 * external font lib, no font
 * assets — keeps deps empty (build.zig.zon), helps web/Android, fits the C-first
 * hedge. Fixed-width with uniform spacing; glyphs draw in the current
 * zuil_set_color tint and honor the translation stack. Bytes outside printable
 * ASCII (0x20..0x7E) draw a fallback box (real UTF-8 + Unicode pages are the
 * deferred next step). */
void zuil_set_font_scale(float s); /* sticky, default 1.0 (like set_color/translate) */
void zuil_draw_text(float x, float y, const char *utf8);

/* Font style — selects one of the baked glyph PAGES (regular/bold/italic), each
 * a real face rasterized 1-bit into the atlas container (src/font_atlas.{h,bin},
 * from the dev-only generator). OR the flags for bold-italic. Sticky like the
 * font scale; the glyphs are fixed-width so style never changes the advance, so
 * measurement is unaffected. Bytes are still ASCII-only here (UTF-8 + Unicode
 * pages are the next step); colored pages (emoji) are a future RGBA depth. */
#define ZUIL_FONT_REGULAR 0
#define ZUIL_FONT_BOLD    1
#define ZUIL_FONT_ITALIC  2
void zuil_set_font_style(int flags);

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

/* ---------------------------------------------------------------------------
 * Spike E — the event struct across the FFI boundary (docs/m1.md §3 / M1.1).
 *
 * The input *snapshot* above sidestepped this spike on the desktop face by
 * choosing accessors. But M1.5's event_post / message / timer traffic needs a
 * payload that genuinely crosses the ABI, so the raw-struct-vs-accessor cost
 * has to be measured, not argued. This is that measurement, with NO SDL in the
 * path: zuil_test_emit posts a synthetic event into a bounded in-process queue;
 * zuil_event_poll drains it. Both read faces are exported off the SAME drain so
 * a single round-trip can be read either way and the two timed against each
 * other (examples/event_smoke.lua does the LuaJIT bench).
 *
 * Representation: a FLAT struct with per-type reused scalar slots (a/b/c) — the
 * "flat struct with dead fields" candidate, chosen over a C union so there is
 * no union-alignment surprise to read identically across wasm32 / x86-64 /
 * arm64. The discriminant is `type`. The payload pointer is the only width-
 * varying field (4 bytes on wasm32, 8 elsewhere); each FFI face asserts its
 * header matches the built binary via zuil_event_struct_size/align.
 * ------------------------------------------------------------------------- */

/* Event discriminant + the meaning of the a/b/c slots per type. */
enum {
    ZUIL_EV_NONE    = 0,
    ZUIL_EV_MOUSE   = 1, /* a = x,        b = y,           c = button bitmask */
    ZUIL_EV_KEY     = 2, /* a = scancode, b = modifiers,   c = 0              */
    ZUIL_EV_MESSAGE = 3, /* a = channel,  b = payload_len,  payload = bytes   */
    ZUIL_EV_TIMER   = 4  /* a = timer id, b = 0,           c = 0              */
};

typedef struct ZuilEvent {
    int            type;       /* one of ZUIL_EV_* */
    int            a, b, c;    /* per-type scalar slots (see enum) */
    const unsigned char *payload; /* ZUIL_EV_MESSAGE only: borrowed bytes,
                                   * valid until the next poll/emit; else NULL */
} ZuilEvent;

/* Post one synthetic event (no SDL). payload may be NULL/0. The queue is
 * bounded and posting FAILS FAST (events.md §3): returns 0 on success, <0 when
 * the queue is full or the payload exceeds the per-event capacity. */
int zuil_test_emit(int type, int a, int b, int c,
                   const unsigned char *payload, int payload_len);

/* Dequeue the next event. Latches it internally (for the accessor face below)
 * and, if out != NULL, copies it (the raw-struct face). Returns 1 if an event
 * was dequeued, 0 if the queue was empty. */
int zuil_event_poll(ZuilEvent *out);

/* Accessor read face — valid after a zuil_event_poll that returned 1, until the
 * next poll. One FFI call per field, vs reading the struct cdata directly. */
int zuil_event_type(void);
int zuil_event_a(void);
int zuil_event_b(void);
int zuil_event_c(void);
const unsigned char *zuil_event_payload(void);
int zuil_event_payload_len(void);

/* Layout self-check: the struct's size/alignment as the binary laid it out, so
 * each face can assert its own ZuilEvent header matches (the cross-pointer-width
 * concern). Returns bytes. */
int zuil_event_struct_size(void);
int zuil_event_struct_align(void);

#ifdef __cplusplus
}
#endif

#endif /* ZUIL_H */
