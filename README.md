<img src="assets/icon.svg" width="64" height="64" alt="">

# Glint

**A native macOS screen recorder and editor for product demos, built so AI agents can do everything a person can.**

Record a take; Glint logs the pointer, clicks and typing next to the video, then turns the raw take into a polished demo. It adds spring-animated zooms that anticipate each action, a smooth redrawn cursor, tightened pauses, captions, a styled background, and vertical/square/GIF variants. Every recording, edit, render and quality check is available in three places: the app, the `glint` CLI, and an MCP server. All three share one engine, so edits are attributed, undoable, revision-checked, and can come from a person and an agent at the same time.

<p align="center"><img src="docs/images/editor.png" width="860" alt="Glint editor: preview, inspector, timeline with zoom, cut, speed and caption lanes"></p>

## What it does

- **Record:** a display or window via ScreenCaptureKit (HEVC, up to 60 fps), plus system audio and optional microphone. Input tracking needs no permissions: it records keystroke *timing*, never the keys.
- **Auto zoom:** clicks and typing are clustered into zooms that start before each action and hold after it. Nearby zooms merge or pan instead of "pumping". A deterministic spring camera follows the cursor, with motion blur on fast moves.
- **Smooth cursor:** zero-lag smoothing that still lands exactly on each click, the recorded cursor images (arrow, I-beam, …) or Glint's own arrow, idle fade, and click ripples.
- **Tighten:** shortens silent pauses, cuts filler words, speeds up silent typing and idle waiting, and trims dead ends.
- **Captions:** on-device transcription (Apple SpeechTranscriber, with whisper as fallback) and readable lines with the active word highlighted.
- **Look:** gradient or image backgrounds, padding, rounded corners, shadow, and 16:9 / 1:1 / 9:16 / 4:3 canvases (the square and vertical variants follow the cursor).
- **Export:** H.264, HEVC, ProRes, and GIF. Loudness is normalised toward −16 LUFS, with peak headroom. **Every output is measured**: duration vs edit, resolution, black or frozen frames, sharpness, loudness and clipping.
- **Non-destructive:** media is never touched. The project is an open folder of JSON plus standard media files.

## Agent-native

| | |
|---|---|
| **One engine** | The app, CLI and MCP call the same `GlintService`/`Engine`. An agent's edit shows up live in the open editor, with a banner. |
| **Typed, reversible edits** | 21 operation kinds become transactions with automatically derived inverse patches: undo/redo, selective revert, and `expected_revision` to prevent clobbering. |
| **Proposals** | Planners and agents propose edits with a rationale. Agents can render frames or contact sheets *of the proposal* and score it before anyone applies it. |
| **Measurable quality** | Edit checks (zoom coverage and pumping, cursor in view while zoomed, camera speed, dead air, caption reading speed…) and render checks, each with a verdict and a fix hint. |
| **Approvals** | Capture, destructive and external actions return `approval_required`. A person approves in the app or with `glint approve` (interactive terminal only). Agents can't approve. |
| **Walkthroughs** | Agents can record an app they're driving and report actions (`glint_record_action`), so automation that doesn't move the real cursor still gets zooms and a natural cursor. |

<p align="center"><img src="docs/images/agent.png" width="860" alt="Agent panel: a proposal from claude-code, attributed history, and an approval request"></p>

## Quick start

Requires macOS 26 and Xcode 26 (Swift 6.2+).

```bash
scripts/build-app.sh                         # → build/Glint.app (the CLI is at Contents/Helpers/glint)
open build/Glint.app                         # record (⇧⌘R), or "Try a demo project"
alias glint="$PWD/build/Glint.app/Contents/Helpers/glint"

glint sources                                # displays and windows
glint record --display 2 --duration 20       # → ~/Movies/Glint/Recording ….glint
glint autopilot -v landscape -v portrait     # tighten + zoom + captions + render + measure
glint qc                                     # edit quality checks
glint history                                # who changed what (undo/revert any of it)
glint demo-project --voice                   # synthetic project, no permissions needed
```

Connect an agent:

```bash
claude mcp add glint -- "$PWD/build/Glint.app/Contents/Helpers/glint" mcp
```

See [docs/AGENTS.md](docs/AGENTS.md) for the workflow and all 34 tools.

## Documentation

- [Architecture](docs/ARCHITECTURE.md): engine, project format, capture, motion, rendering, surfaces
- [Agents](docs/AGENTS.md): MCP/CLI workflow and the generated tool reference
- [Research](docs/research/README.md): REA studies of [Screen Studio](docs/research/screen-studio.md) and [ScreenKite](docs/research/screenkite.md) (confirmed vs inferred), [frameworks and the reelbird evaluation](docs/research/foundations.md)
- [Testing](docs/TESTING.md): automated suite, real recordings, end-to-end agent walkthrough, measured results
- [Known gaps](docs/GAPS.md)

## Development

```bash
swift build                                  # all targets
swift test                                   # 31 tests: core, real media pipeline, MCP protocol
python3 scripts/e2e/agent_walkthrough.py build/Glint.app/Contents/Helpers/glint /tmp/glint-e2e   # real recording, end to end
```

`GLINT_HOME` and `GLINT_PROJECTS` redirect the support folder (approvals, policy) and the default project folder, for example when testing.
