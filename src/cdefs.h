/* Root header for Zig's translate-c step (this dev build uses it in place of @cImport).
 * SDL_MAIN_HANDLED keeps SDL's header-only main shim from hijacking our entry point. */
#define SDL_MAIN_HANDLED 1
#include <SDL3/SDL.h>
