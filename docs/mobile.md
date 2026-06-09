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

## The honest part: Zig + NDK (untested)

Zig is a strong cross-compiler — `zig build -Dtarget=aarch64-linux-android` is the target. The
rough edges are the **Android plumbing**, not Zig-the-language:

- wiring **bionic libc / the NDK sysroot**, linking NDK libs (`liblog`, `libandroid`);
- building **SDL3 for Android** and the **Java `SDLActivity` glue**;
- the Gradle / APK packaging.

**De-risk with cheap, device-free, link-only spikes (fail fast):**

1. cross-compile a *trivial, no-SDL* Zig lib to `aarch64-linux-android` → proves the NDK/bionic
   wiring;
2. then cross-compile the Step-0 `libzuil` (needs SDL3-for-Android present) → proves the SDL link.

If the Android NDK / an Android SDL3 build aren't installed, the spike stops early — and *that*
tells us what to install first.
