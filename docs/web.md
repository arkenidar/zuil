# Web / WASM — user-target and devel-target

*Part of the ZUIL design record — see [architecture.md](architecture.md).*

This doc records the **web** consumption strategy: ZUIL compiled to WebAssembly via
**Emscripten**, both as a **user-target** (shipping ZUIL apps that run in a browser) and as a
**devel-target** (shareable demos, a browser umbilical thin-client, headless CI, and the VS Code
run/test/debug loop with a live-iteration REPL channel). It extends [scripting.md](scripting.md)
(the platform-constraint ledger gains a second "hard case") and the *one core, two faces* build
shape. The closing ledger states **concerns**, **hypotheses**, and **choices** explicitly.

**Proven on 2026-06-10 (Spike W, the foundation):** `zig build -Dwasm` cross-compiles the
Step-0 core to a `wasm32-emscripten` static `libzuil.a` (translate-c against the Emscripten
sysroot + SDL3 *port* headers — the NDK `-isystem` trick, replayed); `emcc` links it with
`--use-port=sdl3` and `-g`; the smoke runs **headless under node** (`zig build -Dwasm
wasm-smoke` → `ZUIL ok - linked SDL3 version = 3004002  (3.4.2)`, the port's SDL, emsdk 6.0.0)
and **in a browser** (`zig build -Dwasm wasm-serve` → `http://127.0.0.1:8080/smoke_web.html`),
with DWARF for both `smoke_web.c` *and* `zuil.zig` present in the wasm.

---

## 1. Toolchain & build shape: Zig builds the archive, emcc owns the link

The division of labour **mirrors Android exactly** (see [mobile.md](mobile.md)): Zig
cross-compiles the core; the *platform* toolchain does the platform link/packaging. On Android
that toolchain is Gradle/SDLActivity around the SDL3 AAR; on the web it is **emcc**, which
injects the JS runtime, the **SDL3 port** (`--use-port=sdl3`; `sdl3_ttf` also exists for M2),
and the browser glue:

    zig build -Dwasm                  # → zig-out/lib/wasm32-emscripten/libzuil.a
    zig build -Dwasm wasm-smoke       # emcc-link examples/smoke_web.c + .a → run under node
    zig build -Dwasm wasm-serve       # emcc-link the .html → serve on 127.0.0.1:8080

Needs `-Demsdk=<path>` or `$EMSDK` (what `emsdk_env.sh` exports). Translate-c reads the **port's
headers from the emscripten sysroot cache** — not the system `libsdl3-dev` ones — so declarations
stay in lockstep with the library emcc actually links (the port lags/leads the system lib; 3.4.2
vs 3.2.10 today). The emsdk is a *toolchain*, exactly like the NDK — **not** a Zig package
dependency; `build.zig.zon` stays empty.

**Static `.a` only.** The web has no `dlopen`: there is no analogue of the LuaJIT-FFI dynamic
face (Emscripten SIDE_MODULEs exist but are fragile and out of scope). The web therefore joins
**iOS in the static-archive column** of [scripting.md](scripting.md) §2.

## 2. The web is the second "hard case" — and the ABI already fits

Every constraint iOS imposes, the web re-imposes — which *re-validates* the existing invariants
rather than straining them:

| Constraint | iOS | Web | ZUIL's answer (already decided) |
|---|---|---|---|
| No JIT | ✅ | ✅ (no LuaJIT wasm port — its interpreter is per-arch hand-written assembler) | **PUC-Lua + C-API module, static** — the blessed shape |
| No runtime loading | `dlopen` restricted | no `dlopen` at all | static `libzuil.a`, one self-contained binary |
| No FFI callback trampolines | W^X forbidden | no codegen from linear memory | **poll-style pump**; callbacks are consumer sugar |

So the web Lua face is **PUC-Lua compiled to wasm, statically linked beside ZUIL in one
module** — `require("zuil")` via `package.preload`, identical to the iOS shape. One design now
serves desktop, Android, iOS, *and* web with the same two shims of [scripting.md](scripting.md) §3.

**JS is a new face, for free.** Emscripten exposes the C ABI to page JavaScript via
`Module.cwrap` / `ccall` — a thin shim over the *same* `zuil_*` exports, exactly the
[bindings.md](bindings.md) thesis (adding a language = a shim, never a core change). JS can be
the logic host outright, or just the embedder gluing the ZUIL canvas into a larger page.

## 3. Main-loop inversion — the one real ABI constraint the web adds

Browsers forbid a blocking main loop: a wasm app gets a **per-frame callback**
(`emscripten_set_main_loop`), it never owns a `while (true)`. Consequence for the C ABI:

> **The pump must keep a non-blocking poll form.** A frame callback pumps-until-empty, draws,
> returns. A C ABI whose only event entry point blocks (a `WaitEvent`-style call) cannot run in
> a browser frame callback.

This costs nothing — the poll pump is already the centre ([scripting.md](scripting.md) §4) — but
it is now *load-bearing from two directions* (no-trampolines **and** frame-callback), so it is
recorded as a hard requirement: blocking waits may exist as desktop conveniences, never as the
only door. `zuil.run()` (the loop-owning sugar) grows an Emscripten flavour internally — SDL3's
own `SDL_main`/callbacks machinery handles most of the inversion. Emscripten's ASYNCIFY (which
fakes blocking by unwinding/rewinding the wasm stack) is noted and **rejected as the default**:
it taxes code size and speed to recover a shape ZUIL doesn't need.

## 4. User-target integration surface

What "a real app in a browser tab" needs, the SDL3-Emscripten backend's mechanism for it, and
where the core/policy line falls:

- **Events** — DOM pointer / touch / keyboard / wheel events are translated by SDL3's Emscripten
  backend into the same SDL event queue; ZUIL's pump is **unchanged**. Multitouch works (DOM
  touch events). The core never learns the web exists.
- **Soft keyboard / IME** — the hard one (it already was on Android/iOS — [mobile.md](mobile.md)).
  Mobile-browser keyboards only open for focused DOM inputs; engines/SDL use a hidden-`<input>`
  pattern to summon them and to receive composed text. Constraint recorded for **M2**: text input
  flows through SDL3's text-input API (`SDL_StartTextInput`, composition events) — **never raw
  keycodes** — so the browser backend can drive it. Quality on mobile browsers is a top open
  question; desktop-browser typing is expected to be unremarkable.
- **Resizable canvas / responsive layout** — three sizes exist: canvas CSS size, framebuffer
  size, and `devicePixelRatio` (HiDPI). SDL3 owns the mapping; ZUIL sees ordinary window-size /
  pixel-density values in the input snapshot. Responsiveness is then **user-space policy**, and
  immediate mode makes it trivial: layout is recomputed every frame from the current size
  ([layout.md](layout.md) — the cost-model flip favours immediate here). Browser quirk: full-
  screen requests must originate from a user gesture.
- **File resources** — there is no real filesystem. Options: `--preload-file` (bundle into
  MEMFS at build time), `fetch` (async — friction against a sync-looking API), IDBFS/OPFS
  (persistence). The core barely touches files — the one real consumer is **fonts for SDL3_ttf
  (M2)**, and the blessed pattern there is *preload/embed* (the `sdl3_ttf` port exists).
  Resource loading otherwise stays consumer policy; SDL3's `SDL_IOStream` works under
  Emscripten for the cases that look like file I/O.
- **Threads** — wasm threads need SharedArrayBuffer, which needs COOP/COEP response headers —
  which **GitHub Pages cannot set**. ZUIL is single-threaded by design, so this costs nothing:
  demos and default builds stay thread-free.

## 5. Devel-target: what the web buys development

- **Shareable demos.** Each milestone's demo can be published as a `.wasm` page on the existing
  GitHub Pages site — anyone can try ZUIL with zero install. (Static hosting suffices precisely
  because the builds are thread-free, §4.)
- **A browser umbilical thin-client.** The umbilical's device end
  ([scripting.md](scripting.md) §5) compiled to wasm: a browser **tab** replays the draw stream
  and ships input back — a zero-install remote display, parallel to (and even lower-friction
  than) the phone thin client. **Constraint recorded now, cheap because it's early:** browsers
  cannot open raw TCP sockets, so the umbilical protocol must be **transport-pluggable and
  message-framed** — carried over TCP natively and **WebSocket** in the browser, same frames.
- **Headless CI.** The node smoke (`wasm-smoke`) runs with no display and no browser — a
  continuous gate on the wasm build. Later, SDL's dummy video driver extends this to API-level
  tests beyond Step 0; pixel/interaction tests would go through browser automation (CDP /
  Playwright) when there are pixels to test.

## 6. The dev loop in VS Code (run / test / debug)

- **Run**: `zig build -Dwasm wasm-serve` → open `http://127.0.0.1:8080/smoke_web.html` in the
  VS Code **Simple Browser** (or any browser). `printf`/`SDL_Log` output lands in the page and
  the browser console; under `wasm-smoke` it lands on stdout.
- **Debug**: builds link with `-g`, so the wasm carries **DWARF** — verified to reference both
  the C driver *and* `zuil.zig`. VS Code's js-debug has built-in WebAssembly DWARF debugging;
  Chrome DevTools has the C/C++ DWARF extension. How well *Zig* source-level stepping resolves
  (vs C) is a verify-and-record item as the core grows — the sections are present.
- **Test**: `wasm-smoke` is the automated gate (node, headless, exit code + expected line).

## 7. Live iteration: the REPL channel (design — lands with M1+)

The eager part: make a **running** ZUIL instance operable from outside, so a human at a prompt
*or an AI agent* can iterate against live state — edit-loop latency near zero, no
rebuild-redeploy. (Implementation needs a loop and an embedded script host, so it lands with
M1+; the *shape* is fixed now so nothing forecloses it.)

- **What it is**: one **message-framed protocol over pluggable transports** — TCP socket
  (desktop), **WebSocket** (browser — the same constraint, and plausibly the same framing, as
  the umbilical), and the **Chrome DevTools Protocol** as the zero-custom-code interim: CDP can
  already evaluate JS in the page (reaching the C ABI via `Module.cwrap`, §2) and read the
  console — an AI agent can drive that *today* against the Step-0 page.
- **Payloads**: a Lua chunk handed to the embedded host (`luaL_dostring` on PUC-Lua — web/iOS;
  LuaJIT on desktop), or JS in page context, or raw draw-vocabulary commands.
- **Relation to the umbilical**: the REPL is the **logic-injection dual** of the umbilical's
  draw-streaming — same framing discipline, opposite direction. Umbilical out: *pixels leave*
  the logic host. REPL in: *logic enters* the running host. Together they make a live instance
  fully external-operable; the framing should be designed once and shared.
- **Agent-operability is an explicit design goal.** The loop *build → serve → connect → inject
  → observe (console / pixels) → iterate* must be drivable by a human and by an AI agent alike:
  keep the channel scriptable, keep observations machine-readable (structured replies, not just
  prose logs). This is also why ZUIL development itself can be agent-accelerated: the whole loop
  is CLI-shaped.
- **Security**: a REPL channel is, by definition, a remote-code-execution port. **Dev-only**:
  bound to localhost / explicit opt-in, never compiled into shipped artifacts.

## 8. Positioning: a framework with liberal uses — yes, by construction

The license and the architecture make the same statement. **Unlicense** (public domain): any
use, no attribution, no copyleft — nothing to negotiate. **Mechanism-not-policy**: no imposed
widget set, layout regime, or app skeleton to fight. **A library, never runnable**: ZUIL is
always embedded in *someone else's* program. The consumption topologies multiply accordingly —
in-process (Zig/C/C++), scripted (Lua/Python/JS), remote (the umbilical thin client), and
REPL-driven (live injection) — on desktop, Android, iOS, and now the web. License liberality
and architectural liberality are one design stance, not two.

---

## 9. Concerns · Hypotheses · Choices

**Concerns** (constraints we design around)
- The Emscripten SDL3 port is flagged *experimental* and its version skews from the desktop
  system SDL3 (3.4.2 vs 3.2.10 today) — behaviour differences will surface as the API grows.
- Mobile-browser soft-keyboard/IME quality through the hidden-`<input>` pattern is unproven
  here (M2's hard case, again).
- PUC-Lua under wasm is an interpreter inside a VM — speed is a question mark for logic-heavy
  apps (immediate-mode redraw itself is native ZUIL/SDL3, unaffected).
- Async `fetch` vs a sync-looking resource API; preload sidesteps it only for bundled assets.
- Canvas focus / keyboard-capture quirks (browsers swallow shortcuts; gesture-gated APIs).
- Zig source-level DWARF stepping quality in js-debug/DevTools — sections verified present,
  stepping ergonomics not yet exercised.

**Hypotheses** (believed, not yet proven)
- The browser umbilical thin-client is the **lowest-friction remote display of all** — a URL
  instead of an install — and may become the default dev surface even for mobile work.
- One message-framing discipline can serve both the umbilical and the REPL channel.
- CDP-as-interim-REPL is good enough for agent-driven iteration until the WebSocket channel
  exists.

**Choices** (decided 2026-06-10)
- **Emscripten is the web path**; Zig builds the static archive, **emcc owns the final link**
  (the Android division of labour, replayed). emsdk is a toolchain, never a Zig dep.
- **Static-only on the web**; the web joins iOS as the second hard case, and the web Lua face
  is **PUC-Lua + C-API, static** — the same blessed shape.
- **The C-ABI pump must keep a non-blocking poll form** (frame-callback compatible); blocking
  waits are at most desktop conveniences. ASYNCIFY rejected as default.
- **JS is a face** (cwrap/ccall over the same C ABI) — a shim, no core change.
- **The umbilical (and the future REPL) protocol is message-framed and transport-pluggable** —
  WebSocket-carriable from day one.
- **The REPL channel is designed as the umbilical's logic-injection dual**, with
  **agent-operability** (human *and* AI) an explicit goal; dev-only, localhost/opt-in.
- M2 text input flows through SDL3's text-input API exclusively (never raw keycodes), keeping
  the browser/IME backend drivable.

---

## Further reading

- [Architecture](architecture.md) — mechanism-not-policy, the poll-able primitive set, one
  core / two faces, the decision log.
- [Scripting & clients](scripting.md) — the linkage split, the two Lua shims, the umbilical,
  the no-JIT/no-W^X reasoning the web now re-validates.
- [Mobile](mobile.md) — the Android build the wasm target mirrors; soft-keyboard/IME notes.
- [Bindings](bindings.md) — the consumer matrix the JS face joins.
