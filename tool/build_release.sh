#!/usr/bin/env bash
# Release builds with R8 shrinking (android/app/build.gradle.kts) and Dart
# obfuscation.
#
#   tool/build_release.sh                # Android: AAB + per-ABI APKs
#   tool/build_release.sh linux          # Linux desktop bundle
#   tool/build_release.sh --with-key     # also compile in secrets.json
#
# Release builds leave out the Gemini key by default: users add their own
# on the Profile tab. A key compiled in with --with-key can be pulled out
# of the APK by anyone who has it, obfuscated or not, so use it only for
# demo devices you control.
#
# Obfuscation symbols go to build/symbols/<version>/. Keep them for each
# release you ship; they're needed to read its crash stack traces:
#   flutter symbolize -i trace.txt -d build/symbols/<version>/app.android-arm64.symbols
set -euo pipefail
cd "$(dirname "$0")/.."

target=android
defines=()
for arg in "$@"; do
  case "$arg" in
    android | linux) target=$arg ;;
    --with-key)
      [[ -f secrets.json ]] || { echo "secrets.json not found" >&2; exit 1; }
      echo "Warning: compiling the Gemini key into the build." >&2
      defines=(--dart-define-from-file=secrets.json)
      ;;
    *) echo "Unknown argument: $arg" >&2; exit 2 ;;
  esac
done

version=$(sed -n 's/^version: *//p' pubspec.yaml)
flags=(--release --obfuscate --split-debug-info="build/symbols/$version" "${defines[@]}")

if [[ $target == linux ]]; then
  flutter build linux "${flags[@]}"
  echo "Bundle: build/linux/x64/release/bundle/"
else
  flutter build appbundle "${flags[@]}"
  flutter build apk --split-per-abi "${flags[@]}"
  echo "Play Store: build/app/outputs/bundle/release/app-release.aab"
  echo "Sideload:   build/app/outputs/flutter-apk/app-*-release.apk"
  ls -la build/app/outputs/flutter-apk/*-release.apk
fi
