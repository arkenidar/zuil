# Scripting & clients across platforms — Lua-first, the umbilical, iOS

*Part of the ZUIL design record — see [architecture.md](architecture.md).*

This doc records the cross-platform **consumption** strategy: who drives ZUIL, how they link it,
what each platform forbids, and the sequencing **choices** that follow. It extends architecture
**§4** (the poll-able mechanism), **§7** (the umbilical), and the *one core, two faces* build
shape — with what was learned (and proven) on 2026-06-10. The closing ledger states the
**concerns**, **hypotheses**, and **choices** explicitly.

---

## 1. The consumption model is gaming-like

ZUIL is a C-ABI library over **SDL3**, so consuming it is **gaming-like**: a real-time frame
loop, immediate-mode by default, input *pulled* as data, drawing issued through one recordable
vocabulary. The two primary client languages are:

- **Lua** — scripting, fast iteration, the bring-up vehicle (§7);
- **C++** — compiled, self-contained, the "serious app" face (wx-like RAII over the C ABI).

Python / C / Zig remain valid faces ([bindings.md](bindings.md)); this doc centres Lua and C++
because they carry the mobile and iteration story. ZUIL stays a **library** on every platform —
never itself runnable; the runnable thing is always a *consumer* (a script host, a C++/Zig app).

---

## 2. Linkage: one C-ABI face, two artifacts (selectable)

The **loading model**, not taste, picks the artifact:

| Artifact | Consumed by | Why this one |
|---|---|---|
| **`libzuil.so`** (dynamic) | LuaJIT **FFI** | `ffi.load` is `dlopen` under the hood — you cannot `ffi.load` a static archive |
| **`libzuil.a`** (static C archive) | **C++**, **PUC-Lua** C-API module, the Zig app, **iOS** | one self-contained binary; no runtime loading |
| Zig **module** (`@import("zuil")`) | a Zig app, static link | the idiomatic-Zig / production path (architecture "two faces") |

`build.zig` emits both linkages of the C-ABI face. **Pick one per app:** statically linking
`libzuil.a` *and* also shipping `libzuil.so` for an in-process script means **two copies** of ZUIL
and its SDL/global state. Across different apps, both artifacts coexist happily.

---

## 3. Two scripting shims over one ABI

Lua reaches ZUIL two different ways, and the difference is decisive on mobile:

| | **LuaJIT + FFI** | **PUC-Rio Lua + C-API module** |
|---|---|---|
| Binding code | ~none — `ffi.cdef` the header | a `luaopen_zuil` shim (hand-written or Sol3-style) |
| Linkage | dynamic `libzuil.so`, `ffi.load("zuil")` | static `libzuil.a`, `require("zuil")` via `package.preload` |
| JIT | yes on desktop; **forced off** on mobile | n/a — always an interpreter |
| C → Lua callbacks | a generated **trampoline** (writable-executable memory) | **free** — function held in the registry, called via `lua_pcall` |
| Cross-builds | a real step, but **proven** (§6) | trivial (pure ANSI C) |
| Sweet spot | desktop + Android ergonomics | **iOS**, hardened Android, the "natural `require`" feel |

The same **poll-style C ABI** sits underneath both; only the shim differs. Write ZUIL once, write
two small shims. PUC-Rio Lua is therefore not a fallback — it is the *blessed* shape where dynamic
loading and executable memory are unavailable (iOS), and it is "easy-going Lua" everywhere.

### Platform × client matrix

| | LuaJIT + FFI | PUC-Lua + C-API | Zig / C++ (native) |
|---|---|---|---|
| **Desktop** | ✅ best — JIT, zero binding code | ✅ works (needs the shim) | ✅ |
| **Android** | ✅ interpreter-mode; `ffi.load` the dynamic `.so` | ✅ static module, rock-solid | ✅ |
| **iOS** | ⚠️ no JIT, `dlopen` restricted (→ static + `ffi.C`), FFI callbacks forbidden | ✅✅ **cleanest** — static, no `dlopen`, callbacks free | ✅ AOT |
| **Web** ([web.md](web.md)) | ❌ no LuaJIT wasm port exists | ✅✅ same blessed shape — PUC-Lua compiled to wasm, static beside ZUIL | ✅ via emcc link (JS `cwrap` is a bonus face) |

---

## 4. The hard case: no-JIT, no-W^X — and why poll-style wins

The constraint that shapes the whole ABI is **scriptability on platforms with no JIT and no
writable-executable memory** — iOS always, hardened Android often. Two consequences:

1. **JIT off ≠ broken.** LuaJIT's **FFI does not depend on the JIT**: FFI *calls* (Lua → `zuil_*`)
   run through the interpreter's precompiled machinery, no runtime codegen. `jit.off()` (forced on
   iOS, often forced by hardened arm64 W^X policy) costs *speed*, not *function*.
2. **FFI callbacks are the trap.** `ffi.cast`-ing a Lua function to a C function pointer (so C can
   call *back* into Lua) generates a small **executable trampoline per callback** → needs
   writable-executable memory → **forbidden on iOS**, fragile on hardened Android. *Even in
   interpreter mode.*

So a **callback-registration** ABI (`zuil_set_on_paint(fn_ptr)`) would silently hardcode a
LuaJIT-on-mobile limitation into ZUIL forever. The decision (architecture §4 already lists
`poll_event` as a primitive; this is the *reason* it must stay the foundation):

> **ZUIL centres a poll-style event pump; the consumer owns the loop. Callbacks are
> consumer-side sugar, never a C-ABI requirement.**

```lua
-- consumer owns the loop — only FFI *calls*, zero callbacks, zero trampolines
while zuil.pump(ev) do
  if ev.type == PAINT then ... end   -- dispatch in pure Lua
end
```

This one shape serves **every** case: LuaJIT-FFI (no trampolines → interpreter-mode everywhere),
PUC-Lua C-API (poll *or* callbacks, both fine), pure-Zig (native loop), desktop FFI (unchanged).
It also *is* the "serializable input" half of the umbilical (§5). `zuil.run()`-owns-the-loop +
registered handlers (architecture §6) becomes optional sugar layered on the pump — not the floor.

---

## 5. The umbilical as a development strategy

The umbilical (architecture §7, [mobile.md](mobile.md)) — **recordable draw choke-point +
serializable input** — was framed as a remote-UI *feature*. It is also a **development
strategy**, and that is the eager part:

- **Decouple where logic runs from where pixels render.** The script/app logic (LuaJIT with full
  JIT, hot-reload, a debugger) runs on the **desktop**; a **thin client** on the phone replays the
  serialized draw stream into real ZUIL/SDL3 and ships serialized input back.
- **It eases devices you don't own.** Install the thin client *once*; then iterate entirely on the
  desktop — no rebuild-redeploy cycle per change, and a briefly-borrowed device is enough.
- **It may ease iOS most of all** *(hypothesis)*. The iOS-side becomes a minimal, stable renderer:
  SDL3 draw-replay + input-capture + a socket — **no scripting engine, no JIT, no `dlopen` of app
  logic** on device. Every constraint-heavy piece stays on the desktop. The iOS surface shrinks to
  "can SDL3 render and a socket open on iOS" — well-trodden ground — which is plausibly buildable
  by someone with a Mac in an afternoon, versus porting the whole scripted stack.

**Scripting is not required.** The umbilical is a property of the *mechanism* — the recordable
draw choke-point + serializable input — not of the logic language. The **logic host** may be Lua
*or* C, C++, or Zig; the choke-point lives in the C core, beneath any binding. And the **device
thin client is pure native** — C / C++ / Zig / **Swift** replaying draws into real ZUIL+SDL3, with
**no scripting engine, no JIT, no `dlopen` of logic** on the device. That is *why* UD is the
cleanest iOS path of all: the device ships a tiny, stable renderer while even a full-JIT LuaJIT
logic host stays on the desktop. Scripting (Lua) is an **accelerant** for the logic host (a
no-recompile edit loop), never a requirement.

The umbilical is a **third consumption topology** (remote/split) over the same poll-style ABI:
the logic end drives a *proxy* ZUIL that serializes; the device end replays into the *real* ZUIL.
Both ends speak the identical pump + draw vocabulary.

The thin client can also be a **browser tab** ([web.md](web.md) §5): the device end compiled to
wasm, replaying draws into ZUIL/SDL3-in-the-browser and shipping input back — a URL instead of an
install. Browsers cannot open raw TCP, so the protocol is **message-framed and
transport-pluggable** (TCP natively, **WebSocket** in the browser — same frames); and the future
**REPL channel** (web.md §7) is the umbilical's *logic-injection dual* over the same framing.

---

## 6. iOS: a design target, validated by proxy

The blocker for iOS here is the **machine, not the design**: this is a **Linux** host, and iOS can
only be built/signed with the **macOS SDK + Xcode**. No Simulator, no cross-compile. So on this
hardware iOS is a **design target, not a buildable one.**

Strategy without a Mac: **apply iOS's constraints on Android and validate by proxy.** iOS imposes
(a) interpreter-only, (b) no FFI callbacks, (c) `dlopen` restricted → effectively static-link.
All three can be *switched on* under Android and tested. If the static-linked, interpreter-only,
callback-free model runs on Android, the iOS port becomes mechanical when a Mac appears (SDL3
already supports iOS; PUC-Lua is portable C; the ABI is iOS-safe by design).

**Proven on 2026-06-10 (the foundation under all of the above):**

- **LuaJIT cross-builds for `android-arm64`, API 21, with NDK r30** — one clean `make amalg` →
  AArch64 `libluajit.a`, **FFI included** (`luaopen_ffi` present). mobile.md's "no LuaJIT
  packaging on Android" worry is retired. (Recipe lives with the toolchain notes; source at
  `~/apps/LuaJIT`.)
- **`build.zig` cross-builds ZUIL for `android-arm64`** (the dynamic `libzuil.so` FFI face),
  linking the SDL3 AAR — see mobile.md.
- **`translate-c` works under the Android target** (NDK sysroot via `-isystem`, bionic
  nullability keywords neutered).

Remaining to demonstrate the LuaJIT-drives-ZUIL chain end-to-end: embed `libluajit.a` in a Zig
`SDL_main` app that runs a script which `ffi.load`s `libzuil.so`, package the APK, run on the
emulator (spike E).

**Swift** is the natural iOS *host* language: it imports the C ABI directly (a module map /
bridging header) and static-links `libzuil.a`, so a Swift app shell — or the umbilical thin client
itself — drives ZUIL with no extra binding layer. A full Swift/iOS treatment is **postponed but
recorded here** so it isn't forgotten.

---

## 7. Sequencing: Lua-first, C++ to follow

**Lua is the easier path than C++ to bring ZUIL up, so Lua leads.** Concretely:

- A Lua script over the C ABI is a few lines and edits in place — fastest loop to exercise each new
  primitive as the mechanism grows (M1+). It is how `examples/smoke.{lua,py}` already validate the
  boundary today.
- Getting ZUIL right *through Lua* (the poll pump, the draw vocabulary, text/IME) shakes out the
  C ABI. **A C ABI proven good for a scripting host is, by construction, good for C++** — C++ then
  consumes the *same* ABI (`extern "C"` + an optional RAII header, [bindings.md](bindings.md)),
  with the umbilical and mobile paths already mapped.

So: **Lua opens the way for ZUIL; ZUIL (proven via Lua) opens the way for C++.**

---

## 8. Concerns · Hypotheses · Choices

**Concerns** (constraints we design around)
- iOS: no JIT; `dlopen` restricted to bundled libs (review-sensitive); FFI callbacks forbidden.
- Hardened Android: W^X often blocks the executable memory LuaJIT JIT *and* FFI callbacks need.
- No Mac here → iOS is unbuildable/untestable on this Linux host.
- Within one process, static `libzuil.a` and dynamic `libzuil.so` must not both carry ZUIL.

**Hypotheses** (believed, not yet fully proven)
- The umbilical eases testing on **un-owned devices** and **iOS** most of all, by keeping all
  constraint-heavy logic on the desktop and shrinking the device-side to a thin renderer.
- iOS support, once a Mac exists, is **mechanical** because the ABI is already iOS-safe and SDL3 +
  PUC-Lua are portable — validated meanwhile by the Android proxy.
- A C ABI proven good for Lua is good for C++ with no core change.

**Choices** (decided)
- ZUIL stays a **C-ABI library**, never runnable; consumers are separate.
- The C ABI **centres a poll-style event pump**; callbacks are consumer-side sugar only.
- `build.zig` emits **both** linkages (dynamic `.so` for FFI, static `.a` for native/iOS), plus the
  Zig module — **selectable, one per app**.
- **Two scripting shims over one ABI**: LuaJIT-FFI (desktop + Android), PUC-Lua C-API (iOS +
  hardened Android + natural `require`).
- **On-device scripting is an embraced, validated consumption mode** — a parallel to the Zig-app
  production path, *not* a replacement (this augments the earlier "no on-device interpreter"
  stance, now that LuaJIT-on-Android is proven).
- **Lua-first sequencing**: bring ZUIL up through Lua, then open C++ over the same ABI.
- The **umbilical is binding-agnostic** — scripting is *optional*. The logic host may be
  C / C++ / Zig / Lua, and the **device thin client is pure native** (no scripting, JIT, or
  `dlopen` on device). This makes UD the cleanest iOS path.
- **Swift** consumes the C ABI natively (static `.a`, module map / bridging header) as the iOS
  host language; detailed iOS/Swift work is *postponed but recorded*.
- **The web is the second "hard case"** ([web.md](web.md), proven 2026-06-10): no JIT, no
  `dlopen`, no trampolines — the same answers apply unchanged (static `.a`, PUC-Lua C-API,
  poll pump), plus one new requirement: the pump keeps a **non-blocking poll form** so it runs
  inside the browser's frame callback.

---

## Further reading

- [Architecture](architecture.md) — mechanism-not-policy, the poll-able primitive set (§4), the
  umbilical (§7), one core / two faces.
- [Mobile](mobile.md) — SDL3 on Android/iOS; spikes A–C; the NDK path.
- [Bindings](bindings.md) — the one-core-many-faces consumer matrix.
- [Web / WASM](web.md) — Emscripten as user- and devel-target; the VS Code dev loop; the REPL
  channel.
