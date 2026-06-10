# Bindings — one core, many faces (the wxWidgets parallel)

*Part of the ZUIL design record — see [architecture.md](architecture.md).*

ZUIL's multi-language story mirrors **wxWidgets**: one native core with many language bindings
(wxWidgets ships wxPython, wxLua, … over its C++ core; ZUIL exposes **Zig / C / C++ / Lua /
Python** over its Zig core).

The parallel is the **distribution model — one core, many faces — *not* the interaction model**:
wxWidgets is retained + sizer-based, whereas ZUIL is immediate-by-default (a wx-like retained +
box/flex feel is the *retained path* of [layout.md](layout.md), available but not the default).

The enabler is a clean **C ABI** (`src/c_abi.zig`): every non-Zig binding speaks it, so adding a
language is a thin shim, never a core change.

## Consumer matrix

| Consumer | Reaches ZUIL via | Linkage | Typical style |
|---|---|---|---|
| **Zig** | the core module (`@import("zuil")`) | static | idiomatic Zig; the mobile / production path |
| **C** | the C ABI directly (`zuil.h`) | static `.a` or dynamic `.so` | plain functions + opaque handles |
| **C++** | the C ABI via `extern "C"` + an optional thin **RAII** header | static `.a` (self-contained) or dynamic `.so` | wx-like classes wrapping handles |
| **Lua (LuaJIT)** | **FFI** (`ffi.load`) | **dynamic `.so`** (required) | immediate-mode functions (`if ui.button() then …`); desktop + Android — **no web** (no LuaJIT wasm port) |
| **Lua (PUC-Rio)** | a **C-API module** (`luaopen_zuil`, `require`) | **static `.a`** | same API; the **iOS-blessed** path — and the **web** path ([web.md](web.md)), callbacks trampoline-free |
| **Python** | `ctypes` / `cffi` | dynamic `.so` | immediate-mode functions (desktop) |
| **JS (browser)** | Emscripten **`cwrap` / `ccall`** over the wasm exports | static `.a` (in the emcc-linked module) | logic host or page-embedder for the web face ([web.md](web.md)) |
| **Swift** | the C ABI via a module map / bridging header | static `.a` | natural **iOS host / thin-client** language (treatment postponed — [scripting.md](scripting.md)) |

`examples/smoke.lua` and `examples/smoke.py` already exercise the Lua (LuaJIT) and Python faces
against the same `libzuil.so`. The **two Lua faces** — LuaJIT-FFI (dynamic) vs PUC-Rio C-API
(static) — and *why the split is decisive on mobile* (no-JIT / no-W^X) are covered in
[scripting.md](scripting.md).

## C++: the wx-like face

C++ consumes the C ABI for free via `extern "C"`; a small header can wrap the opaque handles in
RAII classes for an idiomatic, wxWidgets-flavoured feel — no separate build, it links the same
`libzuil.so` (or the static Zig lib):

```cpp
// sketch — thin RAII over the C ABI
namespace zuil {
  class Window {
    ZuilWindow* w_;
  public:
    Window(const char* title, int w, int h) : w_(zuil_window_open(title, w, h, 0)) {}
    ~Window() { zuil_window_close(w_); }
    void fill_rect(float x, float y, float w, float h) { zuil_fill_rect(w_, x, y, w, h); }
    // …
  };
}
```

## Why this matters

The C ABI is not merely "the FFI surface" — it is the **integration contract** that keeps every
binding thin and keeps the core single-sourced in Zig. **Bindings are policy** (idiomatic shims);
**the core is mechanism.** Adding a language = writing a shim; the core never moves.
