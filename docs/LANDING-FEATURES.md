# Landing page feature facts

For whoever writes the website. Everything here is implemented on `main` and covered by [ENHANCEMENTS.md](ENHANCEMENTS.md). Use only these claims.

## Release vs main

- **Public download: Glint 0.4.0** (Developer ID signed, notarized; `https://github.com/drewsephski/glint/releases/download/v0.4.0/Glint-0.4.0.dmg`). It has recording, facecam, auto zoom, smooth cursor, tighten, captions, narration (Claude script + ElevenLabs voice, bring your own keys), export with measured outputs, and the agent connection for Claude Code, Codex and Claude Desktop.
- **On main, not in 0.4.0 yet:** everything in the "New" list below. Say "coming in the next release" or wait for a new version before presenting them as downloadable.
- Requirements: Apple silicon Mac, macOS 26 or later. Building from source: Xcode 26 (Swift 6.2+).

## New (main)

**Editing**
- Several shots in one project: import movies and append or insert them, split, reorder, trim, remove. Edits stay on their content when shots move. Shots of another shape are letterboxed.
- Music bed (loops, fades, lowers itself under narration), your own recorded voiceover, sound effects.
- Dip-to-black or dip-to-white transitions, including fade in and fade out.
- Callouts: text labels, arrows, boxes and spotlight highlights that zoom with the screen.
- Privacy masks: pixelate, blur or solid, for a time range, drawn into the preview, stills, GIFs and every export.
- Draw and adjust callouts and masks directly on the preview; tools on single keys (B, H, A, T, R).
- Captions: SRT and WebVTT export timed to the edited video, and import; fonts (system, rounded, serif, mono), weight, size, colours, position.
- Cut words from the transcript, or every occurrence of a phrase.
- Reusable style presets across projects.
- Timeline: trim handles, drag captions, speed changes, callouts and audio; snapping; keyboard shortcut sheet (⌘/).

**Recording**
- Pause and resume a take (screen, audio, camera and input stay in sync, no gap).
- Crash recovery: takes are written in 2-second fragments; an interrupted take can be rebuilt from Home or `glint recover` (up to about 2 s may be lost).
- Preflight before recording: permission, source, microphone/camera, folder and disk space, with a fix for each problem.
- Window recordings follow a window that is moved during the take.

**Agents**
- Demo recipes: scenes with stable IDs, steps and expected outcomes, versioned.
- Evidence per outcome: verified, failed or needs review. A click is never treated as proof; Glint checks on-screen text itself with on-device OCR, other outcomes need a real check from the agent or a person.
- Re-record one scene after a product change and swap it in; every other edit is kept.
- Durable render and production jobs with progress, cancel, retry and resume after a crash. A production check only says "passed" when every check passes, otherwise it lists what needs review.
- Everything is available in the app, the `glint` CLI and the MCP server (65 tools).

## Do not claim

- That Glint explores or drives apps by itself (an external coding agent drives; Glint records and checks).
- Crossfades, picture-in-picture, device frames, per-shot facecam, transcription of imported clips.
- Automatic detection of sensitive content: masks are placed by a person or agent.
- Parity with any named competitor, Windows support, hosted or team features.
- That every drag interaction has been user-tested: they were built and screenshotted, not driven by automation.
