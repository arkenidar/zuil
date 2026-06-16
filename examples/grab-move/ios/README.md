# grab-move on iOS — build recipe (design-only)

> **Not built or verified in this repo's CI/dev host** — iOS needs macOS + Xcode +
> SDL3-for-iOS, none of which exist on the Linux box ZUIL is developed on. This
> records the path; the source is already iOS-ready (see below). Android — the
> same SDL `SDL_main` shape — *is* proven end-to-end (docs/mobile.md, and the
> emulator run), so this is a port of a working pattern, not a feasibility claim.

## Why it's simple here: the C-first hedge

[grab-move.c](../grab-move.c) and the core [src/zuil.c](../../../src/zuil.c) are
both plain C over [include/zuil.h](../../../include/zuil.h). iOS forbids JIT and
restricts `dlopen`, but **AOT-compiled C is exactly what Xcode does** — so there is
no interpreter, no FFI, no dynamic-load problem to solve. You don't even need a
cross-built `libzuil.a`: just add the two `.c` files to the Xcode target.

`grab-move.c`'s entry already handles iOS: under `__APPLE__` it includes
`<SDL3/SDL_main.h>`, so its `main()` is renamed to the `SDL_main` that SDL's iOS
launch shim calls — the identical pattern verified on Android.

## Recipe

1. **Get SDL3 for iOS.** Either `SDL3.xcframework` from an SDL3 release, or build
   SDL from source for iOS (`Xcode/SDL` project). Add it to your app target.
2. **New Xcode project** — "App" (or start from SDL's iOS template). Set a bundle id.
3. **Add ZUIL + the demo** to the target's *Compile Sources*:
   - `src/zuil.c`              (the core C implementation)
   - `examples/grab-move/grab-move.c`
   and add `include/` plus SDL3's headers to *Header Search Paths*.
4. **Link** `SDL3.xcframework` (it carries the iOS launch shim that calls `SDL_main`).
5. **Build & run** on a simulator or device. The frame pump's `while
   (zuil_frame_begin())` loop runs under SDL's iOS run-loop integration; touch maps
   to the mouse snapshot (single-touch), so the existing logic works. Bigger,
   finger-sized hit-targets are a later polish, not a blocker.

## Notes

- **No `-Dios` in build.zig yet.** Compiling the two `.c` files directly in Xcode is
  the simplest route and avoids a cross-build toolchain step. A future `-Dios`
  target (emitting `libzuil.a` against the iOS SDK + SDL3, mirroring `-Dandroid`)
  is the "matches the other platforms" option if a static lib is preferred.
- **App Store note:** a plain AOT C app has none of the downloaded-code concerns the
  (deferred) live-edit/script-push path would raise — this thick client is
  App-Store-shaped by construction.
