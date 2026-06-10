# ZUIL — A Descriptive Analysis

*Part of the ZUIL design record — see [architecture.md](architecture.md).*

A point-in-time (2026-06-10) curated read of the whole repository: what the project is, the
state of code vs. design, the goals, the **hard (less-fluid) decisions**, the **semi-fluid
decisions**, the possibilities the design keeps cheap, and an honest risk assessment.

---

## 1. What this project is, in one paragraph

ZUIL ("Zig-based U.I. Layer") is a deliberately small **Zig library rendering through SDL3**,
whose purpose is to be *driven from other languages* — primarily **LuaJIT via FFI**, but equally
Python, C, C++, and Zig itself — over a clean, UTF-8, handle-based **C ABI**. It takes loose
inspiration from the Win32 GUI model (windows as handles, an event loop, a paint step, a drawing
vocabulary) while explicitly refusing to be a Win32 compatibility layer. Its distinguishing
structural trait is that it is currently **~10 lines of shipped code and ~750 lines of unusually
rigorous design documentation** — a project that wrote its constitution before its body.

## 2. The state of the code (vs. the state of the design)

This gap is the single most important thing to understand about the repository:

| Layer | Status |
|---|---|
| Build/link/FFI pipeline ("Step 0") | **Built and verified** — desktop and Android arm64 |
| Android feasibility (spikes A/B/C) | **Proven on emulator** — Zig+SDL3 APK rendered a frame |
| LuaJIT cross-build for Android | **Proven** (NDK r30, FFI included) |
| The actual UI mechanism (M1: window, run loop, draw vocabulary, input) | **Designed only** — does not exist in code |
| Text/IME (M2), widget module (M3), C-ABI veneer (`src/c_abi.zig`) | **Designed only** |

What exists in code is exactly: `src/zuil.zig` exporting one symbol, `zuil_sdl_version()`, which
calls `SDL_GetVersion()` to force the SDL3 link; `build.zig` (172 lines, the most substantial
artifact, emitting dynamic + static linkages for desktop and Android); and two smoke tests
(`examples/smoke.lua`, `examples/smoke.py`) proving the same `.so` is consumable from two FFI
ecosystems. Everything else — `zuil.run()`, `poll_event`, the draw vocabulary, the
id/hot/active/focus registry — lives in the docs as a plan.

This is not a deficiency; it's the project's stated method. [architecture.md](architecture.md)
calls itself "a living design record … kept deliberately explicit so the model is never
re-litigated by accident," and maintains a **dated decision log** (three entries, 2026-06-09 to
2026-06-10). The spikes were chosen to retire the *highest-risk unknowns first* (can Zig
0.17-dev + translate-c + bionic + the SDL3 AAR actually produce a running Android app?) before
investing in the easy middle (drawing rectangles on a desktop).

## 3. The goal, and the justification for existing

The motivating question the docs answer head-on: *why build this when Wine exists?* The answer
has two prongs:

1. **Portability Wine can't follow** — SDL3 gives GPU-accelerated rendering and a path to
   Android, iOS, web, and networked UI from one small embeddable `.so`.
2. **Killing the "parallel-backends tax"** — instead of maintaining a Win32 flavor and an SDL
   flavor of every UI piece, you write against one SDL3 target. Wine is retained as a
   *behavior oracle/reference, never a dependency*.

The end-state vision is a wxWidgets-shaped distribution model (**one core, many language
faces**) but with a Dear-ImGui-shaped interaction model (**immediate-mode by default**), small
enough that the whole widget layer is forkable user-space script.

## 4. The hard decisions (the "less-fluid" layer)

These are logged, argued, and in several cases *load-bearing for platform support* — reversing
them would invalidate proven work. Ordered roughly by how expensive they'd be to undo:

**Mechanism, not policy.** The core owns primitives only: draw vocabulary, clip + 2-D transform
stack, input (event queue *and* per-frame snapshot), text measurement/IME, the id-keyed
hot/active/focused registry, redraw-policy switch, optional render-target, lifecycle/GPU-loss
events. It owns **no** `Button`, `ListBox`, or `Label` — widgets are user-space Lua/Python
tables, shipped as an optional forkable module. The argument is pragmatic: defining widgets as
native C-ABI objects means a C entry point per property per widget forever; defining them as Lua
tables is trivial. This is the constitutional clause everything else derives from.

**Poll-style event pump at the C-ABI center; callbacks are sugar.** This is the most technically
forced decision in the project. LuaJIT FFI *callbacks* (C calling back into Lua) require
generated executable trampolines — writable-executable memory that is **forbidden on iOS and
fragile on hardened Android**, even in interpreter mode. A `zuil_set_on_paint(fn_ptr)` ABI would
silently bake a mobile-fatal assumption into the contract forever. So the consumer owns the loop
and *pulls* events; `zuil.run()` + handlers become optional sugar layered on top. (FFI *calls*
outward, Lua→C, are safe everywhere — that asymmetry is the whole insight.)

**One core, two faces.** The primary API is idiomatic Zig (`src/zuil.zig` — slices, error
unions); the C ABI (planned `src/c_abi.zig`) is a *thin veneer over* it, not the core itself.
Zig apps statically import the module (the mobile/production path); everyone else speaks the
veneer.

**Both linkages, selectable, one per app.** `build.zig` emits dynamic `libzuil.so` (because
`ffi.load` is `dlopen` — you cannot FFI-load a static archive) *and* static `libzuil.a` (because
iOS forbids runtime loading and C++ wants self-contained binaries). The loading model, not
taste, picks the artifact; shipping both into one process means two copies of SDL/global state,
so: one per app.

**Immediate-mode by default, retained also supported — and explicitly *not* functional-pure.**
Both disciplines sit on the *same* primitives; they differ only in where widget state lives and
who triggers repaint. "Default" is made concrete as five settings ([architecture.md](architecture.md)
§6): the headline `zuil.run(frame_fn)` loop, the bundled widgets' return-value style
(`if ui.button("OK") then…`), continuous repaint, app-owned state, and per-event handlers
demoted to the advanced path. Retained stays available chiefly because **editable text** (caret,
selection, focus, IME) is genuinely more natural retained — the docs are honest that text is the
hard case and canvas the trivial one.

**No Zig-package dependencies, pinned dev toolchain.** `build.zig.zon` deps stay empty — SDL3 is
a system lib (desktop) or prebuilt AAR (Android), never a Zig dep. The toolchain is pinned to a
specific Zig 0.17.0-dev build because the build APIs it uses (`addTranslateC`, `addLibrary`,
`root_module`) churn between dev releases. Fragile by admission, pinned on purpose.

**License: Unlicense / public domain.** Maximally forkable, matching the "widgets are yours to
fork" stance.

## 5. The semi-fluid layer (decided in direction, open in detail)

These are commitments whose *shape* is settled but whose execution is hedged, hypothesis-tagged,
or revisable. [scripting.md](scripting.md) §8 is admirably explicit about this, separating
**Concerns / Hypotheses / Choices** — and the hypotheses are the semi-fluid zone:

- **The umbilical (remote UI).** Because all drawing flows through one recordable choke-point
  and input is a serializable struct, the UI can in principle run split: logic (full-JIT LuaJIT,
  hot-reload, debugger) on the desktop, a thin pure-native draw-replaying client on the phone.
  The docs frame this as "kept reachable, not required," and the claim that it's *the* cleanest
  iOS path and the best strategy for un-owned devices is explicitly labeled a **hypothesis**.
  The design preserves the option cheaply; nothing yet depends on it. This is the most
  interesting deferred bet in the project — it's the ghost of the predecessor `zig-sdl`'s
  functional purity, kept alive after the purity itself was dropped
  ([architecture.md](architecture.md) §7's "non-obvious part": app-code purity was never what
  enabled remote UI; the choke-point and snapshot were).

- **iOS overall.** A *design target validated by proxy* — no Mac exists on this Linux host, so
  iOS constraints (no JIT, no FFI callbacks, no dlopen) are switched on under Android and tested
  there. The bet that the eventual port is "mechanical when a Mac appears" is a stated
  hypothesis. Swift-as-iOS-host is *postponed but recorded* — a deliberate parking slot, not a
  decision.

- **On-device scripting — a decision that already moved once.** The 2026-06-09 log said "no
  on-device interpreter"; on 2026-06-10, after LuaJIT was proven to cross-build for
  android-arm64, it was *augmented* to "an embraced, validated parallel" to the Zig-app path.
  This is the clearest evidence of how the project treats fluidity: decisions are firm until
  evidence arrives, then revised *in the log*, with the supersession traceable. The Zig-app AOT
  path remains the production default.

- **The layout menu.** Layout is firmly user-space policy (the core ships text-measure, region
  size, clip/transform, DPI — nothing more), but *which* schemes get bundled is a
  recommendation, not a contract: flow/cursor as the immediate default, a small box/flex helper
  for forms, absolute always available, dock/anchor for the retained path, grid and
  constraint-solving explicitly opt-in or out of scope. See [layout.md](layout.md).

- **Canvas backing strategy.** Direct paint is the default; render-to-texture is the optional
  cache for static/scrollable content — per-canvas choice, with the constraint that textures
  must be recreatable on GPU-context loss. See [canvas.md](canvas.md).

- **The widget set living *in* the Zig core.** A late "bonus" observation: since immediate
  widgets are functions (`button(id, rect, label) -> bool`), not objects, they're trivially
  C-ABI-able — so the bundled immediate set *could* live in the core, used by Zig apps and
  exported to Lua at once. This softens the original "widgets live in user-space" line for the
  immediate case (the painful-native-objects caveat is now scoped to retained widgets only).
  It's stated but not yet committed to in the roadmap — a genuine open seam.

- **Remaining proof, named:** "spike E" — embedding `libluajit.a` in a Zig `SDL_main` app that
  runs a script which `ffi.load`s `libzuil.so` on the emulator — is the one link in the
  scripted-mobile chain not yet demonstrated end-to-end.

## 6. Possibilities — what this design makes cheap

The architecture is best read as an exercise in *option preservation*. Things the current
decisions make reachable at low marginal cost:

- **A scripted app platform**: LuaJIT app logic on desktop and Android, PUC-Lua on iOS, over one
  ABI with two ~small shims — fast-iteration GUI tooling without a compile step.
- **Remote/networked UI and hot-reload** via the umbilical — including a "develop on desktop,
  render on a borrowed phone" workflow that needs only a one-time thin-client install.
- **New language bindings as an afternoon's work** (the wxWidgets parallel,
  [bindings.md](bindings.md)): Swift, or anything with C FFI, is a shim, never a core change.
- **Games-adjacent uses**: the consumption model is explicitly "gaming-like" (frame loop, pulled
  input, immediate draw), so tool UIs, debug overlays, game viewports via canvas, and
  pixel-buffer work (`blit_rgba` for a raytracer) are first-class rather than awkward.
- **Web** is name-checked (SDL3/WASM exists) but is the least-developed direction in the docs —
  a real possibility, currently zero design investment.

## 7. Honest risk assessment

- **Toolchain fragility is the top operational risk** — a pinned Zig *dev* build whose build
  APIs churn; every Zig upgrade is a small migration. The docs own this ("fragile — pinned on
  purpose"), but it's a recurring tax until Zig 1.0-era stability.
- **Design-ahead-of-code risk**: ~750 lines of doctrine rest on a one-function library. The
  decisions are well-argued, but M1/M2 (real input, text, IME) is where designs usually meet
  friction — particularly **IME and editable text**, which the docs themselves flag as the hard
  case. The mitigation is real, though: the riskiest *platform* unknowns (Android toolchain, AAR
  linking, LuaJIT cross-build) were de-risked first, which is the opposite of the usual failure
  mode.
- **Bus-factor / single-author scope**: the design spans desktop + Android + iOS + five language
  bindings + a remote-UI protocol. The mechanism-not-policy split is precisely what keeps that
  tractable — the core stays small and everything wide is a shim or a script — but the breadth
  is still the thing to watch.
- **One process-level footgun is documented but enforceable only by convention**: statically
  linking `libzuil.a` while also `ffi.load`ing `libzuil.so` in the same process duplicates
  SDL/global state.

## 8. Summary verdict

ZUIL is a **design-first bootstrap done unusually well**: a tiny proven seed (one exported
symbol, validated from two FFI ecosystems and cross-built to Android), a constitution that
separates the irreversible (poll-style ABI, mechanism-not-policy, one-core-two-faces, dual
linkage) from the revisable (umbilical, iOS, bundled layout/widget choices) — and a dated
decision log that has already demonstrated it can absorb a reversal (on-device scripting)
without losing coherence. The project's real product so far *is* the decision record; the next
milestone, M1, is where the constitution starts paying rent.
