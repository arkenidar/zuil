//! ZUIL build — the C-ABI core, emitted in both linkages, for two targets.
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
//! Why two linkages: the loading model — not taste — picks the artifact
//! (`ffi.load` needs a .so; iOS/C++ want the static archive). One core, many
//! faces over one C ABI; see docs/bindings.md.
const std = @import("std");

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});

    // `zig build -Dandroid` cross-builds the arm64-v8a Android .so (links the
    // SDL3 AAR); without it, the normal desktop build runs unchanged.
    const android = b.option(bool, "android", "Cross-build the arm64-v8a Android .so (links the SDL3 AAR)") orelse false;

    if (android) {
        buildAndroid(b, optimize);
    } else {
        buildDesktop(b, optimize);
    }
}

/// Desktop build: translate-c reads the system SDL3 headers (libsdl3-dev) and
/// the library links system SDL3 via pkg-config. Host target.
fn buildDesktop(b: *std.Build, optimize: std.builtin.OptimizeMode) void {
    const target = b.standardTargetOptions(.{});

    // C interop via translate-c (this Zig dev build uses it in place of @cImport).
    // The created module both translates the SDL3 header and links the system lib.
    const cdefs_tc = b.addTranslateC(.{
        .root_source_file = b.path("src/cdefs.h"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    cdefs_tc.linkSystemLibrary("sdl3", .{});
    const cdefs = cdefs_tc.createModule();

    // Emit both linkages of the C-ABI face (the consumer selects one):
    //   libzuil.so (dynamic) → LuaJIT FFI / Python ctypes;  libzuil.a (static) → C++/native.
    inline for (.{ std.builtin.LinkMode.dynamic, .static }) |linkage| {
        const mod = b.createModule(.{
            .root_source_file = b.path("src/zuil.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "cdefs", .module = cdefs },
            },
        });

        // Step 0: a do-nothing library that links SDL3 and exports one symbol.
        const lib = b.addLibrary(.{
            .name = "zuil",
            .root_module = mod,
            .linkage = linkage,
        });
        b.installArtifact(lib);
    }
}

// The arm64-v8a slice of the prebuilt SDL3 Android AAR. Internal layout is
// fixed by SDL's prefab packaging (see docs/mobile.md, spikes A/B).
const aar_headers_subpath = "prefab/modules/SDL3-Headers/include";
const aar_arm64_libdir = "prefab/modules/SDL3-shared/libs/android.arm64-v8a";

/// Android build: cross-compile + link the same Step-0 library for
/// aarch64-linux-android against the prebuilt SDL3 AAR. Validated as the
/// build-system form of spikes A/B (translate-c against the AAR headers under
/// the Android target; link the AAR's arm64 libSDL3.so). See docs/mobile.md.
///
/// Requires (via -D options or env):
///   -Dndk=<path>  or  $ANDROID_NDK_HOME / $ANDROID_NDK_ROOT  — Android NDK root
///   -Daar=<path>  or  $ZUIL_SDL3_AAR                         — SDL3-*-android .aar
/// and `unzip` on PATH (used to slice the AAR).
fn buildAndroid(b: *std.Build, optimize: std.builtin.OptimizeMode) void {
    const ndk = b.option([]const u8, "ndk", "Android NDK root") orelse
        b.graph.environ_map.get("ANDROID_NDK_HOME") orelse
        b.graph.environ_map.get("ANDROID_NDK_ROOT") orelse
        std.debug.panic("Android build needs -Dndk=<path> or $ANDROID_NDK_HOME", .{});

    const aar = b.option([]const u8, "aar", "Path to the SDL3 Android .aar") orelse
        b.graph.environ_map.get("ZUIL_SDL3_AAR") orelse
        std.debug.panic("Android build needs -Daar=<path-to-SDL3.aar> or $ZUIL_SDL3_AAR", .{});

    // minSdk: 21 matches the AAR's prebuilt libSDL3.so (its abi.json says api 21).
    const api = b.option(u32, "android-api", "Android minSdk / crt API level") orelse 21;

    // The triple stays plain (aarch64-linux-android, as proven in spike A); the
    // API level is pinned through the libc file's crt_dir rather than the triple.
    const target = b.resolveTargetQuery(.{
        .cpu_arch = .aarch64,
        .os_tag = .linux,
        .abi = .android,
    });

    // NDK sysroot layout (Linux x86_64 host toolchain).
    const sysroot = b.pathJoin(&.{ ndk, "toolchains/llvm/prebuilt/linux-x86_64/sysroot" });
    const inc = b.pathJoin(&.{ sysroot, "usr/include" });
    const arch_inc = b.pathJoin(&.{ sysroot, "usr/include/aarch64-linux-android" });
    const crt_dir = b.pathJoin(&.{ sysroot, b.fmt("usr/lib/aarch64-linux-android/{d}", .{api}) });

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

    // Slice the AAR for the arm64 headers + libSDL3.so. unzip preserves the
    // archive's internal directory structure under the output dir.
    const slice = b.addSystemCommand(&.{ "unzip", "-o", aar });
    slice.addArg(b.fmt("{s}/*", .{aar_headers_subpath}));
    slice.addArg(b.fmt("{s}/libSDL3.so", .{aar_arm64_libdir}));
    slice.addArg("-d");
    const aar_root = slice.addOutputDirectoryArg("sdl3-aar");
    const sdl_headers = aar_root.path(b, aar_headers_subpath);
    const sdl_libdir = aar_root.path(b, aar_arm64_libdir);

    // translate-c under the Android target: the build-system TranslateC step
    // does not forward a --libc file, so point clang at the NDK sysroot headers
    // via -isystem (base + arch), and neuter bionic's nullability keywords,
    // which Zig's bundled clang rejects in array-size position (e.g.
    // `__times[_Nullable 2]` in <sys/time.h>). Verified end-to-end (10k+ lines,
    // SDL_GetVersion present).
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
    const cdefs = cdefs_tc.createModule();

    // Emit both arm64 linkages: dynamic libzuil.so (FFI, into jniLibs/) and static
    // libzuil.a (C++ / native / PUC-Lua module / iOS-shaped consumers, into lib/).
    inline for (.{ std.builtin.LinkMode.dynamic, .static }) |linkage| {
        const mod = b.createModule(.{
            .root_source_file = b.path("src/zuil.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "cdefs", .module = cdefs },
            },
        });
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
        const dest = if (linkage == .dynamic) "jniLibs/arm64-v8a" else "lib/arm64-v8a";
        const install = b.addInstallArtifact(lib, .{
            .dest_dir = .{ .override = .{ .custom = dest } },
        });
        b.getInstallStep().dependOn(&install.step);
    }
}
