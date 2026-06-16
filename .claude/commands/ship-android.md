---
description: Package the grab-move signed APK (no Gradle) — the Android ship gate
allowed-tools: Bash(examples/grab-move/android/build-apk.sh*)
---

Package the grab-move signed APK with the no-Gradle recipe
(zig cross-build → aapt2 → d8 → zipalign → apksigner):

```
examples/grab-move/android/build-apk.sh
```

Defaults to `arm64-v8a` (real devices); the script's env/flags select the ABI
(`x86_64` for the KVM emulator). It needs the Android NDK and the SDL3 AAR on
the documented env vars (`ANDROID_NDK_HOME` / `ZUIL_SDL3_AAR`) and `unzip` on
PATH. Report the resulting APK path and signing status.
