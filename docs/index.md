# ZUIL — design docs

**ZUIL** is a small Zig shared library (`libzuil.so`) exposing a clean **C ABI**, consumed from
**LuaJIT** (and C / C++ / Python / Zig). It renders with **SDL3** and takes *loose inspiration*
from the Win32 GUI model — windows, an event/dispatch loop, a paint step, a drawing vocabulary —
redesigned cleanly for SDL3 + Lua. Not a Win32 compatibility layer.

Source & build instructions: <https://github.com/arkenidar/zuil>

## Documents

- [Architecture](architecture.md) — the model: *mechanism-not-policy*, immediate-mode by default,
  the *one core / two faces* (Zig API + C-ABI veneer) build shape, and the decision log.
- [Canvas](canvas.md) — the owner-draw escape hatch; direct paint vs render-to-texture.
- [Layout](layout.md) — layout as user-space policy; the schemes and the immediate/retained
  cost-model flip.
- [Mobile](mobile.md) — SDL3 on Android/iOS; the Zig-app + NDK path; **spikes A/B/C verified**
  (a Zig+SDL3 app ran on the emulator).
- [Bindings](bindings.md) — the wxWidgets-style multi-language story: one core, many faces over
  the C ABI.
- [Scripting & clients](scripting.md) — cross-platform consumption: **Lua-first**, the
  static/dynamic linkage split, **LuaJIT-FFI vs PUC-Lua C-API**, the umbilical as a dev strategy,
  and iOS by proxy. *(LuaJIT cross-builds for Android arm64 — proven 2026-06-10.)*
- [Web / WASM](web.md) — Emscripten as **user-target and devel-target**: the second "hard case",
  the VS Code run/test/debug loop, the REPL-channel design. *(Step-0 wasm smoke **proven
  2026-06-10** — node + browser, `zig build -Dwasm`.)*
- [Events](events.md) — input, network, timers on **one pump**: the event-injection primitive,
  the opt-in transport module, umbilical/REPL/messages/timers, and the **async/await** position
  (the pump as reactor).
- [Umbilical](umbilical.md) — **script deployment & remote dev cycling**: logic-push first, the
  channel catalogue (script/logs/eval/assets), topologies incl. `adb reverse` and VPS, the
  framed-TCP-push protocol with HTTP-pull fallback, and **debugging as procedures**.
- [M1 plan](m1.md) — the **M1 execution plan**: spike-first sub-steps (events-ABI, wasm pump
  inversion), the smoke-gate matrix, and what is fenced out of the milestone.
- [Analysis](analysis.md) — a curated descriptive analysis of the whole project: code-vs-design
  status, the firm vs semi-fluid decision layers, possibilities, and risks (snapshot 2026-06-10).

## Status

Early bootstrap. **Step 0** (build / link / FFI pipeline) is done and verified; **M1** (the UI
core — window + `zuil.run()` loop + the `on_paint`/`on_key`/`on_mouse` drawing vocabulary) is
next — its gated execution plan is [m1.md](m1.md).

---

> On this GitHub Pages site each doc has two URLs: the **rendered (HTML)** version at its
> extensionless path (e.g. <https://arkenidar.github.io/zuil/mobile>) and the **raw Markdown**
> at the `.md` path (e.g. <https://arkenidar.github.io/zuil/mobile.md>). The `.md` links above
> also render normally on github.com.
