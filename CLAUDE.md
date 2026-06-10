# ZUIL — agent guide

A small **Zig** shared library (`libzuil.so` + `libzuil.a`) exposing a clean
**C ABI**, consumed from **LuaJIT** (FFI), Python (ctypes), C, and C++. Renders
with **SDL3**. *Loosely* inspired by the Win32 GUI model (handle-based windows,
event loop, paint step) but redesigned for SDL3 + Lua — **not** a Win32 compat
layer (UTF-8 throughout, no `*W`/UTF-16, no fixed struct ABI).

## ⚠️ Read this before touching the API

**The design docs describe a plan that is mostly NOT implemented yet.** Only
**Step 0** exists in code: `zuil_sdl_version()` in `src/zuil.zig`. `zuil.run()`,
the draw vocabulary, `src/c_abi.zig`, the input snapshot, and the widget set are
**designed in `docs/`, not built.** Do not assume any of them exist — grep first.

`docs/architecture.md` is the authoritative design record (mechanism vs policy,
immediate-mode default, one-core-two-faces). Read it before extending the API;
update its dated **decision log** when a design choice changes.

## Toolchain (fragile — pinned on purpose)

- **Zig `0.17.0-dev.389+f5a1968f6`** (pinned in `build.zig.zon`). This dev build
  uses `addTranslateC` in place of `@cImport`, plus `createModule` /
  `root_module` / `addLibrary` — APIs that churn between dev builds. `zig` must
  be on PATH.
- **SDL3 dev libs**: `libsdl3-dev` (pkg-config name `sdl3`); later milestones
  add `libsdl3-ttf-dev`.
- **LuaJIT** to run the examples.
- **emsdk 6.0.0** at `~/apps/em-sdk` (env `$EMSDK`; not on PATH — use full
  paths or `-Demsdk=`) for the web target. The SDL3 *port* (`--use-port=sdl3`,
  currently 3.4.2) must be materialized once in the emscripten cache; the
  `-Dwasm` build panics with the recipe if it isn't.

## Build & verify

    zig build                   # -> zig-out/lib/{libzuil.so, libzuil.a}
    luajit examples/smoke.lua   # FFI smoke test
    python3 examples/smoke.py   # ctypes smoke test (same output)

Expected: `ZUIL ok - linked SDL3 version = 3002010  (3.2.10)`

Android cross-build (needs `unzip` on PATH):

    zig build -Dandroid -Dndk=<NDK_ROOT> -Daar=<SDL3.aar>
    # or via env: ANDROID_NDK_HOME / ANDROID_NDK_ROOT, ZUIL_SDL3_AAR
    # -> zig-out/jniLibs/arm64-v8a/libzuil.so  +  zig-out/lib/arm64-v8a/libzuil.a

Web cross-build (static-only — the web has no dlopen; see docs/web.md):

    EMSDK=~/apps/em-sdk zig build -Dwasm    # -> zig-out/lib/wasm32-emscripten/libzuil.a
    EMSDK=~/apps/em-sdk zig build -Dwasm wasm-smoke   # emcc link + headless node run
    EMSDK=~/apps/em-sdk zig build -Dwasm wasm-serve   # serve 127.0.0.1:8080/smoke_web.html (blocks)

Web smoke expected: `ZUIL ok - linked SDL3 version = 3004002  (3.4.2)` — the
Emscripten SDL3 *port's* version, not the desktop 3.2.10.

`zig-out/` and `.zig-cache/` are build outputs — never commit them.

## Invariants — do not violate

- **Mechanism, not policy.** The core owns primitives (draw vocab, clip/transform
  stack, input, text measurement/IME, id/hit-test/focus registry). It owns **no**
  `Button`/`ListBox`/`Label` — widgets live in user-space (Lua/Python).
- **Poll-style event pump** is the C-ABI center; callbacks are consumer sugar.
  No FFI callback trampolines (W^X is forbidden on iOS, fragile on hardened
  Android).
- **One core, two faces**: idiomatic Zig API (`src/zuil.zig`, primary) + a thin
  C-ABI veneer (planned `src/c_abi.zig`). The C ABI is a veneer, not the core.
- **Immediate-mode by default**, retained also supported — *not* functional-pure.
- **No Zig-package dependencies** (`build.zig.zon` deps stay empty): SDL3 is a
  system lib (desktop), the prebuilt AAR (Android), or the Emscripten port
  (web) — never a Zig dep.
- Wine is a behaviour **oracle/reference, never a dependency**.

## Conventions

- Comments explain **why**, densely. Match the existing density — see `build.zig`
  and `src/zuil.zig`.
- `zuil_*` snake_case exports, `callconv(.c)`.
- Public domain (Unlicense) — no per-file license headers.

## Layout

    build.zig, build.zig.zon   Zig 0.17-dev build; emits libzuil.{so,a} (+ Android, + wasm)
    src/cdefs.h                SDL3 root header for the translate-c step
    src/zuil.zig               the exported C ABI (Step 0 only, so far)
    examples/smoke.{lua,py}    FFI / ctypes smoke tests
    examples/smoke_web.c       emcc-side driver for the wasm smoke (wasm-smoke/-serve)
    docs/architecture.md       design record — READ FIRST; has the decision log
    docs/{canvas,layout,mobile,bindings,scripting,web}.md  topic deep-dives
