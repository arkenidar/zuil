-- Frame-capped smoke: open a real window, draw a static rect, pump N frames,
-- close. Proves window + pump + draw + input accessors end-to-end without
-- hanging. Run from project root:  luajit examples/grab-move/_smoke.lua [frames]
package.path = "examples/grab-move/?.lua;" .. package.path
local zuil = require("zuil")

zuil.open("zuil grab-move smoke", 600, 400)
zuil.run(function()
  zuil.color(0.1, 0.1, 0.12); zuil.clear()
  zuil.color(0.31, 0.63, 1.0); zuil.fill(50, 50, 200, 120) -- static colored rect
  zuil.color(1, 1, 1); zuil.rect(50, 50, 200, 120)
end, tonumber(arg and arg[1]) or 30)

print(string.format("smoke ok: last mouse=(%d,%d)", zuil.mouse_x(), zuil.mouse_y()))
