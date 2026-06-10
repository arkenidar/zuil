# Events — input, network, timers: one pump

*Part of the ZUIL design record — see [architecture.md](architecture.md).*

This doc records how **non-input traffic becomes events**: umbilical frames, REPL chunks,
generic app messages, and timer fires arrive on the *same* poll-style pump as mouse and
keyboard. It extends architecture **§4** (the primitive set gains event injection, a message
variant, and timers) and **§7** (the umbilical), [scripting.md](scripting.md) **§4–5** (why
poll-style wins; the umbilical as a dev strategy), and [web.md](web.md) **§3/§5/§7** (the
non-blocking form; the browser thin client; the REPL channel). It also takes the project's
position on **async/await** (§6). The closing ledger states **concerns**, **hypotheses**, and
**choices** explicitly — each graded for firmness (1 = hard … 10 = soft).

---

## 1. The thesis: everything arrives on one pump

The consumer already owns a loop that drains a non-blocking pump
([scripting.md](scripting.md) §4). The networked-events decision is that *nothing else gets a
second door*:

> **The pump is the single scheduling point.** Input, umbilical frames, REPL chunks, app
> messages, and timer fires are all events in one queue, drained by the same `poll_event`
> the consumer already calls. No side channels, no second loop, no callback registry.

The non-blocking poll form was already load-bearing from two directions — no FFI callback
trampolines (iOS W^X; [scripting.md](scripting.md) §4) and the browser frame-callback
inversion ([web.md](web.md) §3). Networked sources add a **third**: a socket read completing
on another thread (or a WebSocket message landing in JS) must become visible to a loop it
does not own, and an injection-into-the-queue primitive is the only shape that serves all
three at once. The consumer's dispatch gains cases, not structure:

```lua
while zuil.pump(ev) do
  if ev.type == PAINT   then ...                       -- as before
  elseif ev.type == MESSAGE then handle(ev.channel, ev.payload)  -- network/REPL/app
  elseif ev.type == TIMER   then fire(ev.timer_id)               -- scheduled wake
  end
end
```

---

## 2. The event vocabulary grows two variants

Alongside the designed input events (architecture §4), the event union gains exactly two
variants — recorded in direction, not struct layout:

- **`message`** — a *source/channel id* plus a *length-delimited byte payload*. The channel id
  is how consumers tell umbilical control frames from REPL chunks from their own app traffic;
  the payload is opaque bytes to the core, always (§4 makes this a fence, not a convenience).
- **`timer`** (wake) — a *timer id*, delivered when a core-scheduled timer fires. A wake with
  no payload; correlating it to a purpose is the consumer's table lookup.

**Payload lifetime across the C ABI**: the bytes a `message` event points at are valid **until
the next pump call**; a consumer that wants to keep them copies them. This is the same
borrow-then-copy discipline every FFI face (Lua string, Python bytes) naturally applies at the
boundary anyway, and it lets the core recycle queue storage without a free-callback — which
the ABI must not have (no callbacks, ever).

---

## 3. The injection primitive

One new C-ABI entry point, `zuil_event_post`, is how anything outside the loop becomes an
event. Its semantics are the actual design content:

- **Callable from any thread.** This is the door for transport threads (§4), worker threads,
  and any future source the core has never heard of.
- **Never blocks.** The queue is **bounded**; on full, the post **fails fast** with an error
  return — backpressure is the *poster's* problem (drop, coalesce, or retry next frame), never
  the UI loop's. A UI pump that can be stalled by a flooding socket is a denial-of-service
  shaped like an API.
- **Wakes a blocking wait *where one exists*.** Desktop `zuil.run()` sugar may sit in a
  blocking wait between frames; a post must interrupt it so network traffic has frame-rate
  latency, not wait-until-next-input latency. On the web there is no blocking wait to wake —
  the next frame callback simply finds the event ([web.md](web.md) §3); the semantics degrade
  to a no-op, not a difference in behaviour.
- **Ordering**: FIFO per source; merged with input in arrival order. No priority lanes — a
  consumer that needs priorities builds them from channel ids in user-space.

*Substrate note (implementation-open):* SDL's user-event queue (`SDL_RegisterEvents` +
`SDL_PushEvent`) already provides thread-safe posting that wakes `SDL_WaitEvent`, so it is the
plausible substrate. The ABI stays ZUIL-shaped regardless — `zuil_event_post` never leaks SDL
types, so the substrate can change invisibly. On the web this thread-safety costs nothing:
builds are thread-free ([web.md](web.md) §4), every post happens on the main thread.

---

## 4. Framing in core; the opt-in transport module

The umbilical/REPL protocol is already decided to be **message-framed and transport-pluggable**
(TCP natively, WebSocket in the browser — same frames; [web.md](web.md) §5/§7). This doc adds
*who owns what*:

- **Framing is core mechanism.** One framing discipline (length-delimited frames + channel id),
  designed once, shared by the umbilical, the REPL, and app messages. A frame arrives → a
  `message` event is posted. Framing is mechanical and identical for every consumer — exactly
  the kind of thing that belongs beneath the ABI.
- **Payload serialization is explicitly open** — a *named non-decision*. What the bytes inside
  a frame mean (msgpack? JSON? a hand-rolled draw-command encoding?) is decided per channel,
  later, by the thing that owns the channel. Freezing it now would be spec-freeze theatre.

**The transport module — and the mechanism fence.** The core ships an **opt-in TCP transport**
(Zig `std.net` — zero new dependencies, `build.zig.zon` stays empty): connect/listen, read
frames, post each as a `message` event; take outgoing frames and write them. The
mechanism-not-policy reconciliation is a single hard rule:

> **The transport moves frames; it never interprets a byte.** What a REPL chunk means, what a
> draw-stream frame contains, what an app message says — all of it is consumer policy. The
> moment the core parses a payload, the fence is broken.

"Opt-in" is concrete, not aspirational: the module is **never started unless explicitly
called**; its dev default is **localhost-only**; and it must be **excludable from shipped
artifacts** (the mechanics of exclusion are an open issue, §7). It is also *demotable*: because
it sits entirely on the public `zuil_event_post`, an external transport is indistinguishable
from the built-in one — the module could move to user-space later without breaking a single
consumer.

**The browser column**: browsers cannot open raw TCP, so the transport module is simply
*bypassed* — page JS opens a **WebSocket** and feeds each message through the same injection
primitive via `cwrap` ([web.md](web.md) §2). Identical frames, identical events, different
mover. That a consumer-side mover is the *only* option on one platform is the strongest
evidence the fence is drawn correctly: transports are replaceable, the event is the contract.

---

## 5. Four consumers, one mechanism

| Consumer | Inbound (as events) | Outbound (as frames) | Core knows |
|---|---|---|---|
| **Umbilical** | input/control frames → `message` | recorded draw stream | nothing of the protocol |
| **REPL** | code chunks → `message` | structured replies | nothing of the language |
| **App messages** | chat/game-state/sensors → `message` | app traffic | nothing at all |
| **Timers** | fires → `timer` | — | create/cancel only |

- **(a) Umbilical** — the remote/split topology ([scripting.md](scripting.md) §5) restated in
  event terms: on the logic end, the proxy ZUIL records draws and emits them as outgoing
  frames; serialized input and control frames come back as `message` events. On the device
  end, the thin client receives draw frames as `message` events and replays them into real
  ZUIL. Both ends are ordinary pump consumers; the umbilical is a *protocol over* the
  mechanism, not a mode *of* it — that protocol (channels, topologies, failure semantics,
  debugging) is specified in [umbilical.md](umbilical.md).
- **(b) REPL** — the logic-injection dual ([web.md](web.md) §7): a `message` event carries a
  Lua chunk; the consumer's script host dispatches it (`luaL_dostring` on PUC-Lua, `loadstring`
  under LuaJIT) and sends the result back as an outgoing frame. Dispatch is the *host's*, never
  the core's. The canonical request/reply, and the **first end-to-end REPL smoke test** once a
  loop exists: a frame carrying `return zuil.sdl_version()` goes in; the host evaluates it;
  `3002010` comes back as a frame — the core moved frames and never interpreted one, yet the
  whole round trip exercised the only symbol built today, mirroring `examples/smoke.{lua,py}`.
- **(c) Generic app messages** — chat, game state, sensor streams: just another source. A
  consumer claims a channel id, its transport (built-in TCP, its own socket library, a JS
  WebSocket) posts frames, the app dispatches on the id. The core gains **zero knowledge** —
  this row exists precisely to prove the mechanism is not umbilical-shaped.
- **(d) Timers** — core `timer create/cancel`, fires delivered as `timer` events through the
  pump. This is what makes the pump the *single* scheduling point: "redraw in 200 ms",
  "timeout this request", "blink the caret" all arrive the same way input does. Note the
  redraw-policy switch (architecture §4) is a wake by another name — on-invalidate redraw and
  timer delivery are the same underlying "something happened, run a frame" mechanism.

---

## 6. Async/await: the pump is already a reactor

The eager part: with injection (§3) and timers (§5d), the poll pump **is a single-threaded
reactor** — evented I/O in the node.js sense, minus node's defining drawback. Node had to
*invert* control (callbacks own you) because the runtime owned the loop; ZUIL's consumer owns
the loop ([scripting.md](scripting.md) §4), so events are *pulled as data* and control never
inverts. That ordering matters:

> **The C ABI stays poll-based and callback-free. async/await is consumer-side sugar.** The
> same two reasons as ever (no W^X trampolines; browser frame callbacks), plus the third:
> sugar built *over* a pull ABI works in every face at once; callbacks baked *into* the ABI
> would hardcode one face's limitation forever.

What the sugar looks like, per face — none of it requires a core change:

- **Lua coroutines** (the flagship — and the natural fit): `await` *is* `coroutine.yield`. A
  scheduler of a few dozen lines runs inside the consumer's pump loop: a task awaiting a reply
  yields a predicate ("a `message` on channel 7"); each pumped event resumes whichever tasks
  it matches; `sleep(ms)` is "create a core timer, yield until its `timer` event". Sequenced
  network logic reads top-to-bottom (`local reply = await(request(...))`) while the frame loop
  never stops.
- **Python**: an asyncio adapter — a custom loop (or a pump-polling task) that resolves
  futures from events.
- **C++**: C++20 coroutines over the RAII face — `co_await channel(7)` resuming from the pump.
- **JS** (browser): events surfaced as **Promises** by the cwrap shim; `async/await` comes with
  the language.

**What the core must provide for the sugar — and only this**: wakeups (`zuil_event_post`),
timers (so `sleep` is awaitable, not a busy-spin), and the §3 ordering guarantees.
**Request/response correlation ids are payload-level policy, not a core stamp** — the core
would have to interpret payloads to match replies to requests, and §4's fence forbids exactly
that; any channel that wants correlation puts an id in its own payload format.

**Is it convenient? Honestly:** the sugar pays where logic is *sequenced* — REPL tooling,
request/reply protocols, multi-step network flows, anything that reads as "do this, then
that". It is *overhead* where immediate mode already shines: game-like UI that re-reads the
input snapshot every frame needs no tasks at all. Both styles run on the same pump in the same
program; async/await is a library a consumer imports, not a mode ZUIL is in.

---

## 7. Security posture (open issues)

Every injection transport is, by construction, a data-injection surface — and the REPL channel
is a **remote-code-execution port** by *definition* ([web.md](web.md) §7). The stance there is
reaffirmed and extended to the TCP module: **dev-only, localhost-bound, explicit opt-in, never
started by default**. Beyond the stance, the mechanics are deliberately open — recorded as
concerns, not decided: authentication (is localhost+opt-in enough, or does the umbilical need
a token once it leaves the loopback?); frame validation (size limits, malformed-frame
behaviour — the bounded queue of §3 already caps amplification); and what "excludable from
shipped artifacts" means mechanically (a build flag? the module simply never being linked when
unreferenced?). These land with the implementation, where they can be tested rather than
speculated.

---

## 8. Concerns · Hypotheses · Choices

Each item carries a **firmness grade**: 1 = hard (platform fact / standing invariant) … 10 =
soft (deliberately open). The gradient extends analysis.md's firm-vs-semi-fluid framing.

**Concerns** (constraints we design around)
- Browsers cannot open raw TCP — a consumer-side WebSocket mover is the *only* browser
  transport. *(1.0 — platform fact)*
- Injection transports are data-injection surfaces; the REPL is RCE by definition. Auth, frame
  validation/size limits, and ship-exclusion mechanics are open. *(9.0 — mechanics open; the
  dev-only/localhost/opt-in stance itself is firm)*
- A flooding poster must not stall the UI loop — hence bounded queue + fail-fast, with
  backpressure pushed to the poster. *(4.5 — semantics could be re-tuned)*

**Hypotheses** (believed, not yet proven)
- One framing discipline really can serve umbilical, REPL, *and* app messages without a
  priority mechanism in core (channel-id dispatch suffices). *(carried from web.md §9)*
- A few-dozen-line Lua coroutine scheduler over the pump delivers async/await ergonomics
  worth having — to be proven with the REPL smoke (§5b), the first sequenced consumer.
- SDL's user-event queue is an adequate substrate for `zuil_event_post` (thread-safe post +
  wait-wake) without a ZUIL-side queue in front of it. *(7.5 — swappable invisibly)*

**Choices** (decided 2026-06-10)
- **The pump is the single scheduling point** — network, REPL, app messages, and timers arrive
  as events in the same queue as input; no second door. *(3.5)*
- The event union gains **`message`** (channel id + length-delimited opaque payload) and
  **`timer`** variants; payloads are valid until the next pump call, consumers copy to keep.
  *(direction 4.0; names/layout 8.5)*
- **`zuil_event_post`**: thread-safe from any thread, never blocks, bounded queue + fail-fast,
  wakes a blocking wait *where one exists*; FIFO per source, merged in arrival order. *(the
  primitive's existence ~2.0; its exact semantics 4.5)*
- The C ABI **stays poll-based and callback-free**; **async/await is consumer-side sugar**
  (Lua coroutines flagship; asyncio / C++20 coroutines / JS Promises per face) enabled only by
  wakeups + timers + ordering. *(1.0 — both platform-forced)*
- **Correlation ids are payload-level policy**, never a core stamp — matching replies to
  requests would require interpreting payloads. *(6.0)*
- **Framing is core mechanism** (shared umbilical/REPL/app); **payload serialization is a
  named non-decision**, chosen per channel later. *(framing 4.0; serialization 9.5)*
- An **opt-in TCP transport module lives in core** (Zig `std.net`, zero new deps), fenced as
  mechanism — *it moves frames, never interprets a byte* — never started unless called,
  localhost dev default, excludable from shipped artifacts; demotable to user-space because it
  sits on the public injection primitive. *(5.5)* The browser bypasses it: consumer-side
  WebSocket feeds the same primitive, identical frames. *(1.0)*
- **Timers live in core**, delivered as `timer` events; on-invalidate redraw is recognized as
  the same wake mechanism. *(5.0)*

---

## Further reading

- [Architecture](architecture.md) — the primitive set this doc extends (§4), the umbilical
  rationale (§7), the decision log.
- [Scripting & clients](scripting.md) — why poll-style wins (§4); the umbilical as a dev
  strategy and third consumption topology (§5).
- [Web / WASM](web.md) — the non-blocking-pump requirement (§3), the browser thin client
  (§5), the REPL channel this doc gives event-level mechanics (§7).
- [Umbilical](umbilical.md) — the protocol layered over this mechanism: script-push, the
  channel catalogue, topologies, and remote debugging procedures.
- [Bindings](bindings.md) — the faces that will each grow their own async sugar over the one
  C ABI.
