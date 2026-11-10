#!/bin/bash
# Builds build/Glint.app (release) containing the app and the `glint` CLI.
# Development builds use a stable Apple signing identity and a separate bundle ID.
# GLINT_SIGN_IDENTITY selects distribution signing; GLINT_DEV_SIGN_IDENTITY selects local signing.
# Ad-hoc signing is opt-in (GLINT_ALLOW_ADHOC=1): its privacy grants may break after every rebuild.
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIG="${1:-release}"
SIGN_IDENTITY="${GLINT_SIGN_IDENTITY:-${GLINT_DEV_SIGN_IDENTITY:-}}"
if [ -z "$SIGN_IDENTITY" ] && [ "${GLINT_ALLOW_ADHOC:-0}" != 1 ]; then
  # Never pick an arbitrary team when several are installed. Prefer Apple Development; Developer ID also
  # provides a stable requirement, but a local build still keeps the development bundle identifier.
  IDENTITIES="$(security find-identity -v -p codesigning)"
  for KIND in 'Apple Development:' 'Developer ID Application:'; do
    MATCHES="$(printf '%s\n' "$IDENTITIES" | sed -n "/\"$KIND /s/.*\"\(.*\)\".*/\1/p")"
    [ -n "$MATCHES" ] || continue
    COUNT="$(printf '%s\n' "$MATCHES" | wc -l | tr -d ' ')"
    if [ "$COUNT" != 1 ]; then
      echo "Multiple $KIND identities found. Set GLINT_DEV_SIGN_IDENTITY explicitly." >&2
      exit 1
    fi
    SIGN_IDENTITY="$MATCHES"
    break
  done
fi
if [ -z "$SIGN_IDENTITY" ]; then
  if [ "${GLINT_ALLOW_ADHOC:-0}" != 1 ]; then
    echo "No stable signing identity found. Set GLINT_DEV_SIGN_IDENTITY, or opt into disposable builds with GLINT_ALLOW_ADHOC=1." >&2
    exit 1
  fi
  SIGN_IDENTITY=-
fi
if [ "$SIGN_IDENTITY" = - ]; then
  [ -z "${GLINT_SIGN_IDENTITY:-}" ] && [ "${GLINT_ALLOW_ADHOC:-0}" = 1 ] || {
    echo "Ad-hoc signing requires GLINT_ALLOW_ADHOC=1 and cannot be used for distribution." >&2; exit 1;
  }
  echo "Warning: ad-hoc builds may need a new Screen Recording grant after each rebuild." >&2
fi
swift build -c "$CONFIG" --product GlintApp
swift build -c "$CONFIG" --product glint
BIN="$(swift build -c "$CONFIG" --show-bin-path)"
mkdir -p build
STAGE="$(mktemp -d build/.glint-app.XXXXXX)"
trap 'rm -rf "$STAGE"' EXIT
APP="$STAGE/Glint.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Helpers"
cp "$BIN/GlintApp" "$APP/Contents/MacOS/Glint"
cp "$BIN/glint" "$APP/Contents/Helpers/glint"
cp packaging/Info.plist "$APP/Contents/Info.plist"
# Public origin only; API/payment keys must never be packaged with the app.
if [ -n "${GLINT_VOICE_SERVICE_URL:-}" ]; then
  python3 - "$APP/Contents/Info.plist" <<'PY'
import os, plistlib, sys
from urllib.parse import urlsplit
value = os.environ["GLINT_VOICE_SERVICE_URL"]
url = urlsplit(value)
if (not url.hostname or url.username or url.password or url.query or url.fragment
        or url.path not in ("", "/")
        or not (url.scheme == "https" or (url.scheme == "http" and url.hostname in ("localhost", "127.0.0.1")))):
    raise SystemExit("GLINT_VOICE_SERVICE_URL must be an HTTPS origin (HTTP is allowed only on loopback).")
with open(sys.argv[1], "rb") as source:
    info = plistlib.load(source)
info["GlintVoiceServiceURL"] = value
with open(sys.argv[1], "wb") as destination:
    plistlib.dump(info, destination)
PY
fi
if [ -z "${GLINT_SIGN_IDENTITY:-}" ]; then
  # All development builds, including certificate-signed builds, stay separate from the installed release.
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
# Sign inside out. Never weaken the designated requirement to work around TCC.
SIGN_OPTIONS=(--force --sign "$SIGN_IDENTITY")
if [ "$SIGN_IDENTITY" != - ]; then
  SIGN_OPTIONS+=(--options runtime --entitlements packaging/Glint.entitlements)
  if [ -n "${GLINT_SIGN_IDENTITY:-}" ]; then SIGN_OPTIONS+=(--timestamp); else SIGN_OPTIONS+=(--timestamp=none); fi
fi
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")"
codesign "${SIGN_OPTIONS[@]}" --identifier "$BUNDLE_ID.cli" "$APP/Contents/Helpers/glint"
codesign "${SIGN_OPTIONS[@]}" "$APP"
codesign --verify --deep --strict "$APP"
# Only replace the previous build after a complete build and successful signature verification.
if [ -e build/Glint.app ]; then mv build/Glint.app "$STAGE/previous.app"; fi
if ! mv "$APP" build/Glint.app; then
  if [ -e "$STAGE/previous.app" ]; then mv "$STAGE/previous.app" build/Glint.app; fi
  exit 1
fi
echo build/Glint.app
