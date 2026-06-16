---
description: Build the grab-move web (wasm) app via emcc — the web ship gate
allowed-tools: Bash(EMSDK=* zig build *), Bash(zig build *)
---

Build the grab-move web app (the wasm build gate). Requires emsdk; the project
keeps it at `~/apps/em-sdk` (env `$EMSDK`, not on PATH):

```
EMSDK=~/apps/em-sdk zig build -Dwasm grab-move-web
```

This is link-only (no serve). To preview it in the VS Code integrated browser,
run `EMSDK=~/apps/em-sdk zig build -Dwasm grab-move-serve` and open the
localhost link. Report whether the emcc link succeeded.
