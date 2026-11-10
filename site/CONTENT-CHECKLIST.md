# Landing page content checklist

Every product claim on `site/index.html`, with its source as of 2026-11-10 (main at `02a235c`, which is also tag `v0.4.0`). The parent should reconcile this against `docs/LANDING-FEATURES.md` and any app changes the app lead lands before deploying.

Status key: **OK** = matches the README or docs and is in the v0.4.0 release. **Check** = plausible from source but worth confirming. **Not claimed** = deliberately left off the page.

## Release and download

| Claim on page | Source | Status |
|---|---|---|
| Latest download is Glint 0.4.0, `Glint-0.4.0.dmg` | `gh release view` (Latest, published 2026-11-10T15:35Z) | OK |
| 5.4 MB disk image | Release asset size 5,413,500 bytes | OK; update on each release |
| Developer ID signed and notarized | v0.4.0 release notes, README Install | OK |
| Apple Silicon (M1 or later), macOS 26 or later | Release notes, README, GAPS.md | OK |
| ZIP and SHA-256 checksums on the release page | Release assets `Glint-0.4.0.zip`, `SHA256SUMS.txt` | OK |
| "Changes on main reach source builds before the next release" | General statement; v0.4.0 currently equals main | OK. If main moves past v0.4.0 with user-facing features, decide whether to list them as "in source builds" with a label |
| Build from source: macOS 26 + Xcode 26 (Swift 6.2+), `scripts/build-app.sh`, `open build/Glint.app`, `glint install-cli` | README Quick start | OK |

## How it works / features

| Claim | Source | Status |
|---|---|---|
| Logs pointer, clicks and typing next to the video | README intro | OK |
| Tighten: shorter silent pauses, filler words cut, silent typing and idle waiting sped up | README "Tighten" | OK (README also says "trims dead ends", omitted) |
| Auto zoom: starts before, holds after, merges or pans instead of pumping | README "Auto zoom" | OK |
| Smooth cursor lands on each click, ripples, idle fade | README "Smooth cursor" | OK |
| Captions transcribed on device with Apple speech recognition, active word highlighted | README "Captions" (SpeechTranscriber, whisper fallback) | OK |
| Narration: scenes, Claude writes lines, ElevenLabs voice, picture retimed; own keys | README "Narration", AGENTS.md | OK |
| Record display or window, ScreenCaptureKit, HEVC up to 60 fps, system audio, optional mic | README "Record" | OK |
| ⇧⌘R starts recording | `GlintApp.swift:36`, `HomeView.swift:26` (`keyboardShortcut("r", [.command, .shift])`) | OK |
| Facecam, new in 0.4.0: circle/square/wide, any corner, follows cuts, shrinks while zoomed, captions move | v0.4.0 release notes, README | OK |
| Records keystroke timing, never keys; no extra permission | README "Record" | OK |
| Backgrounds, padding, corners, shadow; 16:9, 1:1, 9:16, 4:3; square/vertical follow cursor | README "Look" | OK |
| H.264, HEVC, ProRes, GIF; −16 LUFS; outputs measured | README "Export" | OK |
| Media never modified; project is folder of JSON + media; deletes go to Trash | README "Non-destructive" | OK |
| Edits attributed, undo/redo/selective revert | README "Agent-native" | OK |
| Quality checks list with fix hints | README "Measurable quality", AGENTS.md `glint_quality_report` | OK |
| New recordings go to `~/Movies/Glint` | README Quick start comment | OK |

## Agents

| Claim | Source | Status |
|---|---|---|
| App, CLI and MCP share one engine; agent edits show live in editor | README "One engine" | OK |
| One-click Connect for Claude Code, Codex, Claude Desktop; `glint connect` | README "Connect your agents", AGENTS.md | OK (added in v0.2.0) |
| Cursor, VS Code, Windsurf, Zed get a snippet; `glint connect --print` | README, AGENTS.md | OK |
| Glint checks the server answers, edits only its entry, keeps a backup | README | OK |
| Chat tab runs Claude Code or Codex with existing sign-in, no API key; tool calls shown live | README "Chat with an agent", AGENTS.md (added in v0.3.0) | OK |
| Agent recordings run in Glint.app; visible, stoppable; Screen Recording asked once for Glint | README, AGENTS.md "Where recording happens" | OK (falls back to host process if app unreachable; not mentioned on page) |
| Proposals with rationale; render/score a proposal before applying | README "Proposals" | OK |
| Recording, destructive and external actions need approval; agents can't approve | README "Approvals", AGENTS.md | OK |
| Approvals are not a security boundary (FAQ) | GAPS.md "Agents" | OK |
| Agent walkthroughs via `glint_record_action` | README "Walkthroughs" | OK |
| 41 tools | README "all 41 tools"; AGENTS.md table | Check: recount if the app lead adds tools (`glint tools --markdown`) |
| "Codex (CLI, IDE extension and app)" | README agent table | OK |

## Privacy

| Claim | Source | Status |
|---|---|---|
| Recording, zooms, cuts, captions, export run locally | README Install section | OK |
| Scene detection and OCR are on device | README "Narration", AGENTS.md | OK |
| Anthropic receives frames, on-screen text and brief; ElevenLabs receives the script | AGENTS.md `glint_write_narration`, `glint_voiceover` | OK (page lists frames, on-screen text, actions, recorded speech and brief) |
| Keys in Keychain, not part of app, agents can't read or set | README | OK |
| Site has no cookies or analytics | This site's code | OK |

## Deliberately not claimed

- **Pricing.** README says "Glint is free", but the page makes no price or "free forever" claim. Add one only if the owner confirms it.
- **License or "open source".** The repo has no license file (`licenseInfo: null`). The page says "source on GitHub", not open source.
- **App telemetry.** No analytics SDKs show up when grepping `Sources/`, but the page doesn't claim the app has no telemetry. Add that only after the app lead confirms it.
- **Account or sign-up.** None seen, but not claimed.
- **Customers, testimonials, usage numbers, comparisons with competitors.** None.
- **Auto-update.** Listed as missing in the FAQ (GAPS.md).

## Imagery

| File | Source | Note |
|---|---|---|
| `assets/img/editor.jpg`, `og.jpg` | `docs/images/editor.png` | Real screenshot, captioned as such. Captured 2026-11-09, before the full 0.4.0 restyle; no facecam shown. Retake from 0.4.0 or later if the UI has changed visibly |
| `assets/img/agent.jpg` | `docs/images/agent.png` | Real screenshot of the approval banner and proposal |
| `assets/img/frame-captions.jpg` | `docs/images/frame-captions.png` | Real rendered output frame |
| Timeline lane graphic in "What Glint adds" | Drawn in CSS | Illustrative and decorative (`aria-hidden`); it echoes the editor's lanes and isn't presented as a screenshot |

## Open items for the parent

1. Merge `docs/LANDING-FEATURES.md` from the app lead once it lands. Any new feature on main but not in the latest release should be labelled "Available when building from source" or held back until it ships.
2. When a new release ships, update every `0.4.0` / `v0.4.0` and the DMG size, and set `RELEASE` in `tests/check_site.py`.
3. Enable Pages with the source set to GitHub Actions (see `site/README.md`).
4. Do a browser check after deploy (not done here): mobile menu, focus order, dark mode, and the lane reveal with reduced motion on and off.
