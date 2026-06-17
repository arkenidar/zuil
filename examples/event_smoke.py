#!/usr/bin/env python3
"""Spike E -- the event struct across the FFI boundary (Python / ctypes face).

Mirrors examples/event_smoke.lua so the raw-struct-vs-accessor event ABI is
exercised from a SECOND FFI face (the confirmation Spike E's accessor outcome
was owed). Round-trips synthetic events with NO SDL in the path, reads fields
both as a raw Structure and via accessor calls, and checks the layout
self-check, fail-fast on a full bounded queue, FIFO order, and the
borrow-until-next-poll message payload.

Run from anywhere:  python3 examples/event_smoke.py
"""
import ctypes
import os


# This Structure IS the ctypes face's copy of include/zuil.h's ZuilEvent; the
# layout self-check proves it matches the built binary (the pointer is the only
# width-varying field -- the cross-pointer-width concern Spike E burns down).
class ZuilEvent(ctypes.Structure):
    _fields_ = [
        ("type", ctypes.c_int),
        ("a", ctypes.c_int),
        ("b", ctypes.c_int),
        ("c", ctypes.c_int),
        ("payload", ctypes.POINTER(ctypes.c_ubyte)),
    ]


here = os.path.dirname(os.path.abspath(__file__))
root = os.path.join(here, os.pardir)
candidates = [
    os.path.join(root, "zig-out", "lib", "libzuil.so"),
    os.path.join(root, "zig-out", "bin", "zuil.dll"),
    os.path.join(root, "zig-out", "lib", "libzuil.dylib"),
]
lib_path = next((p for p in candidates if os.path.exists(p)), None)
if lib_path is None:
    raise SystemExit(
        "zuil: no library found — build it first (`zig build`, or the gcc hedge)."
    )

z = ctypes.CDLL(lib_path)
z.zuil_test_emit.argtypes = [ctypes.c_int] * 4 + [ctypes.POINTER(ctypes.c_ubyte), ctypes.c_int]
z.zuil_test_emit.restype = ctypes.c_int
z.zuil_event_poll.argtypes = [ctypes.POINTER(ZuilEvent)]
z.zuil_event_poll.restype = ctypes.c_int
for fn in ("zuil_event_type", "zuil_event_a", "zuil_event_b", "zuil_event_c",
           "zuil_event_payload_len", "zuil_event_struct_size", "zuil_event_struct_align"):
    getattr(z, fn).argtypes = []
    getattr(z, fn).restype = ctypes.c_int
z.zuil_event_payload.argtypes = []
z.zuil_event_payload.restype = ctypes.POINTER(ctypes.c_ubyte)

ZUIL_EV_MOUSE, ZUIL_EV_MESSAGE, ZUIL_EV_TIMER = 1, 3, 4
fail = 0


def check(cond, msg):
    global fail
    if not cond:
        fail += 1
        print("  FAIL:", msg)


def as_buf(data):
    """bytes -> (POINTER(c_ubyte), keepalive). emit copies, so keepalive only
    needs to outlive the call."""
    arr = (ctypes.c_ubyte * len(data)).from_buffer_copy(data)
    return ctypes.cast(arr, ctypes.POINTER(ctypes.c_ubyte)), arr


# 1. Layout self-check.
check(ctypes.sizeof(ZuilEvent) == z.zuil_event_struct_size(),
      "sizeof mismatch: ctypes=%d binary=%d" % (ctypes.sizeof(ZuilEvent), z.zuil_event_struct_size()))
check(ctypes.alignment(ZuilEvent) == z.zuil_event_struct_align(),
      "alignof mismatch: ctypes=%d binary=%d" % (ctypes.alignment(ZuilEvent), z.zuil_event_struct_align()))

# 2. Mouse event, read as a RAW struct.
assert z.zuil_test_emit(ZUIL_EV_MOUSE, 320, 240, 1, None, 0) == 0
ev = ZuilEvent()
check(z.zuil_event_poll(ctypes.byref(ev)) == 1, "poll mouse")
check(ev.type == ZUIL_EV_MOUSE and ev.a == 320 and ev.b == 240 and ev.c == 1, "mouse fields (raw)")
check(not ev.payload, "mouse payload NULL")

# 3. Same drain, read via ACCESSORS.
assert z.zuil_test_emit(ZUIL_EV_TIMER, 7, 0, 0, None, 0) == 0
check(z.zuil_event_poll(None) == 1, "poll timer (latch only)")
check(z.zuil_event_type() == ZUIL_EV_TIMER and z.zuil_event_a() == 7, "timer fields (accessor)")

# 4. Message payload, verified through both faces.
msg = b"return zuil.sdl_version()"
ptr, _keep = as_buf(msg)
assert z.zuil_test_emit(ZUIL_EV_MESSAGE, 42, len(msg), 0, ptr, len(msg)) == 0
check(z.zuil_event_poll(ctypes.byref(ev)) == 1, "poll message")
check(ev.type == ZUIL_EV_MESSAGE and ev.a == 42 and ev.b == len(msg), "message fields")
got_raw = bytes(ev.payload[i] for i in range(ev.b))
check(got_raw == msg, "message payload bytes (raw)")
n = z.zuil_event_payload_len()
pp = z.zuil_event_payload()
got_acc = bytes(pp[i] for i in range(n))
check(got_acc == msg, "message payload bytes (accessor)")

# 5. Empty queue.
check(z.zuil_event_poll(ctypes.byref(ev)) == 0, "empty poll returns 0")

# 6. Bounded fail-fast (cap 64) + FIFO drain.
emitted = 0
while z.zuil_test_emit(ZUIL_EV_TIMER, emitted, 0, 0, None, 0) == 0:
    emitted += 1
    if emitted > 10000:
        break
check(emitted == 64, "queue cap fail-fast at 64 (got %d)" % emitted)
check(z.zuil_test_emit(ZUIL_EV_TIMER, 0, 0, 0, None, 0) < 0, "post on full returns <0")
for i in range(emitted):
    z.zuil_event_poll(ctypes.byref(ev))
    check(ev.a == i, "FIFO order")

print("Spike E: ZuilEvent = %d bytes / align %d  (ctypes %d/%d)" % (
    z.zuil_event_struct_size(), z.zuil_event_struct_align(),
    ctypes.sizeof(ZuilEvent), ctypes.alignment(ZuilEvent)))

if fail == 0:
    print("event smoke ok")
else:
    raise SystemExit("%d check(s) failed" % fail)
