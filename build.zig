const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

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

    const mod = b.createModule(.{
        .root_source_file = b.path("src/zuil.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "cdefs", .module = cdefs },
        },
    });

    // Step 0: a do-nothing shared library that links SDL3 and exports one symbol.
    const lib = b.addLibrary(.{
        .name = "zuil",
        .root_module = mod,
        .linkage = .dynamic,
    });
    b.installArtifact(lib);
}
