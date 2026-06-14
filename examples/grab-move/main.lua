-- grab-move, on zuil — a clean, adapted (rect-only) rewrite of the LÖVE2D GUI
-- at lua-love2d/grab-move. Same ideas, expressed over zuil's primitives:
--   * widgets are user-space tables (zuil owns no Button) — mechanism, not policy
--   * input is the per-frame snapshot (zuil.pressed gives the edge natively, so
--     the original's hand-rolled click_down counter disappears)
--   * back-to-front draw / front-to-back action with stop-propagation + bring-to-front
--   * clip + translate drive the draggable, scissored panel
-- Run from the project root:  luajit examples/grab-move/main.lua
package.path = "examples/grab-move/?.lua;" .. package.path
local zuil = require("zuil")

zuil.open("grab-move on zuil", 700, 500)

-- helpers --------------------------------------------------------------------
local function inside(px, py, r)
  return px >= r.x and px <= r.x + r.w and py >= r.y and py <= r.y + r.h
end
local function bring_to_front(list, item)
  for i, v in ipairs(list) do
    if v == item then table.remove(list, i) break end
  end
  list[#list + 1] = item
end

-- Shared per-frame input claim. The topmost widget under the cursor (input is
-- processed front-to-back, the reverse of the draw order) eats the press so it
-- can't pass through to anything drawn beneath it. Reset at the top of each
-- frame. This is the cross-group stop-propagation the original lacked; the
-- handles loop's own early-out still resolves which handle wins within the group.
local claimed = false

-- draggable handles ----------------------------------------------------------
local handles = {
  { x = 60,  y = 90,  w = 300, h = 60, r = 0.20, g = 0.45, b = 0.95 },
  { x = 120, y = 170, w = 300, h = 60, r = 0.20, g = 0.70, b = 0.55 },
  { x = 180, y = 250, w = 300, h = 60, r = 0.80, g = 0.40, b = 0.30 },
}
local DEL = 24 -- delete-button side

local function handle_delete_rect(h)
  return { x = h.x + h.w - DEL, y = h.y, w = DEL, h = DEL }
end

-- one front-to-back interaction pass; returns nothing, mutates handles
local function update_handles()
  local mx, my = zuil.mouse()
  if not claimed and zuil.pressed(1) then
    for i = #handles, 1, -1 do
      local h = handles[i]
      -- delete button (top-right) takes priority
      if inside(mx, my, handle_delete_rect(h)) then
        table.remove(handles, i)
        claimed = true
        break
      end
      -- grab to drag
      if inside(mx, my, h) then
        h.grab = { dx = mx - h.x, dy = my - h.y }
        bring_to_front(handles, h)
        claimed = true
        break -- grab only the topmost hit; stop propagation
      end
    end
  end
  -- apply active drag / release (ungated: an established grab keeps tracking)
  for _, h in ipairs(handles) do
    if h.grab then
      if zuil.down(1) then
        h.x = mx - h.grab.dx
        h.y = my - h.grab.dy
      else
        h.grab = nil
      end
    end
  end
end

local function draw_handles()
  for _, h in ipairs(handles) do -- back-to-front
    zuil.color(1, 1, 1); zuil.fill(h.x, h.y, h.w, h.h) -- white border
    local b = 4
    if h.grab then zuil.color(1, 0.3, 0.3) else zuil.color(h.r, h.g, h.b) end
    zuil.fill(h.x + b, h.y + b, h.w - 2 * b, h.h - 2 * b)
    -- delete button with an X
    local d = handle_delete_rect(h)
    zuil.color(0.85, 0.85, 0.85); zuil.fill(d.x, d.y, d.w, d.h)
    zuil.color(0.2, 0.2, 0.2)
    zuil.line(d.x + 6, d.y + 6, d.x + d.w - 6, d.y + d.h - 6)
    zuil.line(d.x + d.w - 6, d.y + 6, d.x + 6, d.y + d.h - 6)
  end
end

-- exclusive tabs (mutex) -----------------------------------------------------
local tabs = { { label = 1, x = 60, y = 30, w = 120, h = 40 },
               { label = 2, x = 190, y = 30, w = 120, h = 40 } }
local active_tab = tabs[1]

local function update_tabs()
  local mx, my = zuil.mouse()
  if not claimed and zuil.pressed(1) then
    for _, t in ipairs(tabs) do
      if inside(mx, my, t) then active_tab = t; claimed = true end
    end
  end
end
local function draw_tabs()
  for _, t in ipairs(tabs) do
    if t == active_tab then zuil.color(0.9, 0.2, 0.2) else zuil.color(0.45, 0.45, 0.45) end
    zuil.fill(t.x, t.y, t.w, t.h)
    zuil.color(1, 1, 1); zuil.rect(t.x, t.y, t.w, t.h)
  end
end

-- a clipped, draggable panel (shows clip + translate) ------------------------
local panel = { x = 380, y = 110, w = 260, h = 320, ox = 0, oy = 0 }

local function update_panel()
  local mx, my = zuil.mouse()
  -- the whole panel surface is opaque to clicks (blocks pass-through); only the
  -- header initiates a drag.
  if not claimed and zuil.pressed(1) and inside(mx, my, panel) then
    claimed = true
    local header = { x = panel.x, y = panel.y, w = panel.w, h = 28 }
    if inside(mx, my, header) then
      panel.drag = { dx = mx - panel.x, dy = my - panel.y }
    end
  end
  if panel.drag then
    if zuil.down(1) then
      panel.x = mx - panel.drag.dx
      panel.y = my - panel.drag.dy
    else
      panel.drag = nil
    end
  end
end

local function draw_panel()
  -- frame + header
  zuil.color(0.15, 0.15, 0.18); zuil.fill(panel.x, panel.y, panel.w, panel.h)
  zuil.color(0.30, 0.30, 0.36); zuil.fill(panel.x, panel.y, panel.w, 28)
  zuil.color(1, 1, 1); zuil.rect(panel.x, panel.y, panel.w, panel.h)

  -- clipped body: content is translated and deliberately overflows the rect,
  -- so the clip is visible. The body differs per active tab.
  local body = { x = panel.x + 8, y = panel.y + 36, w = panel.w - 16, h = panel.h - 44 }
  zuil.clip(body.x, body.y, body.w, body.h)
  zuil.push()
  zuil.translate(body.x, body.y)
  if active_tab.label == 1 then
    for i = 0, 20 do
      zuil.color(0.2 + 0.03 * i, 0.5, 1.0 - 0.03 * i)
      zuil.fill(-20 + i * 16, i * 14, 220, 12) -- overflows left/right/bottom -> clipped
    end
  else
    for i = 0, 14 do
      zuil.color(0.9, 0.4 + 0.03 * i, 0.2)
      zuil.line(0, i * 22, 320, i * 22 + 40) -- overflows right -> clipped
    end
  end
  zuil.pop()
  zuil.unclip()
end

-- frame ----------------------------------------------------------------------
zuil.run(function()
  -- input: front-to-back (the reverse of the draw order below) so the topmost
  -- widget under the cursor claims the press and it can't pass through. The
  -- panel is drawn last, so it's on top, so it sees input first.
  claimed = false
  update_panel()
  update_handles()
  update_tabs()

  -- draw: background, then back-to-front
  zuil.color(0.08, 0.08, 0.10); zuil.clear()
  draw_tabs()
  draw_handles()
  draw_panel()
end, tonumber(arg and arg[1])) -- optional frame cap for headless smoke
