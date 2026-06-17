# Remote dev — the edit→see loop and the perceive/act/inspect/state substrate

*Part of the ZUIL design record — see [architecture.md](architecture.md).*

This doc consolidates **remote dev** — a topic that was, until now, designed correctly but
*scattered*. Most of its mechanics already live in [umbilical.md](umbilical.md) (script-push,
channels, topologies, debugging), [events.md](events.md) (the injection primitive, the `message`
event, the opt-in transport, the pump-as-reactor), and [scripting.md](scripting.md) (the umbilical
as a dev strategy; the thin client). What was *missing* is the synthesis and two genuinely new
design areas: a **state/reactivity model** and **higher-level semantic descriptions** of the UI.

This doc **owns the synthesis and the new decisions**; it **points to** the docs above for every
mechanic they already own — it never re-specifies them. It is bound by the project's two standing
fences:

- **Mechanism, not policy** (architecture §3): the core owns primitives, never widgets and never a
  reactive engine.
- **The core moves frames, never interprets a byte** (events.md §4): protocol meaning is consumer
  policy.

The closing ledger states **concerns**, **hypotheses**, and **choices** with firmness grades
(1 = hard … 10 = soft), as in the sibling docs.

---

## 1. Why / scope: two capabilities under one name

"Remote dev" is two capabilities that share channels and a transport but answer different needs:

- **(A) The edit→see loop** — collapse device iteration to desktop speed by pushing *logic*, not
  rebuilds. This is the umbilical's high-value case and is **largely designed already**
  ([umbilical.md §1–2](umbilical.md)): logic-push is *hot-reload where the file arrives over a
  socket*.
- **(B) A perceive / act / inspect / state substrate** — synthetic input (act), readable pixels
  (perceive), semantic scene description (inspect), and a state model under all three. This is
  **mostly new**, and its payoff is that the *same* substrate serves two consumers at once:
  **deterministic record-replay testing** and **AI-agent operability**.

The unifying observation: capability (A)'s "logic-tweaking *after verification*" is most powerful
when (B) gives you a deterministic replay to verify *against*. The two halves are complements, not
alternatives.

What this doc owns vs points to:

- **Owns**: the two-capabilities framing; the reactivity model (§4); the readable-pixels primitive
  decision (§6); the semantic-description convention (§7); the unified synchronization model (§8);
  AI-operability as a first-class goal (§9); the expanded security surface (§10).
- **Points to**: framing/transport/injection ([events.md](events.md)); channels/topologies/reload/
  debugging ([umbilical.md](umbilical.md)); the thin client + linkage ([scripting.md](scripting.md));
  the REPL channel + browser mover ([web.md](web.md)).

---

## 2. The substrate map

Honest accounting of where each thread already lives and where the new work is. *Existing* rows are
pointers; *new-edge* is what this doc adds.

| Thread | Already designed in | New edge (this doc) | Firmness |
|---|---|---|---|
| Logic-push | [umbilical.md §2/§7](umbilical.md) | verification-gated push (§3) | edge 7.0 |
| State & reactivity | *(state-survives-reload only)* | the push/pull/lazy model (§4) | 5.5 |
| Synthetic input | [events.md §3](events.md) `zuil_event_post` | record/replay + determinism (§5) | 5.0 |
| Readable pixels | informal `SDL_RenderReadPixels`; `screenshot`/`remote_render` deferred | `zuil_read_pixels` as a core primitive (§6) | 5.0 |
| Semantic description | *(none — id registry is the only anchor)* | a user-space `describe` convention (§7) | 6.0 |
| Synchronization | [umbilical.md §4](umbilical.md), [events.md §3](events.md), `state_sync` deferred | one unified model + schema evolution (§8) | 5.5 |
| AI operability | [web.md §7](web.md) (REPL goal) | the full perceive/act/verify loop (§9) | 4.0 |
| Security | [umbilical.md §5](umbilical.md), [events.md §7](events.md) | per-channel gating + artifact hygiene (§10) | 8.0 |

---

## 3. Logic-push & verification-gated tweaking

The push mechanics are settled: `script_push` deploys a whole file; the host reloads with **state
preserved** (an app-state table held by a registry ref across swaps), guarded by **`pcall` → an
on-screen error view**, with **`@`-chunkname** so tracebacks name the real file
([umbilical.md §2/§7](umbilical.md)). Failure semantics — last-good kept, idempotent re-push,
reconnect-as-normal — are [umbilical.md §4](umbilical.md). Nothing here changes.

**The new edge — "logic-tweaking *after* verification".** Note carefully what "verification" means
today: [`scripts/verify.sh`](../scripts/verify.sh) gates the **native** surface (C↔Zig↔header
lockstep + the FFI/ctypes/grab-move smokes + the gcc hedge). It says **nothing** about a *pushed
Lua chunk*. So "push only verified logic" is a **separate, user-space, dev-side** idea, layered on
the dev tool that owns the listening end ([umbilical.md §4](umbilical.md) — policy lives
consumer-side):

- **Cheap tier**: a pre-push **load/compile check** (`loadstring`/`luac -p`) — never push a chunk
  that won't even parse. Rejects the dumbest breakage before it reaches the device.
- **Strong tier**: replay the chunk against a **recorded session** (§5) and assert the result —
  push only if the deterministic replay still passes. This is where (A) consumes (B).

Recorded as a **hypothesis**, not a built feature: the dev tool *can* gate pushes, the core neither
knows nor cares. *(this stays consumer-side; the core's role is unchanged.)*

---

## 4. State, relations & reactivity disciplines

The most-novel area, and the one most exposed to the mechanism-not-policy fence.

**What the core actually offers for reactivity is small and deliberate**: the **redraw-policy
switch** — continuous vs on-invalidate ([architecture.md §4](architecture.md)) — plus the **wake
primitives**: timers and `zuil_event_post`, both delivered through the one pump
([events.md §5](events.md)). That is *all*. The core ships **no reactive engine**: no signals, no
dependency graph, no memo cache. Those are user-space disciplines, exactly as widgets are.

Three disciplines (and their mixes) sit on those wakes:

- **Pull** — re-derive everything every frame. This *is* the immediate-mode default
  ([architecture.md §5–6](architecture.md)): the frame fn reads the input snapshot and recomputes
  the UI from state, every frame. No invalidation bookkeeping; cheapest to reason about; the
  baseline ZUIL assumes.
- **Push** — invalidate/dirty. A change marks dependents dirty and requests a redraw (the
  on-invalidate switch). Natural for retained widgets and paint-on-demand UIs
  ([architecture.md §5](architecture.md)).
- **Lazy / memoized** — a signal + dependency graph: values recompute *on read*, only when an
  upstream changed. The classic fine-grained-reactivity discipline. Built entirely in user-space on
  top of the same wakes; the core never sees the graph.

**Mixes are expected, not exceptional**: an immediate-mode (pull) frame loop that drives a few
memoized (lazy) expensive derivations and requests an on-invalidate redraw (push) when a background
`message` event lands. All three coexist on one pump.

**Why this belongs in a remote-dev doc** — two relations the substrate forces you to name:

- **Recompute scope on logic-push.** When `script_push` swaps the logic but the registry keeps the
  state table (§3), *what recomputes*? Under pull, everything (next frame re-derives from state) —
  which is why pull is the most reload-robust discipline. Under lazy/push, the pushed code must
  re-establish or invalidate its dependency graph, because the *old* graph referenced the *old*
  closures. **Pull degrades most gracefully across a hot-swap**; lazy/push need a re-seed step.
  *(this is the practical reason the immediate-mode default and the umbilical compose so well.)*
- **State relations across `state_sync`.** When state is serialized for migration/restore (§8), the
  *values* travel but the *dependency graph* (a web of closures) does not — it must be **rebuilt
  from the synced values** on the far side. So the serializable thing is **state**, never the
  reactive graph; the graph is always reconstructed locally. This keeps `state_sync` a data
  protocol, honoring the "frames carry data, not behavior" fence.

**Choice**: the core stays mechanism — redraw switch + wakes only; reactivity disciplines (pull/
push/lazy/mixed) are user-space policy. **Pull is the reload- and sync-robust baseline**; lazy/push
buy efficiency at the cost of a re-seed across swaps. *(5.5)*

---

## 5. Synthetic input & deterministic record/replay

**Synthetic input is already a primitive** — it is just `zuil_event_post`
([events.md §3](events.md)) used by a non-input source: a synthetic pointer/key event is posted
into the same FIFO, merged in arrival order, indistinguishable downstream from a real one. No new
ABI. This is also why the immediate-mode snapshot shape works for it: a synthetic event updates the
same snapshot the frame fn already reads.

**The new edge is record/replay as a composed capability** built from synthetic input + state
snapshots:

- **Record format** (user-space, channel-carried): a timestamped **input stream** plus **periodic
  state snapshots** (§8). The stream is the act-trace; the snapshots are resync points so replay can
  start mid-session and so divergence can be localized.
- **Replay**: re-post the recorded input through `zuil_event_post` on the recorded schedule; assert
  against the recorded pixels (§6) or semantic tree (§7).
- **Determinism requirements** — replay is only meaningful if the logic is reproducible. The
  constraints, recorded as what user code must respect (the core does not enforce them):
  - **input order is the pump's FIFO** — already guaranteed ([events.md §3](events.md));
  - **timer fires must be reproducible** — replay drives logical time from the record, not the wall
    clock, so `timer` events ([events.md §5d](events.md)) fire at recorded offsets;
  - **no hidden wall-clock / RNG in logic** — or seed them from the record. This is the same
    discipline functional-pure frames wanted ([architecture.md §7](architecture.md)), here as an
    *opt-in property of recordable code*, not a requirement on all code.

Record/replay is the **unifier**: synthetic input (act) + state snapshots (state) + assertions
(perceive/inspect) = a deterministic session, which is what §3's strong-tier verification replays
against and what §9's agents use to check their actions. *(5.0)*

---

## 6. Readable output pixels

Two distinct things hide under "readable output pixels", and the docs already lean a specific way:

- **Pull-a-surface** — read back the rendered framebuffer *now*. This already exists **informally**:
  the verify white-box font check calls `SDL_RenderReadPixels` to confirm glyphs rasterize and that
  `text_width` matches the rendered advance (decision log 2026-06-15). It is the natural primitive
  for **screenshot assertions** (§5 replay) and **AI perception** (§9).
- **Streamed sequences** — a continuous feed. The docs deliberately favor streaming the
  **draw-command vocabulary** (the recordable choke-point, [architecture.md §7](architecture.md))
  over streaming pixels: vectors are smaller, resolution-independent, and replayable into real ZUIL
  on a thin client ([scripting.md §5](scripting.md)). That is the deferred `remote_render` channel
  ([umbilical.md §2](umbilical.md)), not a pixel/video stream.

**New decision**: promote **`zuil_read_pixels` to a candidate core primitive** — surface readback
is *measurement-like mechanism* (like text measurement, it needs the renderer and cannot be done in
user-space), and it already exists as an internal check; making it public costs one export and
serves both testing and AI. **Streamed sequences stay `remote_render` draw-commands, deferred** —
pixels are pulled (a frame at a time), draws are streamed. *(primitive 5.0; the pull-pixels /
stream-draws split 4.0, inherited from the choke-point design.)*

---

## 7. Higher-level descriptions of widgets / scene / app

The introspection dual of `eval`: where `eval` *injects* logic, a description channel *extracts*
structure. This pokes the mechanism-not-policy fence the hardest, so the boundary must be explicit.

**Widgets are user-space policy** (architecture §3) — therefore a widget/scene tree **originates in
user-space** and the core cannot emit one. What the core *does* provide is the **minimal semantic
anchor**: the **id / hit-test / focus registry** ([architecture.md §4](architecture.md)) already
names interactive elements by id and tracks `hot`/`active`/`focused`. That registry is the only
core-level semantics; everything richer is layered above it.

So the design is a **convention, not a core feature**: a `describe` channel (a channel id on
`message` events, [events.md §2](events.md)) — dev/agent → host *"emit your scene tree"*, host →
dev/agent a **serialized semantic tree**. The host builds the tree from its own user-space widget
state (cross-referenced with the core id registry for live `hot`/`focused` flags). Suggested levels,
coarse→fine:

- **app** — windows, focus, lifecycle state;
- **scene / window** — regions, scroll/zoom transform, clip;
- **widget tree** — the user-space retained objects or the immediate-mode call tree;
- **element** — `id + role + rect + state + label` (the unit an assertion or an agent targets).

This serves **testing assertions** (find element by role/label, assert state), **accessibility**
(the same tree is an a11y tree), and **AI operability** (§9 — an agent needs structure, not just
pixels). **Fence note, explicit**: the core ships no tree, no roles, no serializer — only the id
registry it already has. The `describe` payload format is per-channel policy, decided by the host.
*(convention 6.0; the id-registry-as-anchor 3.0, inherited from architecture §4.)*

---

## 8. Synchronization model

The synchronization pieces exist but were never gathered. One model, four layers:

- **Protocol-level** — reconnect-as-normal + **idempotent re-push** + last-good-kept
  ([umbilical.md §4](umbilical.md)). Devices roam; this is the floor.
- **Pump ordering** — **FIFO per source, merged in arrival order**, bounded queue + fail-fast
  ([events.md §3](events.md)). The single ordering guarantee everything else builds on.
- **State-level** — `state_sync` (deferred): serialize the state table for migration/restore. **New
  edge — schema evolution**: a logic-push (§3) can change the *shape* of the state the registry
  preserves across reload. So synced/preserved state needs a **version tag + a migration step**
  (run by the host on load) — otherwise a reshaped push reads stale fields. Recorded as the missing
  piece of "state survives reload": it survives only if its *schema* survives or migrates. Per §4,
  only **state values** travel; the reactive graph is always rebuilt locally.
- **Frame-lockstep** — for `remote_render` (deferred): the logic end's draw stream and the device
  end's serialized input must stay in step (input frame N drives draw frame N). This is the one
  place a *clock/sequence* matters beyond FIFO; designed-in with `remote_render`, not before.

**Choice**: synchronization is layered, not monolithic; the only *new* commitment is that
preserved/synced state carries a **schema version + migration hook** (host-side), so logic-push and
state survival actually compose. *(5.5; schema-evolution edge 6.0.)*

---

## 9. AI-agent operability

A **first-class goal**, extending [web.md §7](web.md)'s explicit "a human at a prompt *or an AI
agent*" REPL stance and its "keep observations machine-readable" rule. The point: an agent uses the
**same channels a human dev uses** — there is **no AI-specific ABI**. It rides the substrate:

> **perceive** (readable pixels §6 + semantic description §7) → **act** (synthetic input §5 +
> `eval` [umbilical.md §2](umbilical.md)) → **verify** (replay/assert §5).

Each leg is a channel that already exists or is decided above; the agent loop is their composition.
Two consequences worth recording:

- **Machine-readable beats prose** (web.md §7): the `describe` tree (§7) and structured `eval`
  replies are what make the loop drivable; pixel-only perception (§6) is the fallback, not the
  primary, for an agent — structure localizes intent.
- **ZUIL's own development is agent-accelerable** because the whole loop is CLI/channel-shaped
  (web.md §7) — the same reason this repo's gate and slash commands are scriptable.

**Choice**: AI operability is a *consumer* of the substrate, never a core concept — humans and
agents share channels; keep observations structured. *(4.0)*

---

## 10. Security — the expanded surface

The inherited stance is firm and unchanged: **dev-only, localhost-bound, explicit opt-in, never
started by default**, transport security via **SSH tunnels + a hello token**, the module
**excludable from shipped artifacts** ([umbilical.md §5](umbilical.md),
[events.md §7](events.md)). The new threads *widen the surface*, and that widening is the new
content:

- **Synthetic input (§5)** = **remote-drive**: posting events drives the app as if a user did —
  RCE-adjacent (it can trigger any action the UI exposes).
- **Readable pixels (§6) + semantic description (§7)** = **information exfiltration**: a screen
  scrape and a structure dump leak whatever is on screen / in the tree.
- **Record-replay artifacts (§5) + `state_sync` (§8)** = **secrets at rest / on the wire**: a
  recorded session or a serialized state table may contain tokens, PII, message contents.
- **`eval`** = **RCE by definition** (web.md §7) — unchanged, restated for completeness.

Two new stance points to record (mechanics deliberately left open, like the sibling security
sections):

- **Per-channel capability gating**: a host opts into *which* channels it exposes, not
  all-or-nothing. Exposing `describe` (read) is not exposing `eval` (execute) is not exposing
  synthetic-input (drive). The default-closed posture extends from "the transport is off by default"
  to "each channel is off by default".
- **Artifact hygiene**: replay recordings and state dumps are **data-at-rest that may carry
  secrets** — treat them like logs (don't commit, redact on capture, scope to dev machines).

**Choice**: same dev-only/opt-in/excludable floor; **add per-channel capability gating and artifact
hygiene** as the answer to the wider perceive/act/state surface. Mechanics (token scope, gating
config, redaction) stay open, to be decided with implementation. *(stance 2.0; mechanics 8.0.)*

---

## 11. Sequencing (recorded, not executed)

Slots alongside the umbilical's U-series ([umbilical.md §8](umbilical.md)); most of this is
*designed-not-built*, and the order reflects what is cheap-now vs gated.

- **Promotable now** — `zuil_read_pixels` (§6): it already exists internally as the font white-box
  check; making it a public primitive is one export + a smoke. The lowest-cost real change here.
- **After a pump with injectable events** — synthetic input is `zuil_event_post` (events.md M1
  scope); record/replay (§5) layers on it, user-space.
- **`describe` convention (§7)** — needs a user-space widget layer to describe; lands when there is
  a scene to serialize (post-widget-module).
- **Stays user-space, no core work** — the reactivity disciplines (§4): pull is already the default;
  push/lazy are libraries a consumer imports.
- **Deferred with their owners** — `remote_render` streaming (§6), `state_sync` + schema migration
  (§8), `eval`/`log` channels (umbilical U3), multi-client fan-out.

---

## 12. Concerns · Hypotheses · Choices

Firmness grades: 1 = hard … 10 = soft.

**Concerns** (constraints we design around)
- The new threads widen the attack surface from "code injection" to "drive + scrape + exfiltrate";
  per-channel gating and artifact hygiene are the answer, mechanics open. *(stance 2.0; mechanics 8.0)*
- State survives reload only if its **schema** survives or migrates — a reshaped logic-push reads
  stale fields otherwise. *(6.0)*
- Lazy/push reactivity needs a **re-seed** of its dependency graph across a hot-swap; pull does not.
  *(5.5)*
- The `describe` channel pushes on the mechanism-not-policy fence — kept legal only by originating
  the tree in user-space, anchored on the core id registry. *(3.0)*

**Hypotheses** (believed, not proven)
- The *same* substrate (perceive/act/inspect/state) serves both record-replay testing and AI
  operability with no AI-specific ABI. *(4.0)*
- Verification-gated push (replay-then-push) catches real regressions cheaply at the dev end. *(7.0)*
- Pull is the reload- and sync-robust baseline; the immediate-mode default and the umbilical compose
  *because* of it. *(carried from architecture §6–7)*

**Choices** (decided 2026-06-17)
- **Remote dev is two capabilities** — the edit→see loop (A) and the perceive/act/inspect/state
  substrate (B); this doc consolidates both and points to the owners for mechanics. *(3.5)*
- **Reactivity is user-space policy** (pull/push/lazy/mixed); the core ships only the redraw switch
  + wakes. **Pull is the reload/sync-robust baseline.** *(5.5)*
- **Synthetic input is `zuil_event_post`**, no new ABI; **record/replay** composes it with state
  snapshots, with determinism as an opt-in property of recordable code. *(5.0)*
- **`zuil_read_pixels` is a candidate core primitive** (surface readback = mechanism); **streamed
  sequences stay `remote_render` draw-commands, deferred** — pull pixels, stream draws. *(5.0 / 4.0)*
- **Semantic description is a user-space `describe` convention** (a `message` channel id), anchored
  on the core id registry; the core ships no tree. *(6.0)*
- **Synchronization is layered**; the only new commitment is **schema version + migration hook** on
  preserved/synced state, so logic-push and state survival compose. *(5.5)*
- **AI operability is a consumer of the substrate**, sharing channels with humans; observations stay
  structured. *(4.0)*
- **Security floor unchanged** (dev-only/opt-in/excludable + SSH/token); **add per-channel
  capability gating + artifact hygiene** for the wider surface. *(2.0 / mechanics 8.0)*

---

## Further reading

- [Architecture](architecture.md) — mechanism-not-policy, the primitive set + redraw switch (§4),
  the umbilical rationale + recordable choke-point (§7), the decision log.
- [Umbilical](umbilical.md) — the edit→see loop's mechanics: channels, topologies, framed-TCP-push
  protocol, reload recipe, remote debugging procedures.
- [Events](events.md) — the layer below: the injection primitive, the `message`/`timer` events, the
  opt-in transport, the pump-as-reactor.
- [Scripting & clients](scripting.md) — the umbilical as a dev strategy; the native thin client;
  the static/dynamic linkage split.
- [Web / WASM](web.md) — the browser thin client + WebSocket mover (§5) and the REPL channel with
  human-and-AI operability (§7).
- [Canvas](canvas.md) — the offscreen/render-target backing that pixel readback (§6) reads from.
