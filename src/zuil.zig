//! ZUIL — Step 0: prove the pipeline.
//! A do-nothing shared library that links SDL3 and exports a single C-ABI symbol.
//! Calling SDL_GetVersion forces the SDL3 dependency, so a successful link + a
//! correct version read from LuaJIT validates the whole build/link/FFI boundary.
const c = @import("cdefs");

/// Returns the linked SDL3 version as a packed int (e.g. 3.2.10 -> 3002010).
export fn zuil_sdl_version() callconv(.c) c_int {
    return c.SDL_GetVersion();
}
