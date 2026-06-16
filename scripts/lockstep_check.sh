#!/bin/sh
# lockstep_check.sh — mechanize the #1 ZUIL invariant.
#
# CLAUDE.md / docs/architecture.md: include/zuil.h is the single source of
# truth, and "never let one impl grow a symbol the other lacks." This script
# turns that prose into a hard gate by diffing three sets of zuil_* symbols:
#
#   HEADER : declared in include/zuil.h
#   C      : exported by libzuil.so built with -Dimpl=c   (the default/hedge)
#   ZIG    : exported by libzuil.so built with -Dimpl=zig (the twin)
#
# Any symbol that is in the header but missing from an impl, or present in one
# impl but not the other, is a lockstep break → exit 1 with a named report.
#
# Self-contained: builds BOTH impls into temp copies (so it can nm them
# side-by-side — zig-out only ever holds one impl at a time) and restores the
# default C build at the end so callers' smokes find the expected artifact.
# Standalone by design: the PostToolUse hook and `/lockstep` call it directly.
set -eu

cd "$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"   # project root

SO="zig-out/lib/libzuil.so"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# zuil_* exports defined (text/code symbols) in a built .so.
so_exports() {
  nm -D --defined-only "$1" | awk '{print $3}' | grep -E '^zuil_[a-z0-9_]+$' | sort -u
}

echo "lockstep: building both impls…"
zig build -Dimpl=c   >/dev/null;  cp "$SO" "$TMP/c.so"
zig build -Dimpl=zig >/dev/null;  cp "$SO" "$TMP/zig.so"
zig build            >/dev/null   # restore default C build for downstream smokes

grep -ohE 'zuil_[a-z0-9_]+' include/zuil.h | sort -u > "$TMP/header"
so_exports "$TMP/c.so"   > "$TMP/c"
so_exports "$TMP/zig.so" > "$TMP/zig"

fail=0
report() { # report <label> <missing-file>; sets fail if non-empty
  if [ -s "$2" ]; then
    fail=1
    echo "  ✗ $1:"
    sed 's/^/      /' "$2"
  fi
}

# Header symbols absent from each impl (the "designed-not-built" trap).
comm -23 "$TMP/header" "$TMP/c"   > "$TMP/miss_c";   report "in header, missing from C impl"   "$TMP/miss_c"
comm -23 "$TMP/header" "$TMP/zig" > "$TMP/miss_zig"; report "in header, missing from Zig impl" "$TMP/miss_zig"
# Symbols where the two impls disagree (one grew an export the other lacks).
comm -23 "$TMP/c" "$TMP/zig" > "$TMP/c_only";   report "exported by C impl only"   "$TMP/c_only"
comm -13 "$TMP/c" "$TMP/zig" > "$TMP/zig_only"; report "exported by Zig impl only" "$TMP/zig_only"

if [ "$fail" -ne 0 ]; then
  echo "lockstep: FAIL — C/Zig/header are out of sync (see above)"
  exit 1
fi

n=$(wc -l < "$TMP/header" | tr -d ' ')
echo "lockstep: OK — $n zuil_* symbols match across header, C impl, and Zig impl"
