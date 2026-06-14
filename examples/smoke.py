#!/usr/bin/env python3
"""ZUIL Step 0 smoke test, via Python ctypes -- mirrors examples/smoke.lua.

Loads libzuil.so and calls the one C-ABI export, proving the same
build/link/FFI boundary works from CPython too.

Run from anywhere:  python3 examples/smoke.py
"""
import ctypes
import os

here = os.path.dirname(os.path.abspath(__file__))
root = os.path.join(here, os.pardir)

# Resolve libzuil across build flows: the gcc hedge and Linux `zig build` emit
# zig-out/lib/libzuil.so; Windows `zig build` emits a self-contained
# zig-out/bin/zuil.dll; macOS would be a .dylib. Try each so any build runs.
candidates = [
    os.path.join(root, "zig-out", "lib", "libzuil.so"),
    os.path.join(root, "zig-out", "bin", "zuil.dll"),
    os.path.join(root, "zig-out", "lib", "libzuil.dylib"),
]
lib_path = next((p for p in candidates if os.path.exists(p)), None)
if lib_path is None:
    raise SystemExit(
        "zuil: no library found — build it first (`zig build`, or the gcc hedge).\n"
        "Tried:\n  " + "\n  ".join(os.path.normpath(p) for p in candidates)
    )

zuil = ctypes.CDLL(lib_path)
zuil.zuil_sdl_version.restype = ctypes.c_int
zuil.zuil_sdl_version.argtypes = []

v = zuil.zuil_sdl_version()
print("ZUIL ok - linked SDL3 version = {}  ({}.{}.{})".format(
    v, v // 1000000, v // 1000 % 1000, v % 1000
))
