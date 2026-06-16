/* grab-move, on zuil — the native C twin of main.lua (same demo, no interpreter).
 *
 * A plain thick client: it links libzuil and drives the poll-style frame pump
 * directly, the way examples/grab-move/zuil.lua's `run()` does for LuaJIT. The
 * point of this file is portability without a scripting host — the *same* C
 * source AOT-compiles for desktop, web (emscripten), Android and iOS, because it
 * speaks only include/zuil.h (no FFI, no SDL types except the SDL_main entry shim
 * on mobile). Logic is kept 1:1 with main.lua so the two stay comparable:
 *   * widgets are plain structs in user space (zuil owns no Button) — mechanism, not policy
 *   * input is the per-frame snapshot; zuil_mouse_pressed gives the click edge natively
 *   * back-to-front draw / front-to-back action with a shared claim (stop-propagation)
 *     and bring-to-front; clip + translate drive the scissored, draggable panel
 *
 * Desktop build (the gcc hedge — cc/clang/`zig cc` are drop-in):
 *   zig build                       # or the gcc hedge -> zig-out/lib/libzuil.so
 *   cc examples/grab-move/grab-move.c -Iinclude -o grab-move \
 *      zig-out/lib/libzuil.so $(pkg-config --cflags --libs sdl3)
 *   ./grab-move          # interactive;  ./grab-move 60  caps frames (headless smoke)
 */
#include <stdio.h>
#include <stdlib.h>
#include "zuil.h"

/* ---- state: the Lua tables, as plain structs --------------------------------- */
typedef struct { float x, y, w, h, r, g, b; const char *name;
                 int grab; float gdx, gdy; } Handle;
typedef struct { int label; float x, y, w, h; } Tab;
typedef struct { float x, y, w, h; int drag; float ddx, ddy; } Panel;

#define DEL  24   /* delete-button side */
#define MAXH 16   /* handles are a fixed-cap array + count (delete/reorder in place) */

static Handle handles[MAXH] = {
  {  60,  90, 300, 60, 0.20f, 0.45f, 0.95f, "DRAG ME",   0, 0, 0 },
  { 120, 170, 300, 60, 0.20f, 0.70f, 0.55f, "GRAB-MOVE", 0, 0, 0 },
  { 180, 250, 300, 60, 0.80f, 0.40f, 0.30f, "ZUIL TEXT", 0, 0, 0 },
};
static int   nhandles = 3;
static Tab   tabs[2]   = { { 1, 60, 30, 120, 40 }, { 2, 190, 30, 120, 40 } };
static int   active_tab = 0;
static Panel panel = { 380, 110, 260, 320, 0, 0, 0 };

/* Shared per-frame input claim: the topmost widget under the cursor (input runs
 * front-to-back, the reverse of draw order) eats the press so it can't pass
 * through to anything drawn beneath. Reset at the top of each frame. */
static int claimed = 0;

/* ---- helpers ----------------------------------------------------------------- */
static void col(float r, float g, float b) { zuil_set_color(r, g, b, 1.0f); }

static int inside(float px, float py, float x, float y, float w, float h) {
  return px >= x && px <= x + w && py >= y && py <= y + h;
}

/* move handle i to the end of the list = top of the draw order (drawn last) */
static void bring_to_front(int i) {
  Handle tmp = handles[i];
  for (int k = i; k < nhandles - 1; k++) handles[k] = handles[k + 1];
  handles[nhandles - 1] = tmp;
}
static void remove_handle(int i) {
  for (int k = i; k < nhandles - 1; k++) handles[k] = handles[k + 1];
  nhandles--;
}

/* ---- draggable handles ------------------------------------------------------- */
static void update_handles(void) {
  float mx = zuil_mouse_x(), my = zuil_mouse_y();
  if (!claimed && zuil_mouse_pressed(1)) {
    for (int i = nhandles - 1; i >= 0; i--) {      /* front-to-back */
      Handle *h = &handles[i];
      /* delete button (top-right) takes priority */
      if (inside(mx, my, h->x + h->w - DEL, h->y, DEL, DEL)) {
        remove_handle(i); claimed = 1; break;
      }
      /* grab to drag — only the topmost hit; stop propagation */
      if (inside(mx, my, h->x, h->y, h->w, h->h)) {
        h->grab = 1; h->gdx = mx - h->x; h->gdy = my - h->y;
        bring_to_front(i); claimed = 1; break;
      }
    }
  }
  /* apply active drag / release (ungated: an established grab keeps tracking) */
  for (int i = 0; i < nhandles; i++) {
    Handle *h = &handles[i];
    if (h->grab) {
      if (zuil_mouse_down(1)) { h->x = mx - h->gdx; h->y = my - h->gdy; }
      else h->grab = 0;
    }
  }
}

static void draw_handles(void) {
  for (int i = 0; i < nhandles; i++) {           /* back-to-front */
    Handle *h = &handles[i];
    col(1, 1, 1); zuil_fill_rect(h->x, h->y, h->w, h->h); /* white border */
    float b = 4;
    if (h->grab) col(1, 0.3f, 0.3f); else col(h->r, h->g, h->b);
    zuil_fill_rect(h->x + b, h->y + b, h->w - 2 * b, h->h - 2 * b);
    /* centered caption: measured width drives centering (proves measure == advance) */
    zuil_set_font_scale(2);
    col(1, 1, 1);
    float tw = zuil_text_width(h->name), th = zuil_text_height();
    zuil_draw_text(h->x + (h->w - tw) / 2, h->y + (h->h - th) / 2, h->name);
    zuil_set_font_scale(1);
    /* delete button with an X */
    float dx = h->x + h->w - DEL, dy = h->y;
    col(0.85f, 0.85f, 0.85f); zuil_fill_rect(dx, dy, DEL, DEL);
    col(0.2f, 0.2f, 0.2f);
    zuil_draw_line(dx + 6, dy + 6, dx + DEL - 6, dy + DEL - 6);
    zuil_draw_line(dx + DEL - 6, dy + 6, dx + 6, dy + DEL - 6);
  }
}

/* ---- exclusive tabs (mutex) -------------------------------------------------- */
static void update_tabs(void) {
  float mx = zuil_mouse_x(), my = zuil_mouse_y();
  if (!claimed && zuil_mouse_pressed(1)) {
    for (int i = 0; i < 2; i++)
      if (inside(mx, my, tabs[i].x, tabs[i].y, tabs[i].w, tabs[i].h)) {
        active_tab = i; claimed = 1;
      }
  }
}
static void draw_tabs(void) {
  for (int i = 0; i < 2; i++) {
    Tab *t = &tabs[i];
    if (i == active_tab) col(0.9f, 0.2f, 0.2f); else col(0.45f, 0.45f, 0.45f);
    zuil_fill_rect(t->x, t->y, t->w, t->h);
    col(1, 1, 1); zuil_draw_rect(t->x, t->y, t->w, t->h);
    zuil_set_font_scale(2);
    char label[16];
    snprintf(label, sizeof label, "TAB %d", t->label);
    zuil_draw_text(t->x + (t->w - zuil_text_width(label)) / 2,
                   t->y + (t->h - zuil_text_height()) / 2, label);
    zuil_set_font_scale(1);
  }
}

/* Rich text is a user-space styled-runs pattern over the primitives: walk runs,
 * set color/scale per run, advance the pen by text_width, underline with a line. */
typedef struct { const char *text; float r, g, b, scale; int underline; } Run;
static void styled_line(float x, float y, const Run *runs, int n) {
  float pen = x;
  for (int i = 0; i < n; i++) {
    const Run *run = &runs[i];
    zuil_set_font_scale(run->scale > 0 ? run->scale : 1);
    col(run->r, run->g, run->b);
    zuil_draw_text(pen, y, run->text);
    float w = zuil_text_width(run->text), h = zuil_text_height();
    if (run->underline) zuil_draw_line(pen, y + h, pen + w, y + h);
    pen += w;
  }
  zuil_set_font_scale(1);
}

/* ---- clipped, draggable panel (shows clip + translate) ----------------------- */
static void update_panel(void) {
  float mx = zuil_mouse_x(), my = zuil_mouse_y();
  /* whole panel is opaque to clicks (blocks pass-through); only the header drags */
  if (!claimed && zuil_mouse_pressed(1) &&
      inside(mx, my, panel.x, panel.y, panel.w, panel.h)) {
    claimed = 1;
    if (inside(mx, my, panel.x, panel.y, panel.w, 28)) {
      panel.drag = 1; panel.ddx = mx - panel.x; panel.ddy = my - panel.y;
    }
  }
  if (panel.drag) {
    if (zuil_mouse_down(1)) { panel.x = mx - panel.ddx; panel.y = my - panel.ddy; }
    else panel.drag = 0;
  }
}
static void draw_panel(void) {
  col(0.15f, 0.15f, 0.18f); zuil_fill_rect(panel.x, panel.y, panel.w, panel.h);
  col(0.30f, 0.30f, 0.36f); zuil_fill_rect(panel.x, panel.y, panel.w, 28);
  col(1, 1, 1); zuil_draw_rect(panel.x, panel.y, panel.w, panel.h);

  /* clipped body: content is translated and deliberately overflows the rect */
  float bx = panel.x + 8, by = panel.y + 36, bw = panel.w - 16, bh = panel.h - 44;
  zuil_clip_push(bx, by, bw, bh);
  zuil_push();
  zuil_translate(bx, by);
  if (tabs[active_tab].label == 1) {
    for (int i = 0; i <= 20; i++) {
      col(0.2f + 0.03f * i, 0.5f, 1.0f - 0.03f * i);
      zuil_fill_rect(-20 + i * 16, i * 14, 220, 12); /* overflows -> clipped */
    }
  } else {
    for (int i = 0; i <= 14; i++) {
      col(0.9f, 0.4f + 0.03f * i, 0.2f);
      zuil_draw_line(0, i * 22, 320, i * 22 + 40); /* overflows right -> clipped */
    }
  }
  zuil_pop();
  zuil_clip_pop();
}

/* ---- one frame: platform-blind. The body of main.lua's zuil.run callback. ---- */
static void frame(void) {
  /* input: front-to-back (reverse of draw order) so the topmost widget claims it */
  claimed = 0;
  update_panel();
  update_handles();
  update_tabs();

  /* draw: background, then back-to-front */
  col(0.08f, 0.08f, 0.10f); zuil_clear();
  draw_tabs();
  draw_handles();
  draw_panel();

  /* styled-runs demo: rich text falls out of the primitives (no core markup) */
  static const Run runs[] = {
    { "rich ",  0.6f, 0.8f, 1.0f, 2, 1 },
    { "text ",  1.0f, 0.8f, 0.3f, 2, 0 },
    { "= runs", 0.7f, 0.7f, 0.7f, 1, 0 },
  };
  styled_line(60, 460, runs, 3);
}

/* ---- entry / loop driver: the only per-platform divergence -------------------
 * Native (desktop/Android/iOS) owns the loop directly. The web forbids a blocking
 * loop, so the same frame() is handed to emscripten_set_main_loop (docs/web.md §3):
 * the pump is already non-blocking, so the inversion is free. On Android/iOS SDL
 * supplies the process entry and calls our main() via SDL_main.h's renaming. */
#if defined(__EMSCRIPTEN__)
#include <emscripten.h>
static void frame_cb(void) {
  if (!zuil_frame_begin()) { emscripten_cancel_main_loop(); zuil_window_close(); return; }
  frame();
  zuil_frame_end();
}
#elif defined(__ANDROID__) || defined(__APPLE__)
#include <SDL3/SDL_main.h>   /* renames main -> SDL_main where the platform needs it */
#endif

int main(int argc, char **argv) {
  int cap = (argc > 1) ? atoi(argv[1]) : 0;   /* optional frame cap for headless smoke */
  if (zuil_window_open("grab-move on zuil (C)", 700, 500) != 0) {
    fprintf(stderr, "zuil: could not open window\n");
    return 1;
  }
#if defined(__EMSCRIPTEN__)
  (void)cap;
  emscripten_set_main_loop(frame_cb, 0, 1);   /* loop inversion; does not return */
  return 0;
#else
  int n = 0;
  while (zuil_frame_begin()) {
    frame();
    zuil_frame_end();
    if (cap && ++n >= cap) break;
  }
  zuil_window_close();
  return 0;
#endif
}
