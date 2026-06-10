/* ZUIL — Step 0, C implementation. Twin of src/zuil.zig behind the same
 * contract (include/zuil.h); `zig build -Dimpl=c` selects it (the default).
 *
 * Why a C twin at all: the pinned Zig *dev* toolchain is the project's most
 * fragile dependency. This file compiles with any C compiler (gcc, clang,
 * NDK clang, emcc), so if Zig ever becomes a stopper the core survives and
 * build.zig degrades to convenience rather than dependency. Including zuil.h
 * makes the compiler check this implementation against the contract. */
#define SDL_MAIN_HANDLED 1 /* keep SDL's header-only main shim off our entry point */
#include <SDL3/SDL.h>
#include "zuil.h"

int zuil_sdl_version(void)
{
    return SDL_GetVersion();
}
