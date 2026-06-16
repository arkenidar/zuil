---
description: Check the C↔Zig↔header lockstep invariant (fast ABI surface diff)
allowed-tools: Bash(./scripts/lockstep_check.sh*), Bash(scripts/lockstep_check.sh*)
---

Run the lockstep invariant check and report any divergence:

```
./scripts/lockstep_check.sh
```

It builds both impls, then diffs the `zuil_*` export sets of `include/zuil.h`,
the `-Dimpl=c` `libzuil.so`, and the `-Dimpl=zig` `libzuil.so`. Any symbol in
the header but missing from an impl — or exported by one impl and not the other
— is a lockstep break (exit 1, symbols named). Use this right after touching
`include/zuil.h`, `src/zuil.c`, or `src/zuil.zig`.
