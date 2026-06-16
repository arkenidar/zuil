#!/bin/sh
# install-hooks.sh — opt into the version-controlled git hooks.
#
# Points git at scripts/hooks/ (which holds the tracked pre-commit gate) instead
# of the untracked, per-clone .git/hooks/. One command, idempotent. Run once per
# clone:  ./scripts/install-hooks.sh
set -eu

cd "$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"   # project root
git config core.hooksPath scripts/hooks
echo "installed: core.hooksPath -> scripts/hooks (pre-commit gate active)"
echo "bypass a single commit with: git commit --no-verify"
