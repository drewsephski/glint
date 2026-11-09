#!/bin/bash
# Builds build/Glint.app (release, ad-hoc signed) containing the app and the `glint` CLI.
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
ICONSET=build/AppIcon.iconset
if [ ! -f build/AppIcon.icns ]; then
  swift scripts/make-icon.swift "$ICONSET" && iconutil -c icns "$ICONSET" -o build/AppIcon.icns
fi
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --deep --sign - "$APP" >/dev/null
echo "$APP"
