#!/usr/bin/env python3
"""ZUIL Step 0 smoke test, via Python ctypes -- mirrors examples/smoke.lua.

Loads libzuil.so and calls the one C-ABI export, proving the same
build/link/FFI boundary works from CPython too.

Run from anywhere:  python3 examples/smoke.py
"""
import ctypes
import os

here = os.path.dirname(os.path.abspath(__file__))
lib_path = os.path.join(here, os.pardir, "zig-out", "lib", "libzuil.so")

zuil = ctypes.CDLL(lib_path)
zuil.zuil_sdl_version.restype = ctypes.c_int
zuil.zuil_sdl_version.argtypes = []

v = zuil.zuil_sdl_version()
print("ZUIL ok - linked SDL3 version = {}  ({}.{}.{})".format(
    v, v // 1000000, v // 1000 % 1000, v % 1000
))
