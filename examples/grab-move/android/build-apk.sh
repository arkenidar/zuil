#!/usr/bin/env bash
# Package the native grab-move app into a signed, installable APK — the spike-C
# recipe from docs/mobile.md: SDK build-tools only, NO Gradle/prefab. Inputs are
# the zig-built jniLibs (libmain.so + libzuil.so) and the SDL3 AAR (libSDL3.so +
# classes.jar + SDLActivity). Produces an APK that installs + launches on the
# emulator/device.
#
# Usage (from the project root):
#   examples/grab-move/android/build-apk.sh            # x86_64 (the KVM emulator)
#   ABI=arm64-v8a examples/grab-move/android/build-apk.sh   # a real device
#
# Env (auto-detected, override as needed):
#   ANDROID_SDK   ~/apps/android-sdk          ZUIL_SDL3_AAR  the SDL3 *.aar
#   ANDROID_NDK   <sdk>/ndk/<ver>             ABI            x86_64 | arm64-v8a
#   API           35 (platform android.jar + targetSdk)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
cd "$ROOT"

ABI="${ABI:-x86_64}"
API="${API:-35}"
SDK="${ANDROID_SDK:-$HOME/apps/android-sdk}"
AAR="${ZUIL_SDL3_AAR:-$HOME/apps/SDL3-devel-3.4.10-android/SDL3-3.4.10.aar}"
NDK="${ANDROID_NDK:-$(ls -d "$SDK"/ndk/* 2>/dev/null | head -1)}"
BT="$(ls -d "$SDK"/build-tools/* | sort -V | tail -1)"   # newest build-tools
ANDROID_JAR="$SDK/platforms/android-$API/android.jar"

OUT="zig-out/grab-move-android-$ABI"
rm -rf "$OUT"; mkdir -p "$OUT/lib/$ABI"

echo "==> [1/7] cross-build libmain.so + libzuil.so ($ABI) via zig"
zig build -Dandroid -Dabi="$ABI" -Dndk="$NDK" -Daar="$AAR" grab-move-apk-libs

echo "==> [2/7] gather native libs (.so) for $ABI"
cp "zig-out/jniLibs/$ABI/libmain.so"  "$OUT/lib/$ABI/"
cp "zig-out/jniLibs/$ABI/libzuil.so"  "$OUT/lib/$ABI/"
# the AAR's prebuilt libSDL3.so for this ABI
unzip -o -j "$AAR" "prefab/modules/SDL3-shared/libs/android.$ABI/libSDL3.so" -d "$OUT/lib/$ABI/" >/dev/null

echo "==> [3/7] SDLActivity classes -> classes.dex (d8)"
unzip -o -j "$AAR" classes.jar -d "$OUT" >/dev/null
"$BT/d8" --min-api "$API" --output "$OUT" "$OUT/classes.jar"   # emits classes.dex

echo "==> [4/7] aapt2 link the manifest (no app resources)"
"$BT/aapt2" link -o "$OUT/base.apk" -I "$ANDROID_JAR" \
  --manifest examples/grab-move/android/AndroidManifest.xml \
  --min-sdk-version "$API" --target-sdk-version "$API"

echo "==> [5/7] add classes.dex + native libs into the APK"
( cd "$OUT" && zip -q base.apk classes.dex "lib/$ABI"/*.so )

echo "==> [6/7] zipalign"
"$BT/zipalign" -f 4 "$OUT/base.apk" "$OUT/grab-move-aligned.apk"

echo "==> [7/7] sign (debug keystore; created on first run)"
KS="$HOME/.android/debug.keystore"
if [ ! -f "$KS" ]; then
  keytool -genkeypair -keystore "$KS" -storepass android -keypass android \
    -alias androiddebugkey -dname "CN=Android Debug,O=Android,C=US" \
    -keyalg RSA -keysize 2048 -validity 10000 >/dev/null 2>&1
fi
"$BT/apksigner" sign --ks "$KS" --ks-pass pass:android --key-pass pass:android \
  --out "$OUT/grab-move.apk" "$OUT/grab-move-aligned.apk"

echo "==> done: $OUT/grab-move.apk"
echo "    install + launch:"
echo "      $SDK/platform-tools/adb install -r $OUT/grab-move.apk"
echo "      $SDK/platform-tools/adb shell am start -n org.zuil.grabmove/org.libsdl.app.SDLActivity"
