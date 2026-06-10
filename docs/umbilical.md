# Umbilical — script deployment & remote dev cycling

*Part of the ZUIL design record — see [architecture.md](architecture.md).*

This doc records the **enhanced umbilical**: not just remote-render (architecture **§7**,
[scripting.md](scripting.md) **§5**) but **script deployment** — the logic-push channel that
collapses the device edit→see cycle to desktop speed — plus the channel catalogue, topologies,
the wire protocol, security, and **debugging as a first-class topic**. It is reconciled against
[events.md](events.md), which owns the layer below: framing is core mechanism, frames arrive as
`message` events via the injection primitive, and the opt-in TCP transport moves them. *This doc
owns what the frames mean*; per events.md's fence, the core never does. The predecessor
`zig-sdl-gui` designed (and partly proved) these ingredients; §7 gives each an
adopt/adapt/reject verdict — inspiration, not fidelity. The closing ledger states **concerns**,
**hypotheses**, and **choices** explicitly, with firmness grades (1 = hard … 10 = soft).

---

## 1. Why: the dev-cycle argument

The cost being attacked is **iteration latency on a device**:

| Loop | Latency | What moves |
|---|---|---|
| Desktop file-watch reload | sub-second | nothing — a local file mtime |
| **Device redeploy** (rebuild APK + reinstall) | **minutes** | the whole app, again |
| **Logic-push** (umbilical) | sub-second | a few KB of Lua text over a socket |

The device host is installed **once**; thereafter every edit is a text push. The framing adopted
from the predecessor: **logic-push is literally hot-reload where the file arrives over a socket**
— the same reload machinery, a different source of bytes. That makes it the cheaper,
higher-value first step; full **remote-render** (the thin-client topology of scripting.md §5)
earns its keep only for many-thin-clients fan-out or no-script-on-device platforms (iOS), and is
deferred accordingly (§2, §8).

---

## 2. Capacities: the channel catalogue

One framed protocol, multiple channels — concretely, each channel is a **channel id on `message`
events** ([events.md](events.md) §2/§5): the transport posts a frame, the consumer-side host
dispatches on the id. **v1, designed fully now:**

| Channel | Direction | What / why |
|---|---|---|
| `script_push` | dev → host | whole-file deploy on save; the host reloads with **state preserved** and a **pcall guard** (§7) — a broken push shows an error view, never a dead app |
| `log` / `error` | host → dev | `print` output and Lua errors mirrored back to the dev box — no `adb logcat` needed |
| `eval` | dev → host, reply back | an arbitrary chunk = the **REPL channel** of [web.md](web.md) §7 / [events.md](events.md) §5b — inspect and poke live state; `return zuil.sdl_version()` → `3002010` is its canonical round trip |
| `asset_push` | dev → host | fonts/images keyed by path; pairs with a draw vocabulary that carries *names, not pixels* (`image(src,…)`) |

**Designed-in, deferred:** `remote_render` (the per-frame recorded draw stream ↔ serialized
input — needs M1's recordable choke-point), `state_sync` (serialize the Lua state table for
migration/restore), `screenshot` pull (verify device pixels from the desk), input record/replay
(device-level testing), multi-client fan-out. Channel ids are cheap; reserving these costs one
table row each.

---

## 3. Topologies

- **dev ↔ same machine** — loopback; the degenerate case. A plain **file-mtime watch** gives the
  same reload without any socket, and stays the blessed local mode (§7).
- **dev ↔ Android device** — over **`adb reverse`**: the device connects *out* to a port adb
  maps back to the dev box. No listening port on the device, works over USB, survives Wi-Fi
  changes. This is the topology logic-push exists for.
- **dev ↔ LAN device** — plain TCP to the dev box's LAN address; same protocol.
- **dev ↔ VPS** — two roles adopted from the predecessor: a **Lua distribution authority**
  (pushes text — no compiler on the VPS) and a **cross-compile server** (only when the *native*
  core changes, which is rarely — that is the point of the split). Carried over SSH tunnels (§5).
- **pull mode** — for networks where no socket survives: the HTTP-pull fallback (§4).
- **iOS note** — there is no script host on the device; the device end is the **native thin
  client** (Swift/C over the static `.a`, scripting.md §5–6) speaking `remote_render`. Same
  frames, same channel ids, no Lua on device.

---

## 4. Transport & protocol (the normative part)

**The layer split, post-[events.md](events.md):** *framing* is core mechanism (length-delimited
frames + channel id); the *mover* is the core's **opt-in `std.net` TCP module** — or any
consumer-side substitute posting through the same `zuil_event_post` (a browser WebSocket
necessarily; a pure-FFI POSIX-socket Lua host validly). *This section specifies the protocol
above both*: what frames exist, who connects, what happens on failure. The core moves these
frames and never interprets them.

- **Primary: framed TCP, push model.** Frame shape (proposed, within the core framing
  discipline): magic + **protocol version byte** + channel id + u32 payload length + payload.
  Version mismatch = **refuse loudly** at hello — a silent best-effort umbilical wastes exactly
  the debugging time it exists to save. Payload encoding stays **per-channel** (script/asset
  payloads are raw bytes; `eval`/`log` replies want a small structured encoding — serialization
  is events.md's named non-decision, exercised first here).
- **Connection direction: the host connects *out*** wherever possible (`adb reverse`, the
  LuaPanda precedent) — a device behind NAT/USB needs no open port. The dev-side tool is the
  listener.
- **Failure semantics:** the host keeps the **last good script** through disconnects and failed
  pushes; the dev tool retries with backoff; pushes are **idempotent** (re-push of identical
  bytes is a no-op reload at worst). Reconnect is the normal case, not the exception — Wi-Fi
  roams, USB re-enumerates.
- **Fallback: HTTP-pull, specified as degraded.** The host polls `GET /app.lua` with
  `If-Modified-Since`/ETag against any static server (`python3 -m http.server` suffices).
  Script-push only: no back-channel, no `eval`; logs fall back to the on-screen error view +
  logcat. It exists because it works through anything that passes HTTP.
- **Where the policy lives: the consumer-side host.** Reload machinery, `eval` dispatch
  (`luaL_dostring` / `loadstring`), log mirroring — all consumer-space, per the events.md fence.
  Exception, recorded: `remote_render` needs the core's *recording hook* at the draw choke-point
  (already promised by architecture §7) — but its serialization and transport still live above
  the fence.

---

## 5. Security stance

Pushing executable text is **RCE-by-design** — that is the feature. The
[events.md](events.md) §7 stance (dev-only, localhost-bound, explicit opt-in, never started by
default) is inherited and extended per topology: loopback/USB (`adb reverse`)/private LAN are
the personal-umbilical cases and need nothing more. Beyond them: **transport security is SSH
tunnels** (`ssh -R`/`-L`) — *not* TLS-in-protocol, keeping the protocol plain and reusing keys
that already exist — plus a **pre-shared token in the hello frame** as a belt-and-braces gate.
Sandboxed Lua environments and multi-client auth stay on the deferred ledger (§8).

---

## 6. Debugging — multi-layer, multi-language, remote

The procedures matrix, layer × location, building on recipes the predecessor **proved locally**:

| | Local desktop | Android device | Remote VPS |
|---|---|---|---|
| **Lua** | LuaPanda loopback `:8818` (proven) | same, over `adb reverse tcp:8818` — device-identical to loopback | same, over `ssh -R 8818:localhost:8818` |
| **Zig / native** | gdb on the host binary (proven) | NDK `lldb-server`/`gdbserver` + `adb forward`, attach to the host process | `gdbserver` over an SSH tunnel |
| **Both at once** | the predecessor's "dual debug" compound (proven) | run both tunnels; a gdb halt freezes the process, LuaPanda parks inside the frame | same pattern |

The umbilical's **own** debugging contribution needs no debugger attach at all: the
`log`/`error` back-channel is remote printf; `eval` is live inspection; the on-screen pcall
error view mirrors to the dev box. In practice this triad is expected to remove most
debugger-attach needs (hypothesis, §9). Known limits, recorded: LuaPanda stepping through
LuaJIT tail calls is imperfect; JIT-off on device changes *timing*, never semantics.

---

## 7. Ingredients from zig-sdl-gui — adopt / adapt / reject

Inspiration, not fidelity — every ingredient gets a verdict:

**Adopt** — logic-push-first sequencing; **state survives reload** (app state table held by
registry ref across script swaps); **pcall guard → on-screen error** (a bad push degrades to an
error view); **`@`-chunkname** so tracebacks name the real file; opt-in env-var debugger hookup;
**mtime watch as the local degenerate mode**; the two VPS roles; "umbilical optional in two
senses" (optional to build, optional to run).

**Adapt** — the serializable boundary moves: the predecessor cut at a Lua-side pure `frame()`
contract; ZUIL cuts at the **C-ABI draw vocabulary + poll pump** (mechanism level, any host
language — architecture §7). Hot-reload machinery moves from inside the binary
(`src/script/lua.zig`) to a **consumer-side Lua host over the C ABI**. The predecessor's
length-prefixed codec and `Transport {Local, Tcp}` split are adapted into —  and subsumed by —
[events.md](events.md)'s core framing + opt-in transport + injection primitive: the ideas
survive, one layer lower and behind a fence.

**Reject** — functional-pure `frame(state,input) → (state', cmds)` as a *requirement* (already
rejected, architecture §7; purity stays an optional user style); networking or scripting *logic*
inside the core library (the fence: the core moves frames, never interprets them).

---

## 8. Sequencing (recorded, not executed now)

- **U0** — this design record.
- **U1** — desktop↔desktop logic-push spike: pure Lua both ends, buildable at **Step 0** (pushed
  scripts are smoke-level until M1 gives them something to draw).
- **U2** — Android host over `adb reverse` (after spike E lands the LuaJIT-drives-ZUIL APK).
- **U3** — `eval` + `log` channels (the REPL smoke of events.md §5b is U3's acceptance test).
- **U4** — `remote_render` thin client (post-M1; the iOS story).

**Deferred ledger:** multi-session/fan-out, auth + sandboxed env, TLS-in-protocol (if SSH ever
isn't enough), `state_sync`, input record/replay, `screenshot`.

---

## 9. Concerns · Hypotheses · Choices

Firmness grades as in [events.md](events.md) §8: 1 = hard … 10 = soft.

**Concerns** (constraints we design around)
- Logic-push is RCE-by-design; safe only under the dev-only/opt-in stance (§5) — auth and
  sandboxing remain open. *(stance firm; mechanics 9.0)*
- iOS has no on-device script host — the umbilical's iOS face is the native thin client +
  `remote_render`, which waits on M1. *(1.5 — platform fact + roadmap)*
- Devices roam: reconnect/idempotent-re-push must be the normal path, or the umbilical is
  flakier than the redeploy it replaces. *(4.0)*

**Hypotheses** (believed, not yet proven)
- **Logic-push collapses device iteration to desktop speed** — the whole bet; U1/U2 prove it.
- **`eval` + `log` remove most debugger-attach needs in practice**; the full matrix (§6) is for
  the residue.
- The predecessor's reload recipe (registry ref + pcall + `@`-chunkname) ports unchanged to a
  consumer-side host over the C ABI.
- One protocol-version byte + refuse-loudly is enough version discipline for a personal-scale
  protocol.

**Choices** (decided 2026-06-10)
- **Framed TCP, push model, primary; HTTP-pull specified as the degraded fallback.** *(4.0)*
- **All four v1 channels designed now** — `script_push`, `log`/`error`, `eval`, `asset_push` —
  as **channel ids on `message` events**; `remote_render` and the rest designed-in but
  deferred. *(channels 4.5; the ids-on-message mapping 3.5, inherited from events.md)*
- **The host connects out** (`adb reverse` / SSH `-R`); the dev tool listens. *(5.0)*
- **Mechanics delegated to [events.md](events.md)**: framing in core, frames-as-`message`-events,
  the opt-in `std.net` transport as the default mover — consumer-side movers (WebSocket, FFI
  sockets) stay valid through the same injection primitive. *(inherits events.md grades)*
- **Umbilical policy lives consumer-side**: reload, dispatch, mirroring — the core moves frames,
  never interprets them. *(1.5 — the fence)*
- **Remote security = SSH tunnels + hello token**, not TLS-in-protocol. *(6.0)*
- **Debugging recorded as procedures** (the §6 matrix), not as new mechanism — the umbilical's
  contribution is the back-channel triad, not a debugger. *(7.0)*
- **zig-sdl-gui verdicts**: adopt the reload/dev-loop recipes; adapt the boundary (C ABI, not
  pure `frame()`) and the codec/transport (into events.md); reject purity-as-requirement and
  core-side interpretation. *(recorded once; supersedes silence)*

---

## Further reading

- [Architecture](architecture.md) — the umbilical rationale (§7): the recordable choke-point +
  serializable input that make remote-render reachable.
- [Events](events.md) — the layer below this doc: framing, the `message` event, the injection
  primitive, the opt-in transport, the async/await position.
- [Scripting & clients](scripting.md) — the umbilical as dev strategy and third consumption
  topology (§5); iOS by proxy (§6).
- [Web / WASM](web.md) — the browser thin client (§5) and the REPL channel (§7) this doc's
  `eval` channel realizes.
- [Mobile](mobile.md) — the Android packaging the device host rides on.
