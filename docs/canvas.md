# Canvas

*Part of the ZUIL design record — see [architecture.md](architecture.md).*

A **canvas** is a rectangular region you paint freely and that receives input localized to it —
the **owner-draw escape hatch**: custom visualizations, charts, the raytracer/pixel buffers, a
game viewport, the text-editor render area, anything the bundled widgets don't cover. It is the
pressure-release valve that lets the widget set stay small without limiting you.

## It *is* the mechanism

The draw vocabulary + clip + `blit_rgba` + the input snapshot already are a canvas. A canvas
widget is just: reserve a rect → push a clip to it → hand you a `dc` and pointer coords in
*local* space → you draw.

```lua
-- immediate flavour
ui.canvas(id, w, h, function(dc, input)   -- input.x/y are canvas-local
  dc:line(0, 0, input.x, input.y)
end)

-- retained flavour
--   Canvas{ rect, on_draw = fn(dc), on_mouse = fn(local_ev) }
```

## The one design choice that matters: backing strategy

| | Direct paint (default) | Render-to-texture (optional) |
|---|---|---|
| How | draws into the window each frame, clipped | owns an offscreen `SDL_Texture`; redraw only on change; blit the cache |
| Good for | dynamic content — games, animation, raytracer (fits immediate mode) | expensive/static content; cheap **scroll / zoom / pan** (transform the texture) |
| Mechanism need | clip only | `SDL_CreateTexture(TARGET)` + `SDL_SetRenderTarget` |

`blit_rgba` separately covers the "I computed a pixel buffer in Lua/C" case (e.g. a raytracer).

## What canvas asks of the native mechanism

- **Clip + a 2-D transform stack** (translate/scale) → local coordinate spaces, and the basis
  for **scroll/zoom** and DPI.
- **Optional offscreen render-target** → cache expensive/static content. (Must be **recreatable**
  on GPU-context loss — see [mobile.md](mobile.md).)
- **Input capture** — a drag begun in the canvas keeps getting move/up even if the cursor
  leaves — which is just the `hot`/`active` id-registry doing its job.

Everything else — *what* you draw — is user-space.

## Falls-out unification

**Scrolling = clip + translate transform.** A scroll container is just a canvas with an offset,
so scroll/zoom reuse the canvas primitive rather than being special-cased.
