-- ZUIL Step 0 smoke test: load libzuil.so via LuaJIT FFI and call the one export.
-- Run from the project root:  luajit examples/smoke.lua
local ffi = require("ffi")

ffi.cdef([[ int zuil_sdl_version(void); ]])

-- Resolve libzuil across build flows: the gcc hedge and Linux `zig build` emit
-- zig-out/lib/libzuil.so; Windows `zig build` emits a self-contained
-- zig-out/bin/zuil.dll. Try each so either build runs the smoke (cwd = root).
local candidates = {
  "./zig-out/lib/libzuil.so",
  "./zig-out/bin/zuil.dll",
  "./zig-out/lib/libzuil.dylib",
}
local zuil
for _, path in ipairs(candidates) do
  local ok, lib = pcall(ffi.load, path)
  if ok then zuil = lib; break end
end
if not zuil then
  error("zuil: no library found — build it first (zig build, or the gcc hedge). Tried: "
        .. table.concat(candidates, ", "))
end
local v = zuil.zuil_sdl_version()

print(string.format(
  "ZUIL ok - linked SDL3 version = %d  (%d.%d.%d)",
  v,
  math.floor(v / 1000000),
  math.floor(v / 1000) % 1000,
  v % 1000
))
