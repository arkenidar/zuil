//! ZUIL build — the C-ABI core, emitted in both linkages, for three targets.
//!
//! `zig build` (default, desktop/host): translate-c reads the system SDL3
//! headers; the library links system SDL3 via pkg-config. BOTH linkages land in
//! `zig-out/lib/`:  libzuil.so (dynamic → LuaJIT FFI / Python ctypes)  and
//! libzuil.a (static → C++ / native / a PUC-Lua C-API module).
//!
//! `zig build -Dandroid`: cross-compile aarch64-linux-android against the
//! prebuilt SDL3 Android AAR — the build-system form of the spikes in
//! docs/mobile.md. Needs -Dndk=<NDK> (or $ANDROID_NDK_HOME / _ROOT) and
//! -Daar=<SDL3-*-android.aar> (or $ZUIL_SDL3_AAR), plus `unzip` on PATH. Emits
//! zig-out/jniLibs/arm64-v8a/libzuil.so (FFI face, loaded by SDLActivity) and
//! zig-out/lib/arm64-v8a/libzuil.a (static, for C++/native/iOS-shaped consumers).
//!
//! `zig build -Dwasm`: cross-compile wasm32-emscripten against the Emscripten
//! SDL3 port headers — the web face (docs/web.md). Needs -Demsdk=<path> or
//! $EMSDK. Emits ONLY the static zig-out/lib/wasm32-emscripten/libzuil.a: the
//! web has no runtime loading, so the dynamic/FFI face has no analogue there;
//! emcc owns the final link (`wasm-smoke` runs it headless under node,
//! `wasm-serve` serves the browser page — the VS Code dev-loop entry point).
//!
//! Why two linkages: the loading model — not taste — picks the artifact
//! (`ffi.load` needs a .so; iOS/C++/web want the static archive). One core,
//! many faces over one C ABI; see docs/bindings.md.
//!
//! `-Dimpl=c|zig` (default **c**) picks which implementation of that ABI goes
//! into the artifacts: src/zuil.c or src/zuil.zig — twins behind the
//! include/zuil.h contract. C is the default as the toolchain hedge (see the
//! 2026-06-10 decision-log entry in docs/architecture.md): the C source
//! compiles with any C compiler, so if the pinned Zig dev build ever becomes
//! a stopper, this file degrades to convenience rather than dependency.
const std = @import("std");

/// The two interchangeable implementations of the C ABI. Selecting one is a
/// build-time choice; consumers cannot (and must not) tell them apart.
const Impl = enum { c, zig };

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});

    // `zig build -Dandroid` cross-builds the arm64-v8a Android .so (links the
    // SDL3 AAR); `zig build -Dwasm` cross-builds the wasm32-emscripten static
    // archive; without either, the normal desktop build runs unchanged.
    const android = b.option(bool, "android", "Cross-build the arm64-v8a Android .so (links the SDL3 AAR)") orelse false;
    const wasm = b.option(bool, "wasm", "Cross-build the wasm32-emscripten static .a (Emscripten SDL3 port)") orelse false;
    const impl = b.option(Impl, "impl", "Core implementation: c (default, toolchain hedge) or zig — same C ABI") orelse .c;

    if (android) {
        buildAndroid(b, optimize, impl);
    } else if (wasm) {
        buildWasm(b, optimize, impl);
    } else {
        buildDesktop(b, optimize, impl);
    }
}

/// One core module per (impl, target). The C impl compiles src/zuil.c against
/// include/zuil.h (the contract checks the implementation); the Zig impl
/// compiles src/zuil.zig against `cdefs`, the target's translate-c module
/// (pass null for the C impl — it includes the SDL3 headers directly, so the
/// caller hands it the right include paths instead).
fn coreModule(b: *std.Build, impl: Impl, cdefs: ?*std.Build.Module, opts: std.Build.Module.CreateOptions) *std.Build.Module {
    var o = opts;
    if (impl == .zig) o.root_source_file = b.path("src/zuil.zig");
    const mod = b.createModule(o);
    switch (impl) {
        .zig => mod.addImport("cdefs", cdefs.?),
        .c => {
            mod.addCSourceFile(.{ .file = b.path("src/zuil.c") });
            mod.addIncludePath(b.path("include"));
        },
    }
    return mod;
}

/// Desktop build: the library links system SDL3 (libsdl3-dev) via pkg-config.
/// Host target. The Zig impl reads the headers through translate-c; the C impl
/// includes them directly (pkg-config supplies the cflags either way).
fn buildDesktop(b: *std.Build, optimize: std.builtin.OptimizeMode, impl: Impl) void {
    const target = b.standardTargetOptions(.{});

    // Zig impl only: C interop via translate-c (this Zig dev build uses it in
    // place of @cImport). The created module both translates the SDL3 header
    // and links the system lib.
    const cdefs: ?*std.Build.Module = if (impl == .zig) blk: {
        const cdefs_tc = b.addTranslateC(.{
            .root_source_file = b.path("src/cdefs.h"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        // Give translate-c SDL3's *headers* only — not its link. Calling
        // `linkSystemLibrary("sdl3")` on a translate-c step appends `-lSDL3` to
        // the translate-c command itself, and on Windows lld then tries to merge
        // the static libSDL3.a's many objects → "coff does not support linking
        // multiple objects into one". The actual SDL3 link lives on `mod` below.
        addSdlIncludes(b, cdefs_tc);
        break :blk cdefs_tc.createModule();
    } else null;

    // Emit both linkages of the C-ABI face (the consumer selects one):
    //   libzuil.so (dynamic) → LuaJIT FFI / Python ctypes;  libzuil.a (static) → C++/native.
    inline for (.{ std.builtin.LinkMode.dynamic, .static }) |linkage| {
        const mod = coreModule(b, impl, cdefs, .{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        // Link SDL3 on the final module for BOTH impls. The C impl also needs
        // the pkg-config cflags here so its source finds SDL3's headers at
        // compile; the Zig impl already has the headers via translate-c's
        // include path (addSdlIncludes) and just needs the link.
        mod.linkSystemLibrary("sdl3", .{});

        // Windows/MSYS2: lld resolves pkg-config's bare `-lSDL3` to the *static*
        // libSDL3.a (it sits beside the import lib), but the non-static
        // `pkg-config --libs` omits SDL3's Win32 deps — so the shared libzuil
        // link fails with undefined winmm/ole32/setupapi/gdi32 symbols. Supply
        // SDL3's static dep list (from `pkg-config --static --libs sdl3`) so the
        // .so folds SDL3 in self-contained — no external SDL3.dll at runtime,
        // unlike the gcc-shared hedge. Linux desktop (libsdl3-dev) is unaffected;
        // these are a no-op off Windows. Harmless on the static archive and if a
        // future setup links SDL3 dynamically (real Win32 import libs either way).
        if (target.result.os.tag == .windows) {
            inline for (.{
                "winmm",  "imm32",    "ole32",    "oleaut32", "version",
                "uuid",   "advapi32", "setupapi", "shell32",  "gdi32",
                "user32", "kernel32", "dinput8",
            }) |win_lib| mod.linkSystemLibrary(win_lib, .{ .use_pkg_config = .no });
        }

        // Step 0: a do-nothing library that links SDL3 and exports one symbol.
        const lib = b.addLibrary(.{
            .name = "zuil",
            .root_module = mod,
            .linkage = linkage,
        });
        b.installArtifact(lib);
    }
}

/// Feed a translate-c step SDL3's include dirs *without* linking SDL3. We can't
/// use `linkSystemLibrary` for this: it appends `-lSDL3` to the translate-c
/// command, which breaks on Windows COFF (see the call site). So ask pkg-config
/// for the include flags alone and add each `-I` dir. `cwd_relative` because
/// these are absolute system paths, not build-root-relative.
fn addSdlIncludes(b: *std.Build, tc: *std.Build.Step.TranslateC) void {
    const cflags = b.run(&.{ "pkg-config", "--cflags-only-I", "sdl3" });
    var it = std.mem.tokenizeAny(u8, cflags, " \t\r\n");
    while (it.next()) |tok| {
        if (std.mem.startsWith(u8, tok, "-I"))
            tc.addSystemIncludePath(.{ .cwd_relative = tok[2..] });
    }
}

// The prebuilt SDL3 Android AAR's internal layout, fixed by SDL's prefab
// packaging (see docs/mobile.md, spikes A/B). Headers are ABI-independent; the
// per-ABI libSDL3.so dir is derived in buildAndroid from -Dabi.
const aar_headers_subpath = "prefab/modules/SDL3-Headers/include";

/// Android build: cross-compile + link the same Step-0 library for
/// aarch64-linux-android against the prebuilt SDL3 AAR. Validated as the
/// build-system form of spikes A/B (translate-c against the AAR headers under
/// the Android target; link the AAR's arm64 libSDL3.so). See docs/mobile.md.
///
/// Requires (via -D options or env):
///   -Dndk=<path>  or  $ANDROID_NDK_HOME / $ANDROID_NDK_ROOT  — Android NDK root
///   -Daar=<path>  or  $ZUIL_SDL3_AAR                         — SDL3-*-android .aar
/// and `unzip` on PATH (used to slice the AAR).
fn buildAndroid(b: *std.Build, optimize: std.builtin.OptimizeMode, impl: Impl) void {
    const ndk = b.option([]const u8, "ndk", "Android NDK root") orelse
        b.graph.environ_map.get("ANDROID_NDK_HOME") orelse
        b.graph.environ_map.get("ANDROID_NDK_ROOT") orelse
        std.debug.panic("Android build needs -Dndk=<path> or $ANDROID_NDK_HOME", .{});

    const aar = b.option([]const u8, "aar", "Path to the SDL3 Android .aar") orelse
        b.graph.environ_map.get("ZUIL_SDL3_AAR") orelse
        std.debug.panic("Android build needs -Daar=<path-to-SDL3.aar> or $ZUIL_SDL3_AAR", .{});

    // minSdk: 21 matches the AAR's prebuilt libSDL3.so (its abi.json says api 21).
    const api = b.option(u32, "android-api", "Android minSdk / crt API level") orelse 21;

    // ABI: arm64-v8a for real devices (default, proven in spike A); x86_64 for the
    // KVM emulator (spike C ran an x86_64 app). The AAR ships prebuilt libSDL3.so
    // for both; the NDK sysroot has both triple dirs. Everything ABI-specific
    // below derives from this one option.
    const abi_name = b.option([]const u8, "abi", "Android ABI: arm64-v8a (default) or x86_64") orelse "arm64-v8a";
    const is_x86 = std.mem.eql(u8, abi_name, "x86_64");
    const cpu_arch: std.Target.Cpu.Arch = if (is_x86) .x86_64 else .aarch64;
    const triple_dir = if (is_x86) "x86_64-linux-android" else "aarch64-linux-android";
    const aar_libdir_sub = if (is_x86)
        "prefab/modules/SDL3-shared/libs/android.x86_64"
    else
        "prefab/modules/SDL3-shared/libs/android.arm64-v8a";

    // The triple stays plain (<arch>-linux-android, as proven in spike A); the
    // API level is pinned through the libc file's crt_dir rather than the triple.
    const target = b.resolveTargetQuery(.{
        .cpu_arch = cpu_arch,
        .os_tag = .linux,
        .abi = .android,
    });

    // NDK sysroot layout (Linux x86_64 host toolchain).
    const sysroot = b.pathJoin(&.{ ndk, "toolchains/llvm/prebuilt/linux-x86_64/sysroot" });
    const inc = b.pathJoin(&.{ sysroot, "usr/include" });
    const arch_inc = b.pathJoin(&.{ sysroot, b.fmt("usr/include/{s}", .{triple_dir}) });
    const crt_dir = b.pathJoin(&.{ sysroot, b.fmt("usr/lib/{s}/{d}", .{ triple_dir, api }) });

    // Zig does not bundle bionic, so cross-linking needs a --libc paths file.
    // (include_dir is for any residual C compilation; crt_dir supplies the
    // shared-object crt objects + libc.so for this API level.)
    const libc_txt = b.addWriteFiles().add("android-libc.txt", b.fmt(
        \\include_dir={s}
        \\sys_include_dir={s}
        \\crt_dir={s}
        \\msvc_lib_dir=
        \\kernel32_lib_dir=
        \\gcc_dir=
        \\
    , .{ inc, inc, crt_dir }));

    // Slice the AAR for the headers + this ABI's libSDL3.so. unzip preserves the
    // archive's internal directory structure under the output dir.
    const slice = b.addSystemCommand(&.{ "unzip", "-o", aar });
    slice.addArg(b.fmt("{s}/*", .{aar_headers_subpath}));
    slice.addArg(b.fmt("{s}/libSDL3.so", .{aar_libdir_sub}));
    slice.addArg("-d");
    const aar_root = slice.addOutputDirectoryArg("sdl3-aar");
    const sdl_headers = aar_root.path(b, aar_headers_subpath);
    const sdl_libdir = aar_root.path(b, aar_libdir_sub);

    // Zig impl only — translate-c under the Android target: the build-system
    // TranslateC step does not forward a --libc file, so point clang at the
    // NDK sysroot headers via -isystem (base + arch), and neuter bionic's
    // nullability keywords, which Zig's *translate-c* rejects in array-size
    // position (e.g. `__times[_Nullable 2]` in <sys/time.h>) — plain C
    // compilation (the C impl below) accepts them fine, being a clang
    // extension. Verified end-to-end (10k+ lines, SDL_GetVersion present).
    const cdefs: ?*std.Build.Module = if (impl == .zig) blk: {
        const cdefs_tc = b.addTranslateC(.{
            .root_source_file = b.path("src/cdefs.h"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        cdefs_tc.defineCMacro("_Nullable", "");
        cdefs_tc.defineCMacro("_Nonnull", "");
        cdefs_tc.defineCMacro("_Null_unspecified", "");
        cdefs_tc.addSystemIncludePath(.{ .cwd_relative = inc });
        cdefs_tc.addSystemIncludePath(.{ .cwd_relative = arch_inc });
        cdefs_tc.addIncludePath(sdl_headers);
        break :blk cdefs_tc.createModule();
    } else null;

    // Emit both arm64 linkages: dynamic libzuil.so (FFI, into jniLibs/) and static
    // libzuil.a (C++ / native / PUC-Lua module / iOS-shaped consumers, into lib/).
    var shared_lib: *std.Build.Step.Compile = undefined;
    var shared_install: *std.Build.Step = undefined;
    inline for (.{ std.builtin.LinkMode.dynamic, .static }) |linkage| {
        const mod = coreModule(b, impl, cdefs, .{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        // The C impl compiles against the same headers translate-c read: the
        // NDK sysroot (bionic) plus the AAR's SDL3 headers.
        if (impl == .c) {
            mod.addSystemIncludePath(.{ .cwd_relative = inc });
            mod.addSystemIncludePath(.{ .cwd_relative = arch_inc });
            mod.addIncludePath(sdl_headers);
        }
        // Link the AAR's prebuilt arm64 libSDL3.so (-L<dir> -lSDL3); no pkg-config
        // for a cross target. (For the static .a this is recorded for dependents;
        // the archive holds only ZUIL's objects — the consumer links SDL3 itself.)
        mod.addLibraryPath(sdl_libdir);
        mod.linkSystemLibrary("SDL3", .{ .use_pkg_config = .no });

        const lib = b.addLibrary(.{
            .name = "zuil",
            .root_module = mod,
            .linkage = linkage,
        });
        lib.setLibCFile(libc_txt);

        // .so → jniLibs (loaded at runtime by SDLActivity);  .a → lib (link-time).
        const dest = if (linkage == .dynamic)
            b.fmt("jniLibs/{s}", .{abi_name})
        else
            b.fmt("lib/{s}", .{abi_name});
        const install = b.addInstallArtifact(lib, .{
            .dest_dir = .{ .override = .{ .custom = dest } },
        });
        b.getInstallStep().dependOn(&install.step);
        if (linkage == .dynamic) {
            shared_lib = lib;
            shared_install = &install.step;
        }
    }

    // The grab-move *app* as Android's main shared object (libmain.so). SDLActivity
    // dlopens libSDL3.so then this; grab-move.c's __ANDROID__ branch includes
    // SDL_main.h, so its main() is exported as SDL_main — the entry SDLActivity
    // calls. ZUIL is the dynamic libzuil.so (a clean NEEDED, already installed in
    // jniLibs beside this; Android's linker resolves it from nativeLibraryDir);
    // SDL3 stays the AAR's prebuilt .so (NEEDED via libzuil.so). Packaged into an
    // APK by examples/grab-move/android/build-apk.sh (the spike-C recipe —
    // aapt2/d8/zipalign/apksigner, no Gradle).
    const app_mod = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true });
    app_mod.addCSourceFile(.{ .file = b.path("examples/grab-move/grab-move.c") });
    app_mod.addIncludePath(b.path("include"));
    app_mod.addSystemIncludePath(.{ .cwd_relative = inc });
    app_mod.addSystemIncludePath(.{ .cwd_relative = arch_inc });
    app_mod.addIncludePath(sdl_headers);
    app_mod.linkLibrary(shared_lib);
    const app = b.addLibrary(.{ .name = "main", .root_module = app_mod, .linkage = .dynamic });
    app.setLibCFile(libc_txt);
    const app_install = b.addInstallArtifact(app, .{
        .dest_dir = .{ .override = .{ .custom = b.fmt("jniLibs/{s}", .{abi_name}) } },
    });
    // Opt-in: `zig build -Dandroid grab-move-apk-libs` installs the app + libzuil.so
    // pair (into jniLibs/<abi>/) that the packaging script needs — self-contained,
    // so it also pulls the dynamic libzuil.so install, not just libmain.so.
    const apk_libs = b.step("grab-move-apk-libs", "Build libmain.so + libzuil.so (grab-move) for Android packaging");
    apk_libs.dependOn(&app_install.step);
    apk_libs.dependOn(shared_install);
    b.getInstallStep().dependOn(&app_install.step);
}

/// Web build: cross-compile the same Step-0 library for wasm32-emscripten.
/// Division of labour mirrors Android exactly — Zig builds the core archive;
/// the platform toolchain does the platform link/packaging. Here that
/// toolchain is emcc: it injects the JS runtime and the SDL3 *port* (the
/// `wasm-smoke` / `wasm-serve` steps below), as Gradle/SDLActivity package the
/// Android side. Static `.a` only: the web has no `dlopen`, so the dynamic/FFI
/// face has no analogue (Emscripten SIDE_MODULEs exist but are out of scope) —
/// the web joins iOS in the static-archive column. See docs/web.md.
///
/// Requires (via -D options or env):
///   -Demsdk=<path>  or  $EMSDK (exported by emsdk_env.sh)  — emsdk root
/// with the SDL3 port already materialized in the emscripten cache (any
/// `emcc --use-port=sdl3` compile does it once; the panic below says how).
fn buildWasm(b: *std.Build, optimize: std.builtin.OptimizeMode, impl: Impl) void {
    const emsdk = b.option([]const u8, "emsdk", "Emscripten SDK root") orelse
        b.graph.environ_map.get("EMSDK") orelse
        std.debug.panic("wasm build needs -Demsdk=<path> or $EMSDK (source emsdk_env.sh)", .{});

    // The emscripten sysroot include carries BOTH the libc headers and —
    // once the port has been built once — the SDL3 *port* headers (SDL3/).
    // Using the port's headers (not the system libsdl3-dev ones) keeps the
    // translate-c declarations in lockstep with the library emcc links.
    const sysroot_inc = b.pathJoin(&.{ emsdk, "upstream/emscripten/cache/sysroot/include" });
    std.Io.Dir.cwd().access(b.graph.io, b.pathJoin(&.{ sysroot_inc, "SDL3/SDL.h" }), .{}) catch
        std.debug.panic(
            \\SDL3 port headers not found under {s}.
            \\Materialize the port once (downloads + caches SDL3):
            \\  echo 'int main(void){{return 0;}}' > /tmp/p.c && emcc /tmp/p.c --use-port=sdl3 -o /tmp/p.js
        , .{sysroot_inc});

    const target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .emscripten,
    });

    // Zig impl only — translate-c under the emscripten target: as with the
    // NDK, the build-system TranslateC step gets the sysroot headers via
    // -isystem. Zig has no bundled emscripten libc, so libc stays OFF for the
    // archive (emcc provides musl-flavoured libc at final link); the -isystem
    // path supplies every header translate-c needs, libc's included.
    const cdefs: ?*std.Build.Module = if (impl == .zig) blk: {
        const cdefs_tc = b.addTranslateC(.{
            .root_source_file = b.path("src/cdefs.h"),
            .target = target,
            .optimize = optimize,
            .link_libc = false,
        });
        cdefs_tc.addSystemIncludePath(.{ .cwd_relative = sysroot_inc });
        break :blk cdefs_tc.createModule();
    } else null;

    const mod = coreModule(b, impl, cdefs, .{
        .target = target,
        .optimize = optimize,
        .link_libc = false,
        // Drop the C UBSan instrumentation on wasm: in Debug, clang emits calls to
        // __ubsan_handle_* whose runtime lives in Zig's compiler_rt — which the
        // desktop .so links, but the emcc wasm link does not, leaving them
        // undefined at wasm-ld time. The web build doesn't ship that runtime, so
        // turn the checks off here (localized to wasm; desktop/Android keep them).
        .sanitize_c = .off,
    });
    // The C impl compiles against the same emscripten sysroot headers
    // (libc's + the SDL3 port's) that translate-c read for the Zig impl.
    if (impl == .c) mod.addSystemIncludePath(.{ .cwd_relative = sysroot_inc });

    const lib = b.addLibrary(.{
        .name = "zuil",
        .root_module = mod,
        .linkage = .static,
    });
    const install = b.addInstallArtifact(lib, .{
        .dest_dir = .{ .override = .{ .custom = "lib/wasm32-emscripten" } },
    });
    b.getInstallStep().dependOn(&install.step);

    // ---- emcc-side steps (opt-in, not part of the default install) --------
    // emcc owns the final wasm link: it brings the JS runtime, the SDL3 port
    // library, and (-g) DWARF for the VS Code / DevTools wasm debuggers.
    const emcc = b.pathJoin(&.{ emsdk, "upstream/emscripten/emcc" });

    // `zig build -Dwasm wasm-smoke` — link smoke_web.c + libzuil.a to .js and
    // run it headless under emsdk's bundled node (SDL_GetVersion needs no
    // display): the web twin of `luajit examples/smoke.lua`.
    const link_js = b.addSystemCommand(&.{emcc});
    link_js.addFileArg(b.path("examples/smoke_web.c"));
    link_js.addArtifactArg(lib);
    link_js.addArgs(&.{ "--use-port=sdl3", "-g", "-o" });
    const smoke_js = link_js.addOutputFileArg("smoke_web.js");

    const run_node = b.addSystemCommand(&.{findEmsdkNode(b, emsdk)});
    run_node.addFileArg(smoke_js);
    b.step("wasm-smoke", "Link the web smoke with emcc and run it under node")
        .dependOn(&run_node.step);

    // `zig build -Dwasm wasm-serve` — the .html variant, served over localhost
    // (wasm won't load from file://). Open the printed URL in the VS Code
    // Simple Browser; -g DWARF makes the module debuggable from DevTools /
    // js-debug. Blocks while serving, like a `zig build run` would.
    const link_html = b.addSystemCommand(&.{emcc});
    link_html.addFileArg(b.path("examples/smoke_web.c"));
    link_html.addArtifactArg(lib);
    link_html.addArgs(&.{ "--use-port=sdl3", "-g", "-o" });
    const smoke_html = link_html.addOutputFileArg("smoke_web.html");

    const web_files = b.addInstallDirectory(.{
        .source_dir = smoke_html.dirname(),
        .install_dir = .prefix,
        .install_subdir = "web",
    });

    const serve = b.addSystemCommand(&.{
        "python3",        "-m", "http.server", "8080",
        "--bind", "127.0.0.1", "-d",
    });
    // Serve straight from the emitted .html's cache dir (same files as the
    // installed copy). `b.getInstallPath` was removed in newer Zig dev builds,
    // and a LazyPath dir-arg is version-robust besides — addDirectoryArg also
    // wires the build dependency, so link_html runs first. web_files still
    // installs to zig-out/web for parity; depend on it so that copy is fresh.
    serve.addDirectoryArg(smoke_html.dirname());
    serve.step.dependOn(&web_files.step);
    b.step("wasm-serve", "Serve the web smoke at http://127.0.0.1:8080/smoke_web.html")
        .dependOn(&serve.step);

    // ---- the grab-move *app* on the web (not just Step 0) -----------------
    // Same division of labour as the smoke, but the full demo: emcc links
    // examples/grab-move/grab-move.c against the same libzuil.a + SDL3 port.
    // grab-move.c includes zuil.h (the smoke extern-declares), so pass -Iinclude;
    // under __EMSCRIPTEN__ its entry uses emscripten_set_main_loop (the browser
    // loop inversion, docs/web.md §3) — no source change, one #ifdef. A window is
    // opened, so it can't run headless under node like wasm-smoke: the verifiable
    // gate here is the link (`grab-move-web`); interaction is browser-only (`-serve`).
    const link_gm = b.addSystemCommand(&.{emcc});
    link_gm.addFileArg(b.path("examples/grab-move/grab-move.c"));
    link_gm.addArtifactArg(lib);
    link_gm.addArg("-I");
    link_gm.addDirectoryArg(b.path("include"));
    link_gm.addArgs(&.{ "--use-port=sdl3", "-g", "-o" });
    const gm_html = link_gm.addOutputFileArg("grab-move.html");

    const gm_files = b.addInstallDirectory(.{
        .source_dir = gm_html.dirname(),
        .install_dir = .prefix,
        .install_subdir = "web-grab-move",
    });
    // `zig build -Dwasm grab-move-web` — link + install only (no serve); the
    // build-here gate that proves the app compiles+links for wasm.
    b.step("grab-move-web", "Link the grab-move web app with emcc (no serve)")
        .dependOn(&gm_files.step);

    const gm_serve = b.addSystemCommand(&.{
        "python3",        "-m", "http.server", "8080",
        "--bind", "127.0.0.1", "-d",
    });
    gm_serve.addDirectoryArg(gm_html.dirname());
    gm_serve.step.dependOn(&gm_files.step);
    b.step("grab-move-serve", "Serve the grab-move web app at http://127.0.0.1:8080/grab-move.html")
        .dependOn(&gm_serve.step);
}

/// emsdk bundles its own node under <emsdk>/node/<version>_64bit/bin/node;
/// the version directory changes with emsdk releases, so discover it rather
/// than pin it (the tool shell has no node of its own).
fn findEmsdkNode(b: *std.Build, emsdk: []const u8) []const u8 {
    const node_root = b.pathJoin(&.{ emsdk, "node" });
    var dir = std.Io.Dir.cwd().openDir(b.graph.io, node_root, .{ .iterate = true }) catch
        std.debug.panic("wasm-smoke needs emsdk's bundled node; none at {s}", .{node_root});
    defer dir.close(b.graph.io);
    var it = dir.iterate();
    while (it.next(b.graph.io) catch null) |entry| {
        if (entry.kind == .directory)
            return b.pathJoin(&.{ node_root, entry.name, "bin/node" });
    }
    std.debug.panic("no node version directory under {s}", .{node_root});
}
