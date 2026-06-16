---
description: Run the full ZUIL gate — build both impls, lockstep diff, all smokes, gcc hedge
allowed-tools: Bash(./scripts/verify.sh*), Bash(scripts/verify.sh*)
---

Run the canonical verification gate and report the result:

```
./scripts/verify.sh
```

This is the single source of truth for "is the tree good": it builds the C and
Zig impls, runs `scripts/lockstep_check.sh` (header ↔ C ↔ Zig export diff), the
LuaJIT FFI smoke, the Python ctypes smoke, the headless M1 grab-move smoke, and
finally the no-Zig gcc-hedge rebuild. Non-zero exit = the tree is not shippable.

Pass `--quick` to skip the gcc-hedge re-verify on the hot loop, or
`--impl=zig` to run the smokes against the Zig implementation.
