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
#include "font_atlas.h" /* baked style-page atlas blob: zuil_font_atlas_blob (gen by tools/gen_font_atlas.py) */

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

/* current draw color, cached so draw_text can tint the (white) glyph atlas with
 * the same color set_color last applied to the renderer. */
static Uint8 g_col[4] = { 0, 0, 0, 255 };

/* --- text / font atlas (mirror of src/zuil.zig) --------------------------- */
/* Glyphs come from a baked container of style PAGES (regular/bold/italic/
 * bold-italic), each a real TTF face rendered 1-bit by tools/gen_font_atlas.py,
 * here #included from src/font_atlas.h (the Zig twin @embedFile's the identical
 * src/font_atlas.bin). Container + RLE format: see the generator. */
#define ATLAS_COLS   16 /* glyph-grid columns per page texture */
#define ATLAS_GUTTER 1  /* transparent px between cells so linear filtering can't bleed neighbours */
#define MAX_PAGES    8

/* One parsed PAGE: the NATIVE (oversampled, baked) cell + the EM (nominal) cell
 * that font_scale=1.0 maps to, the codepoint range, and where its (raw|RLE)
 * glyph data sits in the blob. Glyphs are stored at the native cell and drawn
 * DOWNSCALED to em*scale with linear filtering (cheap AA from a 1-bit source).
 * Texture is built lazily and freed on window close. */
typedef struct {
    SDL_Texture *tex;
    Uint16 cell_w, cell_h; /* native (atlas) cell */
    Uint16 em_w, em_h;     /* em (nominal) cell = display size at scale 1.0 */
    Uint16 first, count;
    Uint8  depth; /* 1 = mono (RLE-able); 32 = RGBA (future emoji, raw) */
    Uint8  enc;   /* 0 = raw, 1 = RLE */
    size_t data_off, data_len;
} FontPage;

static FontPage g_pages[MAX_PAGES];
static size_t   g_npages = 0;
static int      g_parsed = 0;
static size_t   g_style = 0; /* selected page index (style bits) */
static float    g_font_scale = 1.0f;

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
    for (size_t i = 0; i < SDL_arraysize(g_pages); i++) { /* free glyph textures; rebuild lazily */
        if (g_pages[i].tex) SDL_DestroyTexture(g_pages[i].tex);
        g_pages[i].tex = NULL;
    }
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
    g_col[0] = to8(r); g_col[1] = to8(g); g_col[2] = to8(b); g_col[3] = to8(a);
    if (!g_ren) return;
    SDL_SetRenderDrawColor(g_ren, g_col[0], g_col[1], g_col[2], g_col[3]);
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

/* --- bitmap text --------------------------------------------------------- */

static inline Uint16 rd16(size_t off) {
    return (Uint16)(zuil_font_atlas_blob[off] | (zuil_font_atlas_blob[off + 1] << 8));
}
static inline Uint32 rd32(size_t off) {
    return (Uint32)zuil_font_atlas_blob[off] | ((Uint32)zuil_font_atlas_blob[off + 1] << 8) |
           ((Uint32)zuil_font_atlas_blob[off + 2] << 16) | ((Uint32)zuil_font_atlas_blob[off + 3] << 24);
}

/* Parse the blob's header + page table once (no renderer needed, so measurement
 * works before the first frame). Bad/short blob -> g_npages stays 0. */
static void ensure_parsed(void)
{
    if (g_parsed) return;
    g_parsed = 1;
    if (ZUIL_FONT_ATLAS_BLOB_LEN < 8) return;
    if (zuil_font_atlas_blob[0] != 'Z' || zuil_font_atlas_blob[1] != 'F' ||
        zuil_font_atlas_blob[2] != '0' || zuil_font_atlas_blob[3] != '2') return;
    unsigned n = zuil_font_atlas_blob[4];
    size_t off = 8, i = 0;
    for (; i < n && i < MAX_PAGES; i++) {
        if (off + 14 > ZUIL_FONT_ATLAS_BLOB_LEN) break;
        Uint32 dlen = rd32(off + 10);
        g_pages[i].cell_w = zuil_font_atlas_blob[off];
        g_pages[i].cell_h = zuil_font_atlas_blob[off + 1];
        g_pages[i].em_w = zuil_font_atlas_blob[off + 2];
        g_pages[i].em_h = zuil_font_atlas_blob[off + 3];
        g_pages[i].first = rd16(off + 4);
        g_pages[i].count = rd16(off + 6);
        g_pages[i].depth = zuil_font_atlas_blob[off + 8];
        g_pages[i].enc = zuil_font_atlas_blob[off + 9];
        g_pages[i].data_off = off + 14;
        g_pages[i].data_len = dlen;
        off += 14 + dlen;
        if (off > ZUIL_FONT_ATLAS_BLOB_LEN) break;
    }
    g_npages = i;
}

static inline size_t active_page(void)
{
    return (g_style < g_npages) ? g_style : 0;
}

/* Expand a page's glyph data into a per-pixel bit buffer (1 byte/pixel, 0/1),
 * row-major (glyph, row, col) — uniform whatever the on-disk encoding is. */
static void expand_page(const FontPage *pg, Uint8 *out, size_t out_len)
{
    const unsigned char *data = &zuil_font_atlas_blob[pg->data_off];
    size_t cw = pg->cell_w, ch = pg->cell_h, count = pg->count;
    if (pg->enc == 1) { /* RLE: toggle run-length, starting color 0 (off) */
        Uint8 color = 0;
        size_t pos = 0, i = 0;
        while (pos < out_len && i < pg->data_len) {
            size_t run = 0;
            while (i < pg->data_len) {
                Uint8 b = data[i++];
                run += b;
                if (b != 255) break;
            }
            for (size_t k = 0; k < run && pos + k < out_len; k++) out[pos + k] = color;
            pos += run;
            color ^= 1;
        }
    } else { /* raw: cell_h rows of ceil(cw/8) bytes per glyph */
        size_t row_bytes = (cw + 7) / 8;
        for (size_t g = 0; g < count; g++)
            for (size_t row = 0; row < ch; row++)
                for (size_t col = 0; col < cw; col++) {
                    Uint8 byte = data[(g * ch + row) * row_bytes + (col / 8)];
                    out[(g * ch + row) * cw + col] = (byte >> (col % 8)) & 1;
                }
    }
}

/* Build a page's glyph-grid texture once (lazy: needs the renderer). White ink
 * + alpha so draw_text can tint it; BLEND so the background shows through.
 * Recreatable: window_close nulls every page's tex. */
static void ensure_atlas(size_t pi)
{
    if (!g_ren) return;
    FontPage *pg = &g_pages[pi];
    if (pg->tex) return;
    size_t cw = pg->cell_w, ch = pg->cell_h, count = pg->count;
    if (!cw || !ch || !count) return;

    size_t cols = ATLAS_COLS;
    size_t rows = (count + cols - 1) / cols;
    size_t stride_w = cw + ATLAS_GUTTER, stride_h = ch + ATLAS_GUTTER;
    size_t W = cols * stride_w, H = rows * stride_h;

    size_t nbits = count * cw * ch;
    Uint8 *bits = SDL_malloc(nbits);
    if (!bits) return;
    expand_page(pg, bits, nbits);

    size_t npx = W * H;
    Uint32 *px = SDL_malloc(npx * 4);
    if (!px) { SDL_free(bits); return; }
    SDL_memset(px, 0, npx * 4); /* RGBA32; white=0xFFFFFFFF, bg=0 (endian-agnostic) */
    for (size_t g = 0; g < count; g++) {
        size_t gx = (g % cols) * stride_w, gy = (g / cols) * stride_h;
        for (size_t row = 0; row < ch; row++)
            for (size_t col = 0; col < cw; col++)
                if (bits[(g * ch + row) * cw + col])
                    px[(gy + row) * W + gx + col] = 0xFFFFFFFFu;
    }

    SDL_Texture *tex = SDL_CreateTexture(g_ren, SDL_PIXELFORMAT_RGBA32,
                                         SDL_TEXTUREACCESS_STATIC, (int)W, (int)H);
    if (tex) {
        SDL_UpdateTexture(tex, NULL, px, (int)(W * 4));
        SDL_SetTextureBlendMode(tex, SDL_BLENDMODE_BLEND);
        SDL_SetTextureScaleMode(tex, SDL_SCALEMODE_LINEAR); /* smooth the downscale (1-bit -> AA) */
        pg->tex = tex;
    }
    SDL_free(px);
    SDL_free(bits);
}

/* Map a byte to its cell index, falling back to the box (last cell) for
 * non-printable / non-ASCII (real UTF-8 decoding is the deferred next step). */
static inline size_t cell_index(const FontPage *pg, unsigned char ch)
{
    if (ch >= pg->first && ch <= pg->first + pg->count - 2) return (size_t)(ch - pg->first);
    return pg->count - 1; /* last cell = fallback box */
}

void zuil_set_font_scale(float s)
{
    g_font_scale = s;
}

void zuil_set_font_style(int flags)
{
    g_style = (flags < 0) ? 0 : (size_t)flags; /* clamped to npages at use */
}

void zuil_draw_text(float x, float y, const char *utf8)
{
    if (!g_ren || !utf8) return;
    ensure_parsed();
    if (!g_npages) return;
    size_t pi = active_page();
    ensure_atlas(pi);
    FontPage *pg = &g_pages[pi];
    SDL_Texture *tex = pg->tex;
    if (!tex) return;

    /* Tint the white glyphs with the current draw color. */
    SDL_SetTextureColorMod(tex, g_col[0], g_col[1], g_col[2]);
    SDL_SetTextureAlphaMod(tex, g_col[3]);

    const size_t cols = ATLAS_COLS;
    const size_t stride_w = pg->cell_w + ATLAS_GUTTER, stride_h = pg->cell_h + ATLAS_GUTTER;
    /* draw the native glyph downscaled into the em (nominal) box * scale */
    const float cw_dst = (float)pg->em_w * g_font_scale;
    const float ch_dst = (float)pg->em_h * g_font_scale;
    float pen = x;
    for (const unsigned char *p = (const unsigned char *)utf8; *p; p++) {
        size_t ci = cell_index(pg, *p);
        SDL_FRect src = { (float)((ci % cols) * stride_w), (float)((ci / cols) * stride_h),
                          (float)pg->cell_w, (float)pg->cell_h };
        SDL_FRect dst = { dx(pen), dy(y), cw_dst, ch_dst };
        SDL_RenderTexture(g_ren, tex, &src, &dst);
        pen += cw_dst;
    }
}

/* --- text measurement (mechanism; user-space owns layout/caret policy) ---- */

static inline size_t glyph_count(const char *utf8)
{
    if (!utf8) return 0;
    size_t n = 0;
    while (utf8[n]) n++; /* byte count for now; same when UTF-8 lands */
    return n;
}

float zuil_font_advance(void)
{
    ensure_parsed();
    if (!g_npages) return 0;
    return (float)g_pages[active_page()].em_w * g_font_scale;
}

float zuil_text_width(const char *utf8)
{
    return (float)glyph_count(utf8) * zuil_font_advance();
}

float zuil_text_height(void)
{
    ensure_parsed();
    if (!g_npages) return 0;
    return (float)g_pages[active_page()].em_h * g_font_scale;
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

/* --- Spike E: synthetic event queue + read faces (no SDL) ----------------- */
/* A bounded in-process queue exercised with NO SDL in the path — zuil_test_emit
 * posts synthetic events, zuil_event_poll drains them. Two read faces hang off
 * the SAME drain (raw struct via the out param; accessors via the latch) so one
 * round-trip can be read either way and the two timed against each other. Single
 * -threaded for the measurement; the thread-safe SDL user-event substrate is
 * M1.5's job (events.md §3). Mirror of src/zuil.zig. */
#define EVQ_CAP        64  /* bounded; post fails fast when full (events.md §3) */
#define EVPAYLOAD_CAP 256  /* max bytes copied per message event */

typedef struct {
    int type, a, b, c;
    int payload_len;
    unsigned char payload[EVPAYLOAD_CAP];
} EvSlot;

static EvSlot g_evq[EVQ_CAP];  /* ring buffer */
static size_t g_evq_head = 0;
static size_t g_evq_count = 0;
static EvSlot g_ev_latch;      /* the one event the accessor face reads */
static bool   g_ev_have = false;

int zuil_test_emit(int type, int a, int b, int c,
                   const unsigned char *payload, int payload_len)
{
    if (g_evq_count >= EVQ_CAP) return -1;     /* full: fail fast, never block */
    if (payload_len < 0) payload_len = 0;
    if (payload_len > EVPAYLOAD_CAP) return -2; /* oversized payload: reject */
    size_t tail = (g_evq_head + g_evq_count) % EVQ_CAP;
    EvSlot *s = &g_evq[tail];
    s->type = type; s->a = a; s->b = b; s->c = c;
    s->payload_len = (payload && payload_len) ? payload_len : 0;
    if (s->payload_len) SDL_memcpy(s->payload, payload, (size_t)s->payload_len);
    g_evq_count += 1;
    return 0;
}

int zuil_event_poll(ZuilEvent *out)
{
    if (g_evq_count == 0) { g_ev_have = false; return 0; }
    g_ev_latch = g_evq[g_evq_head]; /* copy slot -> latch: borrow source for the accessors */
    g_evq_head = (g_evq_head + 1) % EVQ_CAP;
    g_evq_count -= 1;
    g_ev_have = true;
    if (out) {
        out->type = g_ev_latch.type;
        out->a = g_ev_latch.a;
        out->b = g_ev_latch.b;
        out->c = g_ev_latch.c;
        out->payload = g_ev_latch.payload_len ? g_ev_latch.payload : NULL;
    }
    return 1;
}

int zuil_event_type(void) { return g_ev_have ? g_ev_latch.type : ZUIL_EV_NONE; }
int zuil_event_a(void)    { return g_ev_have ? g_ev_latch.a : 0; }
int zuil_event_b(void)    { return g_ev_have ? g_ev_latch.b : 0; }
int zuil_event_c(void)    { return g_ev_have ? g_ev_latch.c : 0; }

const unsigned char *zuil_event_payload(void)
{
    return (g_ev_have && g_ev_latch.payload_len) ? g_ev_latch.payload : NULL;
}
int zuil_event_payload_len(void) { return g_ev_have ? g_ev_latch.payload_len : 0; }

int zuil_event_struct_size(void)  { return (int)sizeof(ZuilEvent); }
int zuil_event_struct_align(void) { return (int)_Alignof(ZuilEvent); }
