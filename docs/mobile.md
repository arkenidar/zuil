# Mobile (SDL3)

*Part of the ZUIL design record — see [architecture.md](architecture.md).*

Mobile is the reason ZUIL uses SDL3 rather than Wine. Because ZUIL is mechanism-not-policy over
SDL3, and SDL3 has first-class Android/iOS support, the rendering / input / text / window
mechanism **ports essentially for free**. Mobile *validates* the architecture; it doesn't
disrupt it.

## Deployment: a Zig app + the ZUIL layer

The chosen mobile shape is a **native Zig application that links the ZUIL Zig module** (see the
"one core, two faces" section of [architecture.md](architecture.md)) — **not** an embedded
interpreter. This sidesteps the two worst interpreter-on-phone problems: no LuaJIT packaging on
Android, and no iOS no-JIT penalty (Zig is AOT).

- **Android:** `SDLActivity` (Java) loads the app's native `.so` and calls `SDL_main`. The Zig
  app provides `SDL_main` (`SDL_MAIN_HANDLED` + `SDL_SetMainReady`), **statically links** ZUIL,
  links **SDL3-built-for-Android**, and ships inside SDL3's Gradle / `.aar` project.
- **iOS:** analogous, and AOT — the LuaJIT no-JIT limit never applies.
- **Desktop scripting (LuaJIT/Python)** stays a convenience; **Zig is the mobile/production path.**

> **Update (2026-06-10): on-device scripting is now a *validated parallel*, not avoided.** LuaJIT
> cross-builds for android-arm64 (NDK r30, FFI included — see below), so a scripted consumer (a
> thin `SDL_main` app embedding a Lua VM that `ffi.load`s `libzuil.so`) is a real option *alongside*
> the Zig-app path. On iOS, where there is no JIT and `dlopen` is restricted, the equivalent is
> **PUC-Rio Lua statically linked via a C-API module** (no `dlopen`, callbacks trampoline-free).
> The Zig-app AOT path remains the production default; the full strategy — linkage split, the two
> Lua shims, the poll-style ABI, and the umbilical as a dev strategy for un-owned/iOS devices — is
> in [scripting.md](scripting.md).

## What mobile adds (vs desktop)

| Area | Desktop | Mobile delta |
|---|---|---|
| **Input** | mouse (with hover) | **touch / multitouch + gestures** (tap, long-press, pan, pinch); **no hover** → hover affordances weaken; bigger hit-targets + touch slop |
| **Text entry** | physical keyboard | **soft keyboard** via `SDL_StartTextInput`; it covers screen → layout must scroll the focused field into view |
| **Lifecycle** | runs until closed | pause/resume/background, rotation, low-memory, **GPU-context loss** → the glyph cache **and** render-target canvases must be **recreatable** |
| **Layout** | window size | **safe-area insets** (notch/status bar), touch-sized default metrics, DPI density |

## Decisions that pay off here

- **Immediate-mode default** → layout recomputed each frame → **rotation / resize / keyboard
  push-up are automatic**.
- **Clip + 2-D transform stack** (from [canvas.md](canvas.md)) → exactly what **pinch-zoom / pan**
  need.
- **Redraw-policy switch** → the lever for **battery** (redraw only on input/animation).
- **Recordable-draw choke-point + serializable input** → enables the **"umbilical"**: run the
  script on desktop, stream to a thin client on the phone.

## Zig + NDK — spikes A & B **verified** (2026-06-09)

The native toolchain path is proven on this machine. Present: Android **NDK r30-beta1**
(`~/apps/android-sdk/ndk/30.0.14904198` — arm64 sysroot, API 21–36), SDK tools (`adb`,
`sdkmanager`, **emulator**, `cmake 4.1.2`), **JDK 21**, and the **SDL3 3.4.10 AAR**
(`~/apps/SDL3-devel-3.4.10-android/SDL3-3.4.10.aar`: prebuilt `libSDL3.so` for all four ABIs +
`SDL3-Headers` + Java `SDLActivity`, via prefab).

- **Spike A ✅** — `zig build-lib … -target aarch64-linux-android --libc <file> -lc` produced an
  ELF *"for Android 34, built by NDK r30"* (NEEDED `libc.so`, `libdl.so`). **Zig does not bundle
  bionic**, so a Zig `--libc` paths file is *required*:

  ```
  include_dir     = <NDK>/toolchains/llvm/prebuilt/linux-x86_64/sysroot/usr/include
  sys_include_dir = <NDK>/toolchains/llvm/prebuilt/linux-x86_64/sysroot/usr/include
  crt_dir         = <NDK>/toolchains/llvm/prebuilt/linux-x86_64/sysroot/usr/lib/aarch64-linux-android/34
  ```
  (`--sysroot` double-prefixes absolute `-L` paths; use the `--libc` file instead.)

- **Spike B ✅** — extracted the AAR's arm64 `libSDL3.so` + `SDL3-Headers`, then cross-built the
  Step-0 call (`SDL_GetVersion`) for `aarch64-linux-android` linking `-lSDL3`. Result: arm64 `.so`,
  **NEEDED `libSDL3.so`**, exporting `zuil_sdl_version`. The native build + SDL link works with
  **no SDL source build** — just the AAR.

**`build.zig` wiring (later):** add an Android target option that sets the module's libc file
(the `.txt` above), points `translate-c`/link at the AAR's extracted `SDL3-Headers/include` +
`android.arm64-v8a/libSDL3.so`, and emits the app `.so` into `app/src/main/jniLibs/arm64-v8a/`.

## Spike C — **PASSED** (2026-06-09): a Zig+SDL3 app ran on the emulator

End-to-end verified — built, packaged, installed, launched, and rendered on Android.

- **App:** a minimal Zig `libmain.so` (x86_64) exporting `SDL_main`, which inits SDL video,
  creates a window + renderer, and renders a solid blue (`#2080ff`) frame for 600 frames.
- **Packaging — no Gradle needed.** Built with the SDK **build-tools only**: app manifest (using
  framework theme `@android:style/Theme.NoTitleBar.Fullscreen`, activity `org.libsdl.app.SDLActivity`)
  → `aapt2 link` (no resources — SDLActivity is code-only) + `classes.dex` (`d8` of the AAR's
  `classes.jar`) + `lib/x86_64/{libSDL3.so, libmain.so}` → `zipalign` → `apksigner`. Simpler than
  the AAR's documented Gradle/prefab route, and it works.
- **Run:** emulator `system-images;android-35;google_apis;x86_64` (KVM-accelerated, headless
  `-gpu swiftshader_indirect`); boot ~28 s; `adb install` → `am start`. logcat showed:
  `Load …/libSDL3.so … ok` → `…/libmain.so … ok` → `SDL: Running main function SDL_main …` →
  `SDL/APP : ZUIL: hello from Zig on Android (SDL 3004010)` → `… window + renderer up; rendering`.
  No crashes; `screencap` captured the blue frame.

  ![ZUIL on the Android emulator — the Zig + SDL3 app (libmain.so → SDL_main) rendering its blue frame on android-35 x86_64](android-spike.png)

**Conclusion:** the Zig-app + ZUIL-layer mobile path is *fully proven* — Zig builds & links a real
Android SDL3 app (spikes A/B), it packages into a signed installable APK, and it runs on Android
(spike C). The remaining work for a real ZUIL mobile app is normal product work (a Gradle project
for distribution, arm64 ABI for devices, real UI), not a feasibility question.
