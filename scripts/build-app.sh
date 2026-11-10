#!/bin/bash
# Builds build/Glint.app (release) containing the app and the `glint` CLI.
# Ad-hoc signed by default. Set GLINT_SIGN_IDENTITY="Developer ID Application: …" to sign for distribution
# (hardened runtime, timestamp); scripts/release.sh does that and packages the result.
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIG="${1:-release}"
swift build -c "$CONFIG" --product GlintApp
swift build -c "$CONFIG" --product glint
BIN="$(swift build -c "$CONFIG" --show-bin-path)"
APP=build/Glint.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Helpers"
cp "$BIN/GlintApp" "$APP/Contents/MacOS/Glint"
cp "$BIN/glint" "$APP/Contents/Helpers/glint"
cp packaging/Info.plist "$APP/Contents/Info.plist"
if [ -z "${GLINT_SIGN_IDENTITY:-}" ]; then
  # Ad-hoc development builds get their own identity. Sharing dev.glint.Glint with the signed app makes macOS tie
  # privacy grants (Screen Recording, Microphone) to whichever build asked first, and refuse the other.
  /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier dev.glint.Glint.dev" "$APP/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Add :CFBundleDisplayName string Glint Dev" "$APP/Contents/Info.plist" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName Glint Dev" "$APP/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleName Glint Dev" "$APP/Contents/Info.plist" 2>/dev/null || true
fi
ICONSET=build/AppIcon.iconset
if [ ! -f build/AppIcon.icns ]; then
  swift scripts/make-icon.swift "$ICONSET" && iconutil -c icns "$ICONSET" -o build/AppIcon.icns
fi
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
if [ -n "${GLINT_SIGN_IDENTITY:-}" ]; then
  # Inside out: the helper first, then the bundle. Same entitlements for both (microphone and camera).
  codesign --force --options runtime --timestamp --entitlements packaging/Glint.entitlements \
    --identifier dev.glint.Glint.cli --sign "$GLINT_SIGN_IDENTITY" "$APP/Contents/Helpers/glint"
  codesign --force --options runtime --timestamp --entitlements packaging/Glint.entitlements \
    --sign "$GLINT_SIGN_IDENTITY" "$APP"
else
  codesign --force --deep --sign - "$APP" >/dev/null
fi
echo "$APP"
