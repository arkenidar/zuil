/* ZUIL Step 0 smoke test, web face: the emcc-side driver that links the
 * wasm32-emscripten libzuil.a (built by `zig build -Dwasm`) against the
 * Emscripten SDL3 port, then prints the same line as smoke.{lua,py}.
 *
 * Not compiled by zig: emcc owns the final wasm link (it injects the JS
 * runtime + the SDL3 port), exactly as Gradle/SDLActivity own the Android
 * packaging — see `zig build -Dwasm wasm-smoke` / `wasm-serve` in build.zig.
 *
 * Deliberately extern-declares the one export instead of including a header:
 * Step 0's point is proving the C ABI crosses the boundary, same as the
 * ffi.cdef / ctypes declarations in the sibling smokes. */
#include <stdio.h>

extern int zuil_sdl_version(void);

int main(void) {
  int v = zuil_sdl_version();
  /* Same format as smoke.lua / smoke.py — but the version is the Emscripten
   * SDL3 *port's* (e.g. 3.4.2 -> 3004002), not the desktop system lib's. */
  printf("ZUIL ok - linked SDL3 version = %d  (%d.%d.%d)\n",
         v, v / 1000000, (v / 1000) % 1000, v % 1000);
  return 0;
}
