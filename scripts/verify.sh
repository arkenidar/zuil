#!/bin/sh
# verify.sh — the one canonical "is the tree good?" gate for ZUIL.
#
# Single source of truth: every other layer (the `/verify` slash command, the
# git pre-commit hook, CI, `zig build verify`, `make verify`) is a thin caller
# of THIS script — no duplicated command lists anywhere. Exit non-zero on any
# failure so all of those can hard-gate on it.
#
# What it proves, in order:
#   1. Lockstep — C impl, Zig impl, and include/zuil.h export the same surface
#      (scripts/lockstep_check.sh; also builds both impls).
#   2. FFI smoke (LuaJIT)      — libzuil.so loads + links SDL3 (expects 3.2.10).
#   3. ctypes smoke (Python)   — same contract from a second consumer.
#   4. M1 headless smoke       — window + pump + draw + input, frame-capped.
#   5. Spike E event ABI       — synthetic event round-trips (no SDL): raw-struct
#      vs accessor faces + the layout self-check, on LuaJIT and ctypes both.
#   6. Hedge — rebuild the .so with plain gcc (no Zig) and re-run the FFI smoke,
#      proving the toolchain hedge still stands. (skipped by --quick)
#
# Flags:
#   --quick        skip step 6 (the gcc-hedge re-verify) — for the hot loop / hook
#   --impl=c|zig   run the smokes against this impl (default c). Lockstep always
#                  checks BOTH regardless; this only picks which lib the smokes load.
set -eu

cd "$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"   # project root

QUICK=0
IMPL=c
for arg in "$@"; do
  case "$arg" in
    --quick)   QUICK=1 ;;
    --impl=c)  IMPL=c ;;
    --impl=zig) IMPL=zig ;;
    *) echo "verify: unknown arg '$arg' (use --quick, --impl=c|zig)" >&2; exit 2 ;;
  esac
done

# SDL needs no real display for the frame-capped window smoke; offscreen keeps
# step 4 runnable on headless CI and never hurts on a desktop with a display.
export SDL_VIDEODRIVER="${SDL_VIDEODRIVER:-offscreen}"

step() { echo; echo "=== $* ==="; }

# Run a command, capture output, fail loudly unless it contains an expected marker.
expect() { # expect <marker> <cmd...>
  marker=$1; shift
  out=$("$@" 2>&1) || { echo "$out"; echo "verify: FAIL — '$*' exited non-zero"; exit 1; }
  echo "$out"
  echo "$out" | grep -qF "$marker" || { echo "verify: FAIL — expected '$marker' in output of '$*'"; exit 1; }
}

step "1/6 lockstep (builds C + Zig impls, diffs against header)"
scripts/lockstep_check.sh

# Lockstep restores the default C build; if smokes want the Zig impl, build it now.
if [ "$IMPL" = zig ]; then
  step "build Zig impl for smokes (-Dimpl=zig)"
  zig build -Dimpl=zig
else
  zig build   # cheap (cached); guarantees zig-out holds the C impl libs
fi
[ -f zig-out/lib/libzuil.so ] || { echo "verify: FAIL — zig-out/lib/libzuil.so missing"; exit 1; }
[ -f zig-out/lib/libzuil.a  ] || { echo "verify: FAIL — zig-out/lib/libzuil.a missing";  exit 1; }

step "2/6 FFI smoke (LuaJIT) — expect linked SDL3 3.2.10"
expect "ZUIL ok" luajit examples/smoke.lua

step "3/6 ctypes smoke (Python)"
expect "ZUIL ok" python3 examples/smoke.py

step "4/6 M1 headless smoke (window + pump + draw, 30 frames)"
expect "smoke ok" luajit examples/grab-move/_smoke.lua 30

step "5/6 Spike E event ABI smoke (synthetic events, no SDL) — LuaJIT + ctypes"
expect "event smoke ok" luajit examples/event_smoke.lua
expect "event smoke ok" python3 examples/event_smoke.py

if [ "$QUICK" -eq 1 ]; then
  echo; echo "verify: OK (--quick; skipped the gcc-hedge re-verify) — impl=$IMPL"
  exit 0
fi

step "6/6 toolchain hedge — rebuild .so with plain gcc (no Zig), re-run FFI smoke"
mkdir -p zig-out/lib
gcc -shared -Iinclude -o zig-out/lib/libzuil.so src/zuil.c $(pkg-config --cflags --libs sdl3)
expect "ZUIL ok" luajit examples/smoke.lua
zig build >/dev/null   # leave zig-out holding the Zig-built default again

echo; echo "verify: OK — lockstep + 4 smokes (incl. Spike E) + gcc hedge all green (impl=$IMPL)"
