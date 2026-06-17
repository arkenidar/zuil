-- Spike E — the event struct across the FFI boundary (LuaJIT face).
--
-- Round-trips synthetic events with NO SDL in the path: emit -> poll -> verify
-- fields read BOTH ways (the raw cdata struct, and the per-field accessor
-- calls). Also checks the layout self-check, fail-fast on a full bounded queue,
-- FIFO order, and the borrow-until-next-poll message payload. Finally it
-- micro-benchmarks raw cdata reads vs accessor calls — the measurement that
-- exits Spike E with a decision (docs/m1.md §3).
--
-- Run from the project root:  luajit examples/event_smoke.lua
local ffi = require("ffi")

-- This cdef IS the FFI face's copy of include/zuil.h's ZuilEvent — the layout
-- self-check below proves it matches the built binary (the cross-pointer-width
-- concern Spike E exists to burn down).
ffi.cdef([[
typedef struct ZuilEvent {
  int type;
  int a, b, c;
  const unsigned char *payload;
} ZuilEvent;
int zuil_test_emit(int type, int a, int b, int c, const unsigned char *payload, int payload_len);
int zuil_event_poll(ZuilEvent *out);
int zuil_event_type(void);
int zuil_event_a(void);
int zuil_event_b(void);
int zuil_event_c(void);
const unsigned char *zuil_event_payload(void);
int zuil_event_payload_len(void);
int zuil_event_struct_size(void);
int zuil_event_struct_align(void);
]])

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

local ZUIL_EV_MOUSE, ZUIL_EV_MESSAGE, ZUIL_EV_TIMER = 1, 3, 4
local fail = 0
local function check(cond, msg)
  if not cond then fail = fail + 1; print("  FAIL: " .. msg) end
end

-- 1. Layout self-check: the cdata struct the FFI built must match the binary.
check(ffi.sizeof("ZuilEvent") == zuil.zuil_event_struct_size(),
      string.format("sizeof mismatch: ffi=%d binary=%d",
                    tonumber(ffi.sizeof("ZuilEvent")), zuil.zuil_event_struct_size()))
check(ffi.alignof("ZuilEvent") == zuil.zuil_event_struct_align(),
      string.format("alignof mismatch: ffi=%d binary=%d",
                    tonumber(ffi.alignof("ZuilEvent")), zuil.zuil_event_struct_align()))

-- 2. A mouse event, read as a RAW struct (zero extra calls after the poll).
assert(zuil.zuil_test_emit(ZUIL_EV_MOUSE, 320, 240, 1, nil, 0) == 0)
local ev = ffi.new("ZuilEvent")
check(zuil.zuil_event_poll(ev) == 1, "poll mouse")
check(ev.type == ZUIL_EV_MOUSE and ev.a == 320 and ev.b == 240 and ev.c == 1, "mouse fields (raw)")
check(ev.payload == nil, "mouse payload NULL")

-- 3. The same drain, this time read via ACCESSORS (poll with no out struct).
assert(zuil.zuil_test_emit(ZUIL_EV_TIMER, 7, 0, 0, nil, 0) == 0)
check(zuil.zuil_event_poll(nil) == 1, "poll timer (latch only)")
check(zuil.zuil_event_type() == ZUIL_EV_TIMER and zuil.zuil_event_a() == 7, "timer fields (accessor)")

-- 4. A message payload: borrow-until-next-poll, verified through both faces.
local msg = "return zuil.sdl_version()"
assert(zuil.zuil_test_emit(ZUIL_EV_MESSAGE, 42, #msg, 0, msg, #msg) == 0)
check(zuil.zuil_event_poll(ev) == 1, "poll message")
check(ev.type == ZUIL_EV_MESSAGE and ev.a == 42 and ev.b == #msg, "message fields")
check(ev.payload ~= nil and ffi.string(ev.payload, ev.b) == msg, "message payload bytes (raw)")
check(ffi.string(zuil.zuil_event_payload(), zuil.zuil_event_payload_len()) == msg,
      "message payload bytes (accessor)")

-- 5. Empty queue drains to 0.
check(zuil.zuil_event_poll(ev) == 0, "empty poll returns 0")

-- 6. Bounded queue fails fast (cap 64), then drains in FIFO order.
local emitted = 0
while zuil.zuil_test_emit(ZUIL_EV_TIMER, emitted, 0, 0, nil, 0) == 0 do
  emitted = emitted + 1
  if emitted > 10000 then break end
end
check(emitted == 64, string.format("queue cap fail-fast at 64 (got %d)", emitted))
check(zuil.zuil_test_emit(ZUIL_EV_TIMER, 0, 0, 0, nil, 0) < 0, "post on full returns <0")
for i = 0, emitted - 1 do
  zuil.zuil_event_poll(ev)
  check(ev.a == i, "FIFO order")
end

-- 7. The measurement: raw cdata field reads vs accessor calls, same latched event.
local N = 2000000
zuil.zuil_test_emit(ZUIL_EV_MOUSE, 1, 2, 3, nil, 0)
zuil.zuil_event_poll(ev) -- latch one event; re-read it N times each way
local t0 = os.clock()
local s1 = 0
for _ = 1, N do s1 = s1 + ev.a + ev.b + ev.c end
local t_raw = os.clock() - t0
t0 = os.clock()
local s2 = 0
for _ = 1, N do s2 = s2 + zuil.zuil_event_a() + zuil.zuil_event_b() + zuil.zuil_event_c() end
local t_acc = os.clock() - t0
check(s1 == s2, "raw and accessor sums agree")

print(string.format("Spike E: ZuilEvent = %d bytes / align %d  (ffi %d/%d)",
      zuil.zuil_event_struct_size(), zuil.zuil_event_struct_align(),
      tonumber(ffi.sizeof("ZuilEvent")), tonumber(ffi.alignof("ZuilEvent"))))
print(string.format("Spike E: %d x 3-field read  raw=%.3fs  accessor=%.3fs  (accessor %.1fx)",
      N, t_raw, t_acc, t_raw > 0 and t_acc / t_raw or 0))

if fail == 0 then
  print("event smoke ok")
else
  error(fail .. " check(s) failed")
end
