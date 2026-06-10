# Zig-based U.I. Layer — ZUIL

A small **Zig** shared library (`libzuil.so`) exposing a clean **C ABI**, consumed primarily
from **LuaJIT** via FFI. It renders with **SDL3** and takes *loose inspiration* from the classic
Win32 GUI model — handle-based windows, an event/dispatch loop, a paint step, a simple drawing
vocabulary — but is **redesigned for SDL3 + Lua**. It is **not** a Win32 compatibility layer
(if you need to run real Win32 binaries on Linux, that is what [Wine](https://www.winehq.org)
is for); ZUIL borrows the model's good ideas and drops its baggage (no `*W`/UTF-16, no fixed
struct ABI, UTF-8 throughout).

> **Status: early bootstrap.** Step 0 — the build / link / FFI pipeline — is complete and
> verified. The UI layer itself (windowing, events, drawing) is the next milestone.

## Why

- One native, embeddable `.so` instead of maintaining parallel Win32/SDL backends.
- An **SDL3** backend → GPU-accelerated and portable (desktop today; Android / web reachable).
- Drive GUIs from **LuaJIT** (or C) over a small, clean C ABI.

## Requirements

- **Zig 0.17.0-dev** (uses translate-c, `createModule`/`root_module`, `addLibrary`); the exact
  dev build is pinned in `build.zig.zon`.
- **SDL3** development libraries — Debian/Ubuntu: `libsdl3-dev` (later milestones also
  `libsdl3-ttf-dev`). pkg-config name: `sdl3`.
- **LuaJIT** — to run the examples.

## Build & run

```sh
zig build                  # -> zig-out/lib/{libzuil.so, libzuil.a}  (links system SDL3)
luajit examples/smoke.lua  # loads libzuil.so via FFI, prints the linked SDL3 version
python3 examples/smoke.py  # same check, via ctypes
```

Expected output (both):

```
ZUIL ok - linked SDL3 version = 3002010  (3.2.10)
```

`zig build` emits the C-ABI core in **both linkages** — a consumer picks one: `libzuil.so`
(dynamic → LuaJIT `ffi.load`, Python ctypes) and `libzuil.a` (static → C++, native, a PUC-Lua
C-API module). See [docs/bindings.md](docs/bindings.md).

### Android (cross-build)

Cross-compile the `arm64-v8a` libraries against the prebuilt **SDL3 Android AAR** (needs `unzip`):

```sh
zig build -Dandroid -Dndk=<NDK_ROOT> -Daar=<path/to/SDL3-*-android.aar>
# or via env:  ANDROID_NDK_HOME / ANDROID_NDK_ROOT  and  ZUIL_SDL3_AAR
# -> zig-out/jniLibs/arm64-v8a/libzuil.so   (FFI face, loaded by SDLActivity)
#    zig-out/lib/arm64-v8a/libzuil.a        (static, for C++/native/iOS-shaped consumers)
```

`-Dandroid-api=<N>` sets the minSdk / crt API level (default 21). The mechanics — translate-c
against the AAR headers under the Android target, a `--libc` file pointing at the NDK sysroot,
linking the AAR's `libSDL3.so` — are in [docs/mobile.md](docs/mobile.md).

## Layout

```
build.zig, build.zig.zon   Zig 0.17-dev build; emits libzuil.{so,a} (+ Android via -Dandroid)
src/cdefs.h                SDL3 header for the translate-c step
src/zuil.zig               the exported C ABI  (Step 0: zuil_sdl_version)
examples/smoke.lua         LuaJIT FFI smoke test
examples/smoke.py          Python/ctypes smoke test (same output)
docs/architecture.md       design decisions & widget model (read this)
```

## Roadmap (sketch)

- **M1** — window + event loop + drawing vocabulary; per-event handlers
  (`on_paint` / `on_key` / `on_mouse`) with `zuil.run()` owning the loop.
- **M2** — text (SDL3_ttf) and a software-framebuffer blit (pixel / raster use).
- **M3** — an optional widget set.

## Design

The widget model, the *mechanism-vs-policy* split, and why ZUIL is **immediate-mode by default**
(with retained also supported) are written up in
**[docs/architecture.md](docs/architecture.md)** — read that before building on the API.

## License

Released into the **public domain** under the [Unlicense](LICENSE).
