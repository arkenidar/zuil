-- ZUIL Step 0 smoke test: load libzuil.so via LuaJIT FFI and call the one export.
-- Run from the project root:  luajit examples/smoke.lua
local ffi = require("ffi")

ffi.cdef([[ int zuil_sdl_version(void); ]])

local zuil = ffi.load("./zig-out/lib/libzuil.so")
local v = zuil.zuil_sdl_version()

print(string.format(
  "ZUIL ok - linked SDL3 version = %d  (%d.%d.%d)",
  v,
  math.floor(v / 1000000),
  math.floor(v / 1000) % 1000,
  v % 1000
))
