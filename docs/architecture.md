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
| Remote-UI ("umbilical") | **Kept reachable**, not required | Via a recordable draw choke-point + serializable input (§7); also a dev strategy for un-owned/iOS devices — [umbilical.md](umbilical.md), [scripting.md](scripting.md) |
| Mobile linkage | **Both, selectable** — dynamic `.so` (FFI) + static `.a` (C++/iOS) | Loading model picks it: `ffi.load` needs `.so`; iOS/C++ want static |
| On-device scripting | **Validated path**, parallel to the Zig app | LuaJIT-on-Android proven; PUC-Lua for iOS — [scripting.md](scripting.md) |
| Networked events | **Same pump as input** — injection primitive + opt-in transport | one scheduling point; umbilical/REPL/messages/timers unified — [events.md](events.md) |

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
- **Event injection + timers**: a thread-safe, non-blocking `zuil_event_post` plus **message**
  (channel id + framed payload) and **timer** event variants — how network/umbilical/REPL
  traffic and scheduled wakes arrive on the *same* pump as input. See [events.md](events.md).

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
ZUIL-level requirement. The umbilical itself — script-push, channels, transport, the remote
debugging procedures — is specified in [umbilical.md](umbilical.md), over the event mechanics
of [events.md](events.md).

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

`build.zig` emits the core in **three linkages** (selectable, one per app):

- `b.addLibrary(.{ .linkage = .dynamic })` → **`libzuil.so`** — the FFI surface (LuaJIT `ffi.load`);
- `b.addLibrary(.{ .linkage = .static })` → **`libzuil.a`** — a static C archive for **C++**, a
  PUC-Lua C-API module, **iOS**, and the **web** (`-Dwasm`; no runtime loading in either —
  see [web.md](web.md));
- `b.addModule("zuil", …)` → a **Zig package** other `build.zig.zon` projects depend on and
  **statically link** (e.g. a mobile app — see [mobile.md](mobile.md)).

So **desktop = scripting convenience** (LuaJIT/Python → C ABI); **mobile / production = a Zig app
→ the Zig API → ZUIL, statically linked**. The C ABI is a *veneer*, not the core.

**On-device scripting is also a validated consumption mode** (not only desktop): LuaJIT
cross-builds for Android arm64 (proven 2026-06-10) and PUC-Lua is the iOS-blessed shape. This is a
*parallel* to the Zig-app path, not a replacement — see [scripting.md](scripting.md).

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
  first immediate-mode demo. **Execution plan: [m1.md](m1.md)** — spike-first sub-steps,
  smoke gates, and the milestone fence.
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
- **[Scripting & clients](scripting.md)** — cross-platform consumption: Lua-first sequencing, the
  static/dynamic linkage split, LuaJIT-FFI vs PUC-Lua C-API, the umbilical as a dev strategy, iOS.
- **[Web / WASM](web.md)** — Emscripten as user-target and devel-target; the second "hard case";
  the VS Code dev loop and the REPL-channel design.
- **[Events](events.md)** — input, network, timers on one pump: the injection primitive, the
  opt-in transport module, and the async/await position (the pump as reactor).
- **[Umbilical](umbilical.md)** — script deployment & remote dev cycling: the channel catalogue,
  topologies, framed-TCP-push protocol, and debugging as procedures.

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
- **2026-06-10** — Cross-platform consumption strategy ([scripting.md](scripting.md)). Proved
  **LuaJIT cross-builds for android-arm64** (NDK r30, FFI included) and wired a **`build.zig`
  Android target** (dynamic `libzuil.so` linking the SDL3 AAR). Decided: emit **both** C-ABI
  linkages (dynamic `.so` for FFI + static `.a` for C++/iOS), selectable one-per-app; **two
  scripting shims over one ABI** — LuaJIT-FFI (desktop/Android) and **PUC-Rio Lua C-API** (iOS +
  hardened Android, callbacks trampoline-free); the C ABI **centres a poll-style pump** because FFI
  callbacks need W^X trampolines (forbidden on iOS, fragile on hardened Android); **on-device
  scripting is embraced** as a parallel to the Zig-app path (augmenting the earlier "no on-device
  interpreter" stance); the **umbilical doubles as a dev strategy** for un-owned/iOS devices;
  **Lua-first sequencing** (bring ZUIL up via Lua, then open C++). iOS stays a *design target*
  validated by Android proxy (no Mac on the Linux host).
- **2026-06-10** — Web/WASM target wired & proven ([web.md](web.md)). **Spike W**: `zig build
  -Dwasm` cross-compiles the static `libzuil.a` for `wasm32-emscripten` (translate-c against the
  Emscripten sysroot + SDL3 *port* headers — the NDK `-isystem` trick replayed); **emcc owns the
  final link** (`--use-port=sdl3 -g`); smoke verified headless under node (`wasm-smoke`, SDL
  3.4.2 port) and served in-browser (`wasm-serve`), DWARF present for C *and* Zig sources.
  Decided: **static-only on the web** (no `dlopen`) — the web joins iOS as the **second "hard
  case"**, re-validating poll-pump / no-trampolines / PUC-Lua-static; the C-ABI pump must keep a
  **non-blocking poll form** (browser frame-callback inversion; ASYNCIFY rejected as default);
  **JS becomes a face** (cwrap/ccall over the same C ABI); the umbilical/REPL protocol is
  **message-framed + transport-pluggable (WebSocket-carriable)**; a **REPL channel** is designed
  as the umbilical's logic-injection dual with **agent-operability** (human *and* AI) an explicit
  goal — dev-only, localhost/opt-in. Positioning recorded: liberal-use framework by construction
  (Unlicense + mechanism-not-policy + never-runnable library).
- **2026-06-10** — Networked events designed ([events.md](events.md)). Decided: the pump is the
  **single scheduling point** — umbilical/REPL traffic, generic app messages, and timers arrive
  as **events in the same queue as input**; the core gains a **thread-safe, non-blocking
  injection primitive** (`zuil_event_post` — bounded queue, fail-fast on full, wakes a blocking
  wait *where one exists*) and two event variants (**message**: channel id + framed opaque
  payload, framing shared with the umbilical/REPL, **serialization left open**; **timer**); an
  **opt-in TCP transport module lives in core** (Zig `std.net`, zero new deps), fenced as
  mechanism — *it moves frames, never interprets a byte* — while the browser feeds the **same
  frames via consumer-side WebSocket** into the injection primitive. Position on **async/await**:
  the poll pump *is* a single-threaded reactor (node-style evented I/O, consumer-owned loop); the
  C ABI stays **poll-based and callback-free**; async/await is **consumer-side sugar** (Lua
  coroutines flagship; asyncio / C++20 coroutines / JS Promises per face) enabled only by core
  wakeups + timers; **correlation ids are payload-level policy**. Injection transports stay
  **dev-only, localhost, opt-in**; security mechanics recorded as open issues. The ledger gains
  **firmness grades** (1 = hard … 10 = soft), extending analysis.md's firm-vs-semi-fluid framing.
- **2026-06-10** — Umbilical enhanced ([umbilical.md](umbilical.md)), reconciled against
  events.md. Decided: **logic-push first** — script deployment is the umbilical's high-value
  channel (*hot-reload where the file arrives over a socket*), remote-render designed-in but
  deferred to post-M1; **four v1 channels** (`script_push`, `log`/`error`, `eval`, `asset_push`)
  as **channel ids on `message` events** over events.md's core framing + injection primitive —
  the predecessor's codec/`Transport{Local,Tcp}` ideas are *subsumed* there, one layer lower;
  **framed TCP push primary** (magic + version byte + channel id + length; version mismatch
  refuses loudly; host keeps last-good script, idempotent re-push), **HTTP-pull as the specified
  degraded fallback** (poll + ETag, push-only); the **host connects out** (`adb reverse` / SSH
  `-R` — no listening port on devices); umbilical *policy* (reload, eval dispatch, log
  mirroring) stays **consumer-side** per the moves-frames-never-interprets fence; remote
  security = **SSH tunnels + hello token**, not TLS-in-protocol; **debugging recorded as
  procedures** (Lua/native/dual × local/Android/VPS matrix; LuaPanda + gdb recipes carried from
  the predecessor, which proved them locally); zig-sdl-gui ingredients given explicit
  **adopt/adapt/reject** verdicts (purity-as-requirement stays rejected). Sequencing recorded
  U0–U4 (doc → desktop spike → `adb reverse` host → eval/log → thin client).
- **2026-06-10** — M1 execution plan ([m1.md](m1.md)) — the milestone zoomed into gated
  sub-steps before code. Decided: **spike-first ordering** — Spike E (the event struct across
  four FFIs, no SDL in the build) and Spike P (the pump inverted under the Emscripten frame
  callback) report *before* draw/input are built; the **core/veneer split (`src/c_abi.zig`)
  lands at M1.0**, while there is one symbol to move; the **`message`/`timer` enum slots and
  semantics are M1 scope** even though transports stay post-M1 (gate = the local half of
  events.md's REPL smoke, no socket); every sub-step is **smoke-gated across faces** (LuaJIT +
  Python always; wasm/Android on pump/ABI-touching steps); **raw-struct vs accessor-fn event
  ABI is a named open decision** until Spike E measures it; M1.7's button demo is the
  **fence test** — it must need zero core additions or the mechanism/policy line is wrong.
- **2026-06-10** — **Dual-implementation core — C first.** The C ABI became a real artifact:
  `include/zuil.h` is **the contract**, with **two interchangeable implementations** behind it —
  `src/zuil.c` (C) and `src/zuil.zig` (Zig) — selected per build via `-Dimpl` (**default = c**).
  Why: the pinned Zig *dev* toolchain is the project's most fragile dependency (build-API churn
  between snapshots); a C core compiles with **any** C compiler (gcc / NDK clang / emcc — gcc
  spot-checked end-to-end through LuaJIT FFI), so if Zig ever stalls, `build.zig` degrades to
  *convenience, not dependency* and the project keeps moving. The fallback ladder this buys:
  re-pin / ride to stable Zig → keep compiling C via `zig cc` → any C compiler + any build
  driver. Zig remains a first-class implementation, and **one-core-two-faces survives either
  way**: the idiomatic Zig face can sit on the Zig impl directly *or* wrap the C core through
  translate-c, exactly as every other consumer wraps the header. Both impls smoke-gated on all
  three targets (desktop LuaJIT + ctypes; wasm node smoke; Android arm64 link + symbol).
  Invariant added: **the header is the single source of truth — implementations must not
  diverge from it**, and M1 sub-steps land in *both* impls or the C one explicitly leads with
  the Zig twin trailing in the same sub-step.
- **2026-06-14** — **Zig-first desktop M1 slice, driven by `grab-move` as acceptance test.**
  Implemented a desktop window+draw+input mechanism directly in `src/zuil.zig` as
  `export fn … callconv(.c)` (the emitted symbols are a plain C ABI — LuaJIT consumes them
  unchanged), and **inverted the C-first stance for this work**: the standalone C twin
  (`src/zuil.c`) is *not* maintained for this slice; `include/zuil.h` remains the single source
  of truth. Rationale: owner preference + Zig ergonomics, and Zig's C-ABI is sufficient for the
  FFI faces; C stays as the optional toolchain-fragility hedge, portable later if wanted.
  **Landed exports:** `zuil_window_open/close`, `zuil_frame_begin/end` (poll-style,
  callback-free, consumer owns the loop), draw vocab (`set_color/clear/fill_rect/draw_rect/
  draw_line`), input snapshot **as accessors** (`mouse_x/y`, `mouse_down/pressed/released`,
  `key_pressed`, `should_quit`), and a clip + 2-D **translation** stack
  (`clip_push/pop`, `push/pop/translate`). Acceptance test: an adapted, rect-only rewrite of
  the LÖVE2D `grab-move` GUI runs over these (`examples/grab-move/{zuil.lua,main.lua}`) —
  draggable handles with bring-to-front + delete, exclusive mutex tabs, and a clipped draggable
  panel. **What this falsified / confirmed vs `m1.md`:** (a) the *snapshot-via-accessor* shape
  is sufficient for a real immediate-mode GUI and **sidesteps Spike E** (no event struct
  crosses the ABI; `pressed` gives the click-edge natively, retiring grab-move's hand-rolled
  `click_down`) — accessors stay *soft*, to be confirmed by a 2nd/3rd FFI face and re-opened by
  M1.5's `event_post`/message/timer; (b) the **transform stack fell out cheaply** as a CPU
  offset applied in the draw wrappers (SDL3's 2D renderer has no matrix stack) — so it did
  *not* need to wait for M2; (c) **deliberate deviations for speed**, recorded as debt: M1.0
  (`c_abi.zig` core/veneer split) **skipped**, the 4-face smoke matrix reduced to **desktop +
  LuaJIT only**, and Spike P deferred (wasm-only). The `hot`/`active`/`focused` id-registry was
  *not* needed — grab-move does its own hit-test + z-order in user-space, reinforcing the
  mechanism-not-policy line. Text/IME, `blit_rgba`, and the TCL/ticoluna re-expression are
  designed but deferred (no pixels added). Build/run: `zig build -Dimpl=zig`, then
  `luajit examples/grab-move/main.lua`.
- **2026-06-14** — **C twin brought back to lockstep; the Zig-only deviation is closed.**
  Ported the entire M1 slice into `src/zuil.c` as a line-for-line twin of `src/zuil.zig` (same
  module state, same SDL3 calls, same semantics). Rationale: the C twin exists *only* as the
  toolchain-fragility hedge, and a hedge that omits the whole working surface hedges nothing —
  if Zig stalled today, everything past `zuil_sdl_version` would be lost. Restoring it costs one
  mechanical port and re-arms the hedge for real. Both `zig build -Dimpl=c` and `-Dimpl=zig` now
  export the full surface, pass `examples/smoke.{lua,py}`, and run `examples/grab-move/` +
  `_smoke.lua` identically. One portability note surfaced and was absorbed: SDL3 dropped
  `SDL_bool` (now standard C `bool`), so the twin uses `bool`/`true`/`false`. The header's
  lockstep invariant holds again. **Still open as designed-not-built**: `src/c_abi.zig`
  core/veneer split (so the two faces share one core instead of two hand-kept twins), the 4-face
  smoke matrix, Spike P (wasm), `event_post`/message/timer, and the id-registry.
- **2026-06-14** — **Hedge fired and held — full M1 slice built with zero Zig.** An
  installed Zig newer than the pin (`0.17.0-dev.857` vs `…-dev.389`) broke `zig build`
  outright (`build.zig:351` calls `getInstallPath`, an API that churned out from under
  the pin) — exactly the toolchain-fragility scenario the C-first stance exists for. The
  fallback ladder worked as designed: skip `build.zig`, compile the C twin straight to a
  shared library —
  `gcc -shared -Iinclude -o zig-out/lib/libzuil.so src/zuil.c $(pkg-config --cflags --libs sdl3)` —
  and it ran `examples/smoke.{lua,py}` *and* drove `examples/grab-move/` interactively.
  This **promotes the earlier hedge claim**: the 2026-06-10 entry above recorded gcc only
  "spot-checked end-to-end" for **Step 0** (`zuil_sdl_version`); it is now verified for the
  **whole M1 surface** (window/draw/input/clip/transform), because `src/zuil.c` is in
  lockstep with the header. Environment: Windows/MSYS2 MINGW64, gcc 15.2.0, SDL3 3.4.4
  (so the smoke prints `3004004`, not the pinned-desktop `3.2.10` — version is whatever you
  link). One portability nuance recorded: on Windows the output is a PE DLL merely *named*
  `libzuil.so` (LuaJIT `ffi.load` / ctypes `CDLL` load it by path regardless), and `SDL3.dll`
  must be on `PATH` at runtime. Scope unchanged: the hand build covers the desktop `.so`
  only; `-Dimpl`, Android, and wasm still need `build.zig`. Documented as a first-class
  path in `README.md`, `CLAUDE.md`, and `examples/grab-move/README.md`. (The hedge kept the
  broken `build.zig` from being a blocker; `build.zig` was then repaired too — see next entry.)
- **2026-06-14** — **`build.zig` repaired for newer dev Zig + Windows — both impls build
  again.** Having proven the hedge, fixed the convenience driver rather than leaving it
  broken. Three independent fixes, each verified on Windows/MSYS2 MINGW64: (a) **config
  crash** — `b.getInstallPath` was removed from `std.Build`, so *every* `zig build` died at
  config evaluating the `wasm-serve` step; now serves the web smoke from the emitted `.html`'s
  dir via a `LazyPath` dir-arg (version-robust, no install-path API). (b) **Windows desktop
  link** — lld resolves pkg-config's bare `-lSDL3` to the *static* `libSDL3.a`, whose Win32
  deps `pkg-config --libs` (non-static) omits, so the shared `libzuil` link failed on
  undefined `winmm`/`ole32`/`setupapi`/`gdi32`; supply SDL3's static dep list (from
  `pkg-config --static --libs sdl3`) when targeting Windows, folding SDL3 in **self-contained**
  (no external `SDL3.dll` at runtime — unlike the gcc-shared hedge). (c) **Zig-impl
  translate-c** — `linkSystemLibrary("sdl3")` on the *translate-c* step appended `-lSDL3` to
  it, and on Windows lld tried to merge the static archive's many objects ("coff does not
  support linking multiple objects into one"); translate-c needs only headers, so feed it the
  include dirs alone (`pkg-config --cflags-only-I`) and move the SDL3 link to the final module
  for both impls. Net: `zig build` (C, default) **and** `zig build -Dimpl=zig` both build,
  link, and pass `smoke.{lua,py}` + `grab-move` on Windows. (b)/(c) are no-ops off Windows;
  Linux desktop (`libsdl3-dev`) is unaffected. The example loaders also learned the Windows
  artifact name: Zig emits `zig-out/bin/zuil.dll` (the gcc hedge writes `zig-out/lib/libzuil.so`),
  so `smoke.{lua,py}` + `grab-move/zuil.lua` now try a small candidate list. The pin
  (`0.17.0-dev.389`) is still the supported toolchain; these just keep the door open on a
  drifted dev Zig — the same toolchain-hedge spirit, now extended to `build.zig` itself.
