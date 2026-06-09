# ZUIL — Architecture & Design

A living design record: the decisions behind ZUIL, *why* they were made, their trade-offs, and
a dated log. Kept deliberately explicit so the model is never re-litigated by accident.

> **Status (2026-06-09): early bootstrap.** Step 0 (build / link / FFI pipeline) is complete and
> verified. The "mechanism" API and the widget layer described here are **designed, not yet
> built** — they are the plan for the next milestones, written down *before* the code.

---

## 1. What ZUIL is (and isn't)

ZUIL is a small **Zig** shared library (`libzuil.so`) exposing a clean **C ABI**, consumed
primarily from **LuaJIT** via FFI (and equally from Python/ctypes, C, etc. — it is a plain C
ABI, demonstrated by `examples/smoke.lua` and `examples/smoke.py`). It renders with **SDL3**.

- **It is** a clean, SDL3-native, event-driven UI *mechanism* that takes **loose inspiration**
  from the Win32 GUI model — handle-based windows, an event loop, a paint step, a drawing
  vocabulary.
- **It is not** a Win32 compatibility layer. It does **not** aim for Win32 fidelity: no
  `*W`/UTF-16, no fixed struct ABI, no goal of running existing Win32 binaries or source
  unmodified. (If you need to run real Win32 programs on Linux, that is what
  [Wine](https://www.winehq.org) is for. Wine is a *reference* and a behaviour *oracle* for
  ZUIL, never a dependency.)

**Why build it at all, given Wine exists?** The justification is the **SDL3 backend**:
GPU-accelerated, embeddable as one small `.so`, and portable toward Android / iOS / web /
networked-UI — places a Win32 emulator cannot follow. ZUIL also collapses the *parallel-backends
tax* (maintaining a Win32 version and an SDL version of everything) into a single SDL3 target you
write UI against once.

---

## 2. Decisions at a glance

| Decision | Choice | Why |
|---|---|---|
| Build ZUIL vs use Wine | **Build it** | SDL3 portability + tiny embeddable `.so`; Wine = reference/oracle only |
| Relationship to Win32 | **Inspiration, not fidelity** | Keep the good ideas, drop `*W`/struct-ABI/binary-compat baggage |
| API style | **Loose redesign for SDL3 + Lua** | Clean names, UTF-8 throughout, per-event handlers — not a `WndProc` switch |
| Who provides widgets | **User-space** (Lua/Python), with an optional bundled module | Widgets-in-script are trivial & forkable; native C-ABI widget objects are painful |
| ZUIL's own scope | **Mechanism, not policy** | A small primitive layer that makes *both* widget disciplines cheap |
| Default widget discipline | **Immediate mode** (Dear-ImGui-style, **not** functional-pure) | Tiny API, no FFI callbacks, return-value interactions; mainstream and proven |
| Retained mode | **Also supported** over the same mechanism | Forms / editable text / focus are more natural retained |
| Remote-UI ("umbilical") | **Kept reachable**, not required | Via a recordable draw choke-point + serializable input (§7) |

---

## 3. The core split: mechanism, not policy

ZUIL (native, C ABI) provides a **mechanism**. **Widgets are policy and live in user-space.**

This split is deliberate and is the single most important design choice:

- ZUIL is a C ABI for *scripting hosts*. Defining a `Button` as a **Lua/Python table** is
  trivial and endlessly forkable. Defining it as a **native, C-ABI-exposed object** is painful —
  every property/method needs a C entry point and struct marshalling, repeated per widget
  forever.
- ZUIL therefore owns **no** `Button`/`ListBox`/`Label`. It owns the primitives those are built
  from. (This mirrors the predecessor `zig-sdl`'s validated stance: *"widgets are userland; the
  toolkit's value is the layout/interaction/draw primitives."*)

---

## 4. The "one mechanism" (native C ABI)

The primitive set, designed so that **both** retained and immediate widgets sit on top of it
unchanged:

- **Draw vocabulary** with clip/region push-pop: `clear`, `fill_rect`, `draw_rect`, `draw_line`,
  `draw_text`, `blit_rgba`.
- **Input, two ways**: the raw **event queue** (`poll_event`) *and* a derived per-frame
  **snapshot** — mouse pos/buttons/modifiers plus *edges* (pressed-this-frame,
  released-this-frame, text-entered-this-frame).
- **Text services**: `text_size(font,text)` measurement, and **text-input / IME** enable + the
  entered-text events. (These cannot be done in user-space — they need the font engine and the
  platform IME.)
- **An id-keyed interaction registry**: `hot` / `active` / `focused` tracked by id, plus a
  hit-test helper. *This is the shared heart that makes both disciplines work.*
- **A redraw-policy switch**: continuous (every frame) *or* on-invalidate.
- **A clip + 2-D transform stack** (translate/scale): local coordinate spaces — the basis for
  canvas, scrolling/zoom, and DPI. See [canvas.md](canvas.md), [layout.md](layout.md).
- **An optional offscreen render-target**: cache expensive/static canvas content; **recreatable**
  on GPU-context loss (see [mobile.md](mobile.md)).
- **Pointer input incl. multitouch + gestures**: mouse and touch unified (tap/long-press/pan/
  pinch); note touch has no *hover*.
- **Platform lifecycle events**: background/foreground/rotation/low-memory and **GPU-context-loss**
  (so caches/render-targets can be rebuilt).

---

## 5. Two widget disciplines over one mechanism

Retained vs immediate are not different engines — they are different answers to **where widget
state lives** and **who triggers repaint**. Same primitives; different convention.

### Retained (Win32 / GTK / Qt flavour)
A widget is a *persistent object* the app/user-space holds: `Button{rect,label,on_click,state}`.
The loop routes each event to the widget under the cursor (hit-test), the widget mutates its own
fields and *invalidates*, and the paint step walks the widgets drawing each. Event-driven;
repaint only what changed. Natural for forms, focus/tab order, and **editable text**.

### Immediate (Dear ImGui / the predecessor — **ZUIL's default**)
No widget objects. Each frame the app *re-declares* the UI by calling functions that both draw
and report interaction: `if ui.button("OK") then … end`. The toolkit keeps only tiny `hot`/
`active` state keyed by id. Paint + logic are fused; redraw every frame. Tiny API, **no FFI
callbacks** (interactions are return values), trivial lifetimes.

| Widget | Retained | Immediate (default) |
|---|---|---|
| **button** | object + `on_click`; loop hit-tests, fires callback | `if ui.button("OK")` → clicked-this-frame |
| **canvas** | `Canvas{rect, on_draw(dc)}` | draw inside a region in your frame — *trivial either way* |
| **text field** | `{text,caret,sel,focus}`; `on_key` edits; loop manages focus | `s.t = ui.input(id, s.t)`; toolkit tracks caret by id |

> **Canvas** is the easy case — it is just the draw vocabulary scoped to a rect; it needs
> nothing from a widget system. **Editable text** is the hard case and the main reason the
> mechanism provides native text measurement + IME, and the reason retained stays available.

---

## 6. What "immediate-mode by default" means in practice

"Default" is not abstract — it is five concrete settings:

1. **Headline run loop is immediate**: `zuil.run(function(ui) … end)` calls your frame fn every
   frame and presents.
2. **The bundled widget module is immediate**: `ui.button/label/slider/text/canvas`,
   return-value style.
3. **Repaint defaults to continuous** (with throttling/vsync), not paint-on-demand.
4. **State ownership defaults to the app** (you keep your `state`; widgets read/write it) plus
   tiny id-keyed toolkit state.
5. **Per-event handlers (`on_paint`/`on_key`) are the advanced/secondary path** — present for
   retained / paint-on-demand UIs, but not what the first tutorial shows.

i.e. **"default" = what `zuil.run()` does with no args, what the README's first example uses, and
what the shipped widgets assume.** Everything else stays available but opt-in.

---

## 7. The functional-purity trade-off (and the escape hatch)

The predecessor `zig-sdl` enforced a *functional* immediate mode —
`frame(state, input) -> (state', command_buffer)`, pure and serializable — specifically to get a
networked **"umbilical"** (run the UI over a socket / on Android via a thin client) and trivial
hot-reload/testability *for free*.

ZUIL's default is **not** functional-pure: it is ordinary imperative Dear-ImGui-style (mutable
state, side effects allowed, no pure-frame contract). That is the mainstream, easier path.

**The non-obvious part:** dropping purity in *user code* does **not** forfeit the umbilical.
What enabled remote-UI was never app-code purity — it was (a) **all drawing flowing through one
recordable choke-point** and (b) **input being a serializable snapshot**. ZUIL keeps both in the
*mechanism* (every draw goes through the vocabulary, which can be recorded; input is a plain
struct). So you may write fully imperative user code **and** keep remote-UI / Android / hot-reload
reachable later. Functional purity is therefore an *optional user-space style*, not a
ZUIL-level requirement.

---

## 8. Native vs user-space — the dividing line

- **Must be native (in `libzuil.so` / the Zig core):** window + event loop + redraw policy; the
  draw vocabulary + **clip & 2-D transform stack**; `blit_rgba` + an **optional render-target**;
  **text measurement**; **text-input / IME / soft-keyboard**; **pointer / multitouch + gestures**;
  **lifecycle / GPU-context-loss** events; the id / hit-test / focus registry.
- **Stays in user-space (Lua/Python):** every actual widget — `Button`, `Label`, `Slider`,
  `Checkbox`, `Canvas`, `TextField`, lists, layout. Shipped as an **optional, forkable** default
  module (`zuil_widgets.lua` / `.py`); replace or ignore it freely. Written **once** against the
  single SDL3 backend (the cure for the parallel-backends tax).

---

## Consumers & build artifacts — one core, two faces

ZUIL is **one Zig core with two front doors**:

- **`src/zuil.zig` — the core: an idiomatic Zig API** (slices, enums, error unions, structs).
  What a **Zig app imports directly** — the path for desktop *and* mobile.
- **`src/c_abi.zig` — a thin `export fn` C ABI veneer** over the core — the *lingua franca* for
  every non-Zig binding: **C**, **C++** (`extern "C"` + an optional RAII header), **Lua** (LuaJIT
  FFI), **Python** (ctypes/cffi). See [bindings.md](bindings.md).

`build.zig` emits both artifacts:

- `b.addLibrary(.{ .linkage = .dynamic })` → **`libzuil.so`** (the FFI surface), and
- `b.addModule("zuil", …)` → a **Zig package** other `build.zig.zon` projects depend on and
  **statically link** (e.g. a mobile app — see [mobile.md](mobile.md)).

So **desktop = scripting convenience** (LuaJIT/Python → C ABI); **mobile / production = a Zig app
→ the Zig API → ZUIL, statically linked**. The C ABI is a *veneer*, not the core.

**Bonus:** immediate-mode widgets are *functions, not objects* (`button(id, rect, label) -> bool`),
so they are trivially C-ABI-able. The bundled immediate widget set can live **in the Zig core** —
used directly by Zig apps *and* exported through the C ABI to Lua — one set, both paths, no
per-language duplication. (The "native widget objects are painful" caveat applied only to
*retained* widgets, which stay language-local.)

---

## 9. Status & roadmap

- **Step 0 — done & verified.** `libzuil.so` builds (Zig 0.17-dev, SDL3 via translate-c), exports
  one C-ABI symbol, loaded from LuaJIT (`examples/smoke.lua`) and Python/ctypes
  (`examples/smoke.py`).
- **M1 — mechanism + window.** Window, the `zuil.run()` loop (immediate, continuous redraw by
  default), input snapshot + event queue, draw vocabulary, clip, id/hit-test/focus registry. A
  first immediate-mode demo.
- **M2 — text + pixels.** SDL3_ttf text measurement/draw + IME; `blit_rgba` software framebuffer.
- **Widget module.** An optional user-space immediate-mode widget set; a retained convention
  documented alongside for forms/text.

---

## Further reading (topic docs)

- **[Canvas](canvas.md)** — the owner-draw escape hatch; direct paint vs render-to-texture.
- **[Layout](layout.md)** — layout as user-space policy; the schemes and the immediate/retained
  cost-model flip.
- **[Mobile](mobile.md)** — SDL3 on Android/iOS; touch/lifecycle/safe-area; the Zig-app + NDK
  deployment.
- **[Bindings](bindings.md)** — the wxWidgets-style multi-language story: one core, many faces
  over the C ABI (Zig / C / C++ / Lua / Python).

---

## 10. Decision log

- **2026-06-09** — Bootstrap. Chose: build ZUIL (driver = SDL3 portability + embeddable, Wine as
  oracle only); Win32 = inspiration not fidelity; loose redesign (per-event handlers, UTF-8);
  mechanism-not-policy with **user-space widgets**; **immediate mode by default**, *not*
  functional-pure (ImGui-style), with retained also supported over the same mechanism; keep the
  recordable-draw choke-point + serializable input so remote-UI stays reachable. Step 0 landed
  and published to `github.com/arkenidar/zuil` (Unlicense).
- **2026-06-09** — Refined to **one core, two faces**: an idiomatic Zig API (primary; the Zig-app
  path incl. mobile) + a C-ABI veneer (FFI). `build.zig` emits `libzuil.so` *and* a Zig module.
  Mobile target = a **Zig app statically linking ZUIL** via SDL3's Android/iOS packaging (no
  on-device interpreter; iOS AOT sidesteps the LuaJIT no-JIT limit). Added to the native
  mechanism: clip + 2-D transform stack, optional render-target, multitouch/gestures,
  lifecycle/context-loss. Split the design into topic docs: canvas, layout, mobile, bindings —
  and framed the multi-language story as a **wxWidgets-style parallel** (one core; Zig / C / C++ /
  Lua / Python bindings over the C ABI).
