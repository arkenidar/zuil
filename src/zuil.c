/* ZUIL — C implementation. Twin of src/zuil.zig behind the same contract
 * (include/zuil.h); `zig build -Dimpl=c` selects it (the default).
 *
 * Why a C twin at all: the pinned Zig *dev* toolchain is the project's most
 * fragile dependency. This file compiles with any C compiler (gcc, clang,
 * NDK clang, emcc), so if Zig ever becomes a stopper the core survives and
 * build.zig degrades to convenience rather than dependency. Including zuil.h
 * makes the compiler check this implementation against the contract.
 *
 * This twin is a line-for-line port of src/zuil.zig's M1 desktop slice — same
 * module state, same SDL3 calls, same semantics — so the two impls stay in
 * lockstep behind the header and either can satisfy a consumer transparently. */
#define SDL_MAIN_HANDLED 1 /* keep SDL's header-only main shim off our entry point */
#include <SDL3/SDL.h>
#include "zuil.h"

/* Step 0: returns the linked SDL3 version as a packed int (3.2.10 -> 3002010). */
int zuil_sdl_version(void)
{
    return SDL_GetVersion();
}

/* --- module state (mirrors src/zuil.zig: the de-facto "core") ------------- */

static SDL_Window   *g_win = NULL;
static SDL_Renderer *g_ren = NULL;

/* input snapshot */
static int  g_mx = 0;
static int  g_my = 0;
static bool g_down[8];     /* held this frame, indexed by button (1..3) */
static bool g_pressed[8];  /* edge: down this frame */
static bool g_released[8]; /* edge: up this frame */
static bool g_key[512];    /* edge: scancode down this frame */
static bool g_quit = false;

/* translation stack (translation only — no scale in this slice) */
static float g_tx = 0;
static float g_ty = 0;
static float g_xform_stack[32][2];
static size_t g_xform_len = 0;

/* clip stack (rects already offset into device space) */
static SDL_Rect g_clip_stack[32];
static size_t g_clip_len = 0;

static inline float dx(float x) { return x + g_tx; }
static inline float dy(float y) { return y + g_ty; }

/* --- window + frame pump -------------------------------------------------- */

int zuil_window_open(const char *title, int w, int h)
{
    if (!SDL_Init(SDL_INIT_VIDEO)) return -1;
    g_win = SDL_CreateWindow(title, w, h, 0);
    if (g_win == NULL) return -2;
    g_ren = SDL_CreateRenderer(g_win, NULL);
    if (g_ren == NULL) return -3;
    return 0;
}

void zuil_window_close(void)
{
    if (g_ren) SDL_DestroyRenderer(g_ren);
    if (g_win) SDL_DestroyWindow(g_win);
    g_ren = NULL;
    g_win = NULL;
    SDL_Quit();
}

int zuil_frame_begin(void)
{
    /* clear per-frame edges */
    SDL_memset(g_pressed, 0, sizeof(g_pressed));
    SDL_memset(g_released, 0, sizeof(g_released));
    SDL_memset(g_key, 0, sizeof(g_key));

    SDL_Event ev;
    while (SDL_PollEvent(&ev)) {
        switch (ev.type) {
        case SDL_EVENT_QUIT:
            g_quit = true;
            break;
        case SDL_EVENT_MOUSE_BUTTON_DOWN: {
            size_t b = ev.button.button;
            if (b < SDL_arraysize(g_pressed)) g_pressed[b] = true;
            break;
        }
        case SDL_EVENT_MOUSE_BUTTON_UP: {
            size_t b = ev.button.button;
            if (b < SDL_arraysize(g_released)) g_released[b] = true;
            break;
        }
        case SDL_EVENT_KEY_DOWN:
            if (!ev.key.repeat) {
                int sc = (int)ev.key.scancode;
                if (sc >= 0 && sc < (int)SDL_arraysize(g_key)) g_key[sc] = true;
                if (ev.key.scancode == SDL_SCANCODE_ESCAPE) g_quit = true;
            }
            break;
        default:
            break;
        }
    }

    /* mouse position + held buttons from the current device state */
    float fx = 0, fy = 0;
    Uint32 mask = SDL_GetMouseState(&fx, &fy);
    g_mx = (int)fx;
    g_my = (int)fy;
    for (int b = 1; b <= 3; b++) {
        Uint32 bit = (Uint32)1 << (b - 1);
        g_down[b] = (mask & bit) != 0;
    }

    return (g_quit || g_win == NULL) ? 0 : 1;
}

void zuil_frame_end(void)
{
    if (g_ren) SDL_RenderPresent(g_ren);
}

/* --- draw vocabulary ----------------------------------------------------- */

static inline Uint8 to8(float v)
{
    return (Uint8)(SDL_clamp(v, 0.0f, 1.0f) * 255.0f);
}

void zuil_set_color(float r, float g, float b, float a)
{
    if (!g_ren) return;
    SDL_SetRenderDrawColor(g_ren, to8(r), to8(g), to8(b), to8(a));
}

void zuil_clear(void)
{
    if (g_ren) SDL_RenderClear(g_ren);
}

void zuil_fill_rect(float x, float y, float w, float h)
{
    if (!g_ren) return;
    SDL_FRect rect = { dx(x), dy(y), w, h };
    SDL_RenderFillRect(g_ren, &rect);
}

void zuil_draw_rect(float x, float y, float w, float h)
{
    if (!g_ren) return;
    SDL_FRect rect = { dx(x), dy(y), w, h };
    SDL_RenderRect(g_ren, &rect);
}

void zuil_draw_line(float x1, float y1, float x2, float y2)
{
    if (!g_ren) return;
    SDL_RenderLine(g_ren, dx(x1), dy(y1), dx(x2), dy(y2));
}

/* --- input snapshot accessors -------------------------------------------- */

static inline int boolBit(bool v) { return v ? 1 : 0; }
static inline bool idx(int button, const bool *arr)
{
    if (button < 0 || button >= 8) return false;
    return arr[button];
}

int zuil_mouse_x(void) { return g_mx; }
int zuil_mouse_y(void) { return g_my; }
int zuil_mouse_down(int button)     { return boolBit(idx(button, g_down)); }
int zuil_mouse_pressed(int button)  { return boolBit(idx(button, g_pressed)); }
int zuil_mouse_released(int button) { return boolBit(idx(button, g_released)); }

int zuil_key_pressed(int scancode)
{
    if (scancode < 0 || scancode >= (int)SDL_arraysize(g_key)) return 0;
    return boolBit(g_key[scancode]);
}

int zuil_should_quit(void) { return boolBit(g_quit); }

/* --- clip + translation stacks ------------------------------------------- */

void zuil_clip_push(float x, float y, float w, float h)
{
    if (!g_ren) return;
    SDL_Rect rect = { (int)dx(x), (int)dy(y), (int)w, (int)h };
    /* intersect with the current clip (if any) so nesting behaves */
    if (g_clip_len > 0) {
        SDL_Rect out = { 0, 0, 0, 0 };
        SDL_GetRectIntersection(&rect, &g_clip_stack[g_clip_len - 1], &out);
        rect = out;
    }
    if (g_clip_len < SDL_arraysize(g_clip_stack)) {
        g_clip_stack[g_clip_len] = rect;
        g_clip_len += 1;
    }
    SDL_SetRenderClipRect(g_ren, &rect);
}

void zuil_clip_pop(void)
{
    if (!g_ren) return;
    if (g_clip_len > 0) g_clip_len -= 1;
    if (g_clip_len > 0) {
        SDL_SetRenderClipRect(g_ren, &g_clip_stack[g_clip_len - 1]);
    } else {
        SDL_SetRenderClipRect(g_ren, NULL);
    }
}

void zuil_push(void)
{
    if (g_xform_len < SDL_arraysize(g_xform_stack)) {
        g_xform_stack[g_xform_len][0] = g_tx;
        g_xform_stack[g_xform_len][1] = g_ty;
        g_xform_len += 1;
    }
}

void zuil_pop(void)
{
    if (g_xform_len > 0) {
        g_xform_len -= 1;
        g_tx = g_xform_stack[g_xform_len][0];
        g_ty = g_xform_stack[g_xform_len][1];
    }
}

void zuil_translate(float ddx, float ddy)
{
    g_tx += ddx;
    g_ty += ddy;
}
