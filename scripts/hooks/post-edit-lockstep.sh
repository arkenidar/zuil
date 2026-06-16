#!/bin/sh
# post-edit-lockstep.sh — Claude Code PostToolUse hook (Edit|Write).
#
# Fires the lockstep invariant check the moment an ABI-defining file changes —
# include/zuil.h or either impl (src/zuil.c, src/zuil.zig) — so a divergence is
# surfaced to Claude in the same turn it was introduced, not at commit time.
# For unrelated edits it is a no-op (exit 0), so it stays cheap on the hot loop.
#
# Reads the hook's JSON event on stdin; we only need the edited path, matched by
# substring (no jq dependency). On lockstep failure we exit 2 so the harness
# feeds the report back to Claude as actionable feedback.
set -eu

cd "$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"   # project root

event=$(cat)
case "$event" in
  *src/zuil.c*|*src/zuil.zig*|*include/zuil.h*) ;;   # ABI surface touched → check
  *) exit 0 ;;                                        # anything else → no-op
esac

if out=$(scripts/lockstep_check.sh 2>&1); then
  echo "$out" | tail -n1
  exit 0
else
  echo "ABI edit broke C/Zig/header lockstep — fix before continuing:" >&2
  echo "$out" >&2
  exit 2
fi
