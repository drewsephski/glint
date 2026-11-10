# Distributing Glint for macOS

Glint is a native Swift app. Direct distribution uses a Developer ID Application certificate and Apple notarization; it does not require a Mac App Store listing. The current minimum OS is macOS 26. Builds target the architecture of the build machine; an Apple Silicon build does not support Intel Macs.

## Apple setup (once per developer Mac)

1. Use an Apple Account with an active [Apple Developer Program membership](https://developer.apple.com/programs/). Find its Team ID under [Membership details](https://developer.apple.com/account/).
2. Install a Developer ID Application certificate **and its private key** in Keychain. Check with `security find-identity -v -p codesigning`.
3. At [account.apple.com](https://account.apple.com/), open **Sign-In and Security → App-Specific Passwords**, generate a password named `Glint notarization`, and copy it. This requires two-factor authentication. Use the Apple Account belonging to the signing team, not a separate account for the app. [Apple instructions](https://support.apple.com/en-us/102654).
4. Store it in Keychain using the following command, replacing the placeholders. Enter the app-specific password at the hidden prompt; do not put it in the command, `.env`, source files, or GitHub.

```bash
xcrun notarytool store-credentials glint --apple-id 'YOUR_APPLE_ACCOUNT_EMAIL' --team-id 'YOUR_TEAM_ID'
xcrun notarytool history --keychain-profile glint
```

The password authorizes notarization; the certificate signs the app. Both are needed. Apple also supports App Store Connect API keys as an alternative to an app-specific password. See [Apple's notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow).

## Build and verify

```bash
swift test
GLINT_NOTARY_PROFILE=glint scripts/release.sh
codesign --verify --deep --strict build/Glint.app
xcrun stapler validate build/Glint.app
spctl --assess --type execute --verbose=2 build/Glint.app
xcrun stapler validate build/release/Glint-0.1.0.dmg
spctl --assess --type open --context context:primary-signature --verbose=2 build/release/Glint-0.1.0.dmg
(cd build/release && shasum -a 256 -c SHA256SUMS.txt)
```

Update the version in `packaging/Info.plist` before a later release and use that version in the commands. If several signing identities are installed, set `GLINT_SIGN_IDENTITY` explicitly. The script signs the embedded CLI and app with the hardened runtime, notarizes and staples the app, then creates and signs the DMG and notarizes and staples it too. Both the ZIP and DMG contain the stapled app.

Running without `GLINT_NOTARY_PROFILE` produces signed but **not notarized** artifacts. Do not describe those as Gatekeeper-ready downloads. A successful notarization is also separate from testing recording, microphone permissions, editing, and export on another Mac.

## Publish a download

After all checks pass, commit and push the intended release source, then create a GitHub release with the DMG, ZIP, and checksums. For example, from the exact commit that was built:

```bash
gh release create v0.1.0 \
  build/release/Glint-0.1.0.dmg \
  build/release/Glint-0.1.0.zip \
  build/release/SHA256SUMS.txt \
  --repo drewsephski/glint --target "$(git rev-parse HEAD)" \
  --title 'Glint 0.1.0' \
  --notes 'Initial release for Apple Silicon Macs running macOS 26 or later. Developer ID signed and notarized by Apple.'
```

Only use those release notes after notarization and verification succeed. Private-repository releases are downloadable only by people with repository access. Public downloads need an approved public release repository or other public hosting; the source repository can remain private.

Download the published DMG, mount it, drag Glint to Applications, and verify first launch and the capture/edit/export workflow on a separate Mac before claiming end-to-end distribution testing.
