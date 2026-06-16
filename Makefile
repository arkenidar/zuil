# ZUIL Makefile — a thin, universal discoverability layer over the build.
#
# Deliberately NOT a second build system: every target shells out to build.zig
# or the scripts/ gate, so there is one source of truth and nothing to keep in
# sync. `make` is everywhere, which reinforces the project's stance that
# build.zig is convenience, not a dependency (the `hedge` target proves the
# whole desktop .so builds with plain gcc and zero Zig).
#
# Targets:
#   make            -> build the default C-impl libs (zig build)
#   make verify     -> the full gate (both impls, lockstep, smokes, gcc hedge)
#   make lockstep   -> just the C/Zig/header invariant diff
#   make hedge      -> build libzuil.so with plain gcc (no Zig) + run the smoke
#   make hooks      -> install the version-controlled git pre-commit gate
#   make web        -> link the grab-move wasm app (needs $EMSDK)
#   make android    -> package the signed APK (no Gradle; needs NDK + SDL3 AAR)
#   make clean      -> remove zig build outputs

.POSIX:
.PHONY: all build verify lockstep hedge hooks web android clean

all: build

build:
	zig build

verify:
	./scripts/verify.sh

lockstep:
	./scripts/lockstep_check.sh

# The toolchain hedge, made a first-class target: no Zig in this path at all.
hedge:
	mkdir -p zig-out/lib
	gcc -shared -Iinclude -o zig-out/lib/libzuil.so src/zuil.c $$(pkg-config --cflags --libs sdl3)
	luajit examples/smoke.lua

hooks:
	./scripts/install-hooks.sh

web:
	EMSDK=$${EMSDK:-$$HOME/apps/em-sdk} zig build -Dwasm grab-move-web

android:
	examples/grab-move/android/build-apk.sh

clean:
	rm -rf zig-out .zig-cache
