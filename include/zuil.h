/* ZUIL public C ABI — THE contract.
 *
 * This header is the single source of truth for the exported surface. Two
 * interchangeable implementations exist behind it — src/zuil.c (C, the
 * default) and src/zuil.zig (Zig) — selected with `zig build -Dimpl=...`;
 * consumers (LuaJIT FFI, ctypes, C, C++, JS/cwrap) see only these symbols and
 * must not care which implementation produced the library. Keep both
 * implementations in lockstep with this file.
 *
 * UTF-8 throughout; zuil_* snake_case; plain C types only (FFI-friendly). */
#ifndef ZUIL_H
#define ZUIL_H

#ifdef __cplusplus
extern "C" {
#endif

/* Step 0: returns the linked SDL3 version as a packed int (3.2.10 -> 3002010).
 * Exists to prove the whole build/link/FFI pipeline, nothing more. */
int zuil_sdl_version(void);

#ifdef __cplusplus
}
#endif

#endif /* ZUIL_H */
