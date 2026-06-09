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

## Status

Early bootstrap. **Step 0** (build / link / FFI pipeline) is done and verified; **M1** (the UI
core — window + `zuil.run()` loop + the `on_paint`/`on_key`/`on_mouse` drawing vocabulary) is next.

---

> On this GitHub Pages site each doc has two URLs: the **rendered (HTML)** version at its
> extensionless path (e.g. <https://arkenidar.github.io/zuil/mobile>) and the **raw Markdown**
> at the `.md` path (e.g. <https://arkenidar.github.io/zuil/mobile.md>). The `.md` links above
> also render normally on github.com.
