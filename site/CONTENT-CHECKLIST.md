# Landing page content checklist

Every product claim on `site/index.html`, with its source as of 2026-11-10. Release claims are checked against tag `v0.4.0`; source-build claims against `docs/LANDING-FEATURES.md`, `README.md`, `docs/AGENTS.md` and `docs/GAPS.md` on the working branch (after `8be8b5b`).

Status key: **OK** = matches the README or docs and is in the v0.4.0 release. **Check** = plausible from source but worth confirming. **Not claimed** = deliberately left off the page. **Source** = on main, not in the 0.4.0 download; shown only in the clearly labelled "Available in source builds" section and FAQ.

## Release and download

| Claim on page | Source | Status |
|---|---|---|
| Latest download is Glint 0.4.0, `Glint-0.4.0.dmg` | `gh release view` (Latest, published 2026-11-10T15:35Z) | OK |
| 5.4 MB disk image | Release asset size 5,413,500 bytes | OK; update on each release |
| Developer ID signed and notarized | v0.4.0 release notes, README Install | OK |
| Apple Silicon (M1 or later), macOS 26 or later | Release notes, README, GAPS.md | OK |
| ZIP and SHA-256 checksums on the release page | Release assets `Glint-0.4.0.zip`, `SHA256SUMS.txt` | OK |
| FAQ: download is 0.4.0; newer features only in source builds until the next release | LANDING-FEATURES "Release vs main" | OK |
| Build from source: Apple Silicon, macOS 26 + Xcode 26 (Swift 6.2+), `scripts/build-app.sh`, `open build/Glint.app`, `build/Glint.app/Contents/Helpers/glint install-cli`, `… glint connect` (points agents at the build) | README Quick start (from source) | OK |
| Source builds are ad-hoc signed, permissions may reset after rebuild | GAPS.md "Platform and engineering" | OK |

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
| Hero: agents' reversible edits are attributed and undoable; bigger changes are previewable proposals (no claim that you approve every change) | README "Typed, reversible edits", "Proposals"; AGENTS.md (reversible tools apply without approval) | OK |
| Quality checks list with fix hints | README "Measurable quality", AGENTS.md `glint_quality_report` | OK |
| New recordings go to `~/Movies/Glint` | README Quick start comment | OK |

## Agents

| Claim | Source | Status |
|---|---|---|
| App, CLI and MCP share one engine; agent edits show live in editor | README "One engine" | OK |
| One-click Connect for Claude Code, Codex, Claude Desktop; `/Applications/Glint.app/Contents/Helpers/glint connect` and `connect --status` both use the full helper path | README "Connect your agents", AGENTS.md | OK (added in v0.2.0) |
| `install-cli` links plain `glint` into `~/.local/bin` | v0.4.0 README, AGENTS.md | OK |
| Cursor, VS Code, Windsurf, Zed get a snippet; `--print` | README, AGENTS.md | OK |
| Glint checks the server answers, edits only its entry, keeps a backup | README | OK |
| Chat tab runs Claude Code or Codex with existing sign-in, no API key; tool calls shown live; messages/project context go to that agent's provider | README "Chat with an agent", AGENTS.md "Chat inside Glint" (added in v0.3.0) | OK |
| Agent recordings run in Glint.app; visible, stoppable; Screen Recording asked once for Glint | README, AGENTS.md "Where recording happens" | OK (falls back to host process if app unreachable; not mentioned on page) |
| Proposals with rationale; render/score a proposal before applying | README "Proposals" | OK |
| Glint's capture, destructive and external tools return an approval request unless the user's policy allows them; agents can't approve; approvals don't cover an agent's own tools | README "Approvals", AGENTS.md ("unless the user's policy allows…") | OK |
| Approvals are not a security boundary (FAQ) | GAPS.md "Agents" | OK |
| Agent walkthroughs via `glint_record_action` | README "Walkthroughs" | OK |
| Tool count | v0.4.0 README says 41, main README says 65 | No number on the page; it says source builds have more tools and links docs/AGENTS.md |
| "Codex (CLI, IDE extension and app)" | README agent table | OK |

## Available in source builds

| Claim | Source | Status |
|---|---|---|
| Shots: import, append/insert, split, reorder, trim, remove; edits stay on content; letterbox | LANDING-FEATURES "Editing" | Source |
| Music bed (loops, fades, ducks), own voiceover, sound effects | LANDING-FEATURES | Source |
| Dip-to-black/white transitions, fade in/out | LANDING-FEATURES | Source |
| Callouts (text, arrows, boxes, spotlight), drawn on preview | LANDING-FEATURES | Source |
| Privacy masks placed by a person or agent, in preview, stills, GIFs, exports | LANDING-FEATURES, "Do not claim" automatic detection | Source |
| SRT/WebVTT export timed to edit, import; caption fonts/weight/size/colours/position | LANDING-FEATURES | Source |
| Cut words from transcript or every occurrence of a phrase | LANDING-FEATURES | Source |
| Style presets, trim handles, snapping, ⌘/ sheet | LANDING-FEATURES | Source |
| Pause/resume in sync; crash recovery from 2 s fragments, `glint recover`, up to ~2 s lost; preflight; window follow | LANDING-FEATURES "Recording", GAPS.md | Source |
| Recipes, evidence (click never proof, OCR on-device), scene refresh keeping manual edits outside the scene | LANDING-FEATURES "Agents", AGENTS.md | Source |
| Jobs: progress, cancel, retry; run inside the host process (app, CLI or MCP server); checkpoint per stage; retry continues after last completed stage when the host quit; production succeeds only if every check passes | AGENTS.md "Durable jobs", GAPS.md "Agents" | Source |

## Privacy

| Claim | Source | Status |
|---|---|---|
| Recording, zooms, cuts, captions, export run locally; two optional online paths: narration and agents | README Install section, AGENTS.md | OK |
| Agent chat / connected agents send messages, project context, Glint tool results and requested frames to that agent's provider | AGENTS.md "Chat inside Glint" (headless `claude -p` / `codex exec`), tools return frames as images | OK |
| Glint asks before calling Anthropic/ElevenLabs unless policy allows external; can't limit an agent's own tools or provider | AGENTS.md, GAPS.md "Agents" | OK |
| Scene detection and OCR are on device | README "Narration", AGENTS.md | OK |
| Anthropic (narration, user's key) receives frames, on-screen text, actions, recorded speech and brief; ElevenLabs receives only the script | AGENTS.md `glint_write_narration`, `glint_voiceover` | OK |
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
| `assets/img/editor.jpg`, `og.jpg` | `docs/images/editor.png` | Real screenshot, captioned as from a release build; shows none of the source-build features. Captured 2026-11-09, before the full 0.4.0 restyle; no facecam shown. Retake from 0.4.0 or later if the UI has changed visibly |
| `assets/img/agent.jpg` | `docs/images/agent.png` | Real screenshot of the approval banner and proposal, captioned as from a release build |
| `assets/img/frame-captions.jpg` | `docs/images/frame-captions.png` | Real rendered output frame, captioned as from a release build |
| Timeline lane graphic in "What Glint adds" | Drawn in CSS | Illustrative and decorative (`aria-hidden`); it echoes the editor's lanes and isn't presented as a screenshot |

## Open items for the parent

1. Done: features from `docs/LANDING-FEATURES.md` are in the labelled "Available in source builds" section. When the next release ships, move them into "Everything in the current release", drop the source-only label and the FAQ caveats, and retake screenshots that show them.
2. When a new release ships, update every `0.4.0` / `v0.4.0` and the DMG size, and set `RELEASE` in `tests/check_site.py`.
3. Enable Pages with the source set to GitHub Actions (see `site/README.md`).
4. Do a browser check after deploy (not done here): mobile menu, focus order, dark mode, and the lane reveal with reduced motion on and off.
