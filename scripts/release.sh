#!/bin/bash
# Builds a distributable Glint: Developer ID signed, hardened runtime, notarized when credentials are available,
# packaged as build/release/Glint-<version>.dmg and .zip (plus SHA-256 sums).
#
#   scripts/release.sh                      # sign + package
#   GLINT_NOTARY_PROFILE=glint scripts/release.sh   # also notarize and staple
#
# One-time notarization setup (stores an app-specific password in your Keychain, nothing in the repo):
#   xcrun notarytool store-credentials glint --apple-id you@example.com --team-id <TEAMID>
#
# No API keys are ever part of the build: the script fails if anything key-shaped is found in the bundle.
set -euo pipefail
cd "$(dirname "$0")/.."

IDENTITY="${GLINT_SIGN_IDENTITY:-$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)}"
[ -n "$IDENTITY" ] || { echo "No Developer ID Application identity found. Set GLINT_SIGN_IDENTITY." >&2; exit 1; }
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' packaging/Info.plist)"
echo "Signing as: $IDENTITY"

GLINT_SIGN_IDENTITY="$IDENTITY" scripts/build-app.sh release >/dev/null
APP=build/Glint.app

# Secrets check: values from a local .env, and common key prefixes, must not appear anywhere in the bundle.
if [ -f .env ]; then
  while IFS='=' read -r name value; do
    value="${value%\"}"; value="${value#\"}"
    [ ${#value} -ge 12 ] || continue
    if grep -rqF -- "$value" "$APP"; then echo "SECRET LEAK: the value of $name from .env is inside $APP" >&2; exit 1; fi
  done < <(grep -E '^[A-Za-z_][A-Za-z0-9_]*=' .env)
fi
if grep -rqaE 'sk-ant-[A-Za-z0-9_-]{20,}|sk_[a-f0-9]{40,}' "$APP"; then echo "SECRET LEAK: an API key pattern is inside $APP" >&2; exit 1; fi

codesign --verify --deep --strict "$APP"
OUT=build/release; rm -rf "$OUT"; mkdir -p "$OUT"
ZIP="$OUT/Glint-$VERSION.zip"; DMG="$OUT/Glint-$VERSION.dmg"

notarize() { # $1 file
  xcrun notarytool submit "$1" --keychain-profile "$GLINT_NOTARY_PROFILE" --wait
}

ditto -c -k --keepParent "$APP" "$ZIP"
if [ -n "${GLINT_NOTARY_PROFILE:-}" ]; then
  notarize "$ZIP"
  xcrun stapler staple "$APP"
  rm "$ZIP"; ditto -c -k --keepParent "$APP" "$ZIP"      # re-zip with the stapled ticket
fi

STAGE="$(mktemp -d)"; cp -R "$APP" "$STAGE/"; ln -s /Applications "$STAGE/Applications"
hdiutil create -quiet -volname "Glint $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
rm -rf "$STAGE"
codesign --force --timestamp --sign "$IDENTITY" "$DMG"
if [ -n "${GLINT_NOTARY_PROFILE:-}" ]; then notarize "$DMG"; xcrun stapler staple "$DMG"; fi

( cd "$OUT" && shasum -a 256 "$(basename "$DMG")" "$(basename "$ZIP")" > SHA256SUMS.txt )
echo
[ -n "${GLINT_NOTARY_PROFILE:-}" ] && echo "Notarized and stapled." || echo "Signed but NOT notarized (set GLINT_NOTARY_PROFILE). Gatekeeper will warn on other Macs."
ls -lh "$OUT"
