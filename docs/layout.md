# Layout

*Part of the ZUIL design record — see [architecture.md](architecture.md).*

**Stance (consistent with mechanism-not-policy): layout is user-space policy.** The C ABI / Zig
core ships **no layout engine**. It provides only what layout genuinely *needs*:

- **text measurement** (size labels/buttons to content),
- the **current region size** (divide space),
- the **clip + 2-D transform stack** (nested coordinate spaces, scrolling),
- **DPI scale**.

Given those, any scheme below is a small user-space module.

## Schemes

| Scheme | What | Fits |
|---|---|---|
| **Absolute** (x,y,w,h) | explicit coords, Win32/ZetCode style | both; always available; needed for canvas interiors & ports |
| **Flow / cursor** (default) | cursor auto-advances; vertical stack + `row{}`; specs = px `>1`, fraction `0..1`, fill `<=0`; `same_line`/`spacing`/`indent` | **immediate** — recomputed each frame (the predecessor's proven scheme) |
| **Box / flex** | containers with direction + grow weights + align/justify | both (immediate: nested begin_row/col scopes; retained: container widgets) — the "level 2" for forms |
| **Grid** | rows × cols, spans | user-space helper for tables/forms |
| **Dock / anchor** | dock top/left/fill; anchor edges so children track on resize | mainly **retained** (persistent widgets reflowing on `on_resize`) |
| **Constraint (Cassowary)** | solver-based auto-layout | out of scope; addable in user-space if ever needed |

## The cost-model flip (immediate vs retained)

- **Immediate**: layout is *recomputed every frame from the current size*, so
  **responsive-on-resize is automatic and free** — read the size and divide. Flow/cursor +
  nested begin/end scopes are the idiom. No tree, no invalidation. (This is why dock/anchor
  barely matter in immediate mode — reflow is free.)
- **Retained**: layout is a *tree recomputed on resize / structure change* — box/grid/dock/anchor
  containers compute child rects. More machinery, but runs only when things change.

Same schemes; the cost model is what flips.

## Recommendation

- **Default bundled (immediate, user-space):** flow/cursor with `row{ px | fraction | fill }` +
  `same_line` / `spacing` / `indent`.
- **Ship a small box/flex helper** for non-trivial forms.
- **Absolute always available** (canvas interiors, ports).
- **Dock/anchor** as a retained-path helper; **grid / constraint** as opt-in add-ons, not bundled.
- Scale px specs by **DPI** so layouts hold across monitors and on mobile.
