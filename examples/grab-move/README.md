# grab-move on zuil

A clean, **adapted** rewrite of the LÖVE2D GUI `lua-love2d/grab-move`, expressed over zuil's
M1 desktop primitives instead of `love.graphics`. It is zuil's first real immediate-mode
demo — the acceptance test that drove the desktop M1 slice (see the **2026-06-14** entry in
[../../docs/architecture.md](../../docs/architecture.md) §10).

## Run

From the project root (so the relative `libzuil.so` path resolves):

```sh
zig build                            # C impl (default); add -Dimpl=zig for the Zig twin — same ABI
luajit examples/grab-move/main.lua   # interactive
luajit examples/grab-move/main.lua 60   # optional: auto-stop after 60 frames (headless smoke)
```

### Without Zig

This demo needs no Zig toolchain — it loads `zig-out/lib/libzuil.so` by path, and the
C core (`src/zuil.c`) builds that with any C compiler. If `zig build` is unavailable or
broken, hand-build the library first and run the demo unchanged:

```sh
mkdir -p zig-out/lib
gcc -shared -Iinclude -o zig-out/lib/libzuil.so src/zuil.c $(pkg-config --cflags --libs sdl3)
luajit examples/grab-move/main.lua      # or `… main.lua 60` for the headless smoke
```

`src/zuil.c` is in lockstep with the header, so the full M1 surface this demo exercises
is present. See [**Building without Zig**](../../README.md#building-without-zig) for the
fallback ladder and the Windows/MSYS2 note (`SDL3.dll` on `PATH`,
`mingw-w64-x86_64-luajit`).

## What it demonstrates

- **Draggable handles** — drag to move; grabbing brings a handle to front and tints it red.
- **Delete buttons** — the top-right X on each handle removes it.
- **Exclusive tabs (mutex)** — click tab 1 / 2 to switch the panel's content.
- **A clipped, draggable panel** — drag it by its header; its body is drawn with `clip` +
  `translate` and deliberately overflows, so the clip is visible.

Escape (or closing the window) quits.

## How it maps to zuil

- Widgets are plain Lua tables with their own update/draw — **zuil owns no Button**
  (mechanism, not policy). [main.lua](main.lua) is all user-space.
- Input is the per-frame snapshot: `zuil.pressed(1)` gives the click *edge* natively, so the
  original's hand-rolled `click_down` counter is gone.
- The only glue is [zuil.lua](zuil.lua) — a thin LuaJIT FFI wrapper over the C ABI in
  `include/zuil.h`, shaped to look like `love.graphics`.

## Adapted / deferred

This cut is **rectangles + lines only**. Text labels, wrapped text, and icon images need
`text_size`/`draw_text` (SDL3_ttf) and `blit_rgba` — **M2 material**, deferred. The TCL
re-expression (driving these same primitives from mini-tcl via `ticoluna/`) is designed but
not built; see the architecture decision log.
