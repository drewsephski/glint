# Architecture

Glint is a native macOS screen recorder and editor whose every capability sits behind one shared project engine. The SwiftUI app, the `glint` CLI and the MCP server are three thin surfaces over the same code. They work on the same files, and can do so at the same time.

```
                 ┌────────────── surfaces ──────────────┐
  SwiftUI app (GlintApp)      glint CLI (glint)        MCP server (glint mcp, stdio)
         │                          │  (ArgumentParser)        │ (JSON-RPC 2.0)
         └──────────────┬───────────┴──────────┬───────────────┘
                        ▼                      ▼
              GlintAgent: GlintService  ·  ToolRegistry (41 tools, risk-classed)  ·  Autopilot  ·  Docs
                        │
      ┌─────────────────┼──────────────────┬───────────────────────┐
      ▼                 ▼                  ▼                       ▼
  GlintCore         GlintCapture        GlintRender            GlintAnalysis
  (pure Swift)      ScreenCaptureKit    Core Image/Metal        SpeechTranscriber,
  document, ops,    + AVAssetWriter,    compositor, AVFoundation  loudness/silence,
  engine/history,   input tracking,     composition, export,     render inspection,
  proposals,        cursor images       frames, GIF,             scene frames + OCR
  approvals, time                       voiceover mix/ducking    (Vision), narration
  map, motion,                                                   writer (Anthropic),
  planners, scenes,                                              voices (ElevenLabs)
  narration fit,
  quality
```

Dependencies point inward. GlintCore imports nothing but Foundation (plus Security for the Keychain), so all edit logic, planning, motion and quality checking is deterministic and unit-testable without media.

## The project bundle

A project is a folder package `Name.glint/` (UTI `dev.glint.project`):

| Path | Contents |
|---|---|
| `project.json` | `ProjectDocument`: media info, recording info, `timeline` (in/out, cuts, speeds, zooms, captions, markers), `style` (background, frame, cursor, zoom/camera, captions, audio, canvas), and a `revision` counter |
| `events.json` | `EventLog`: pointer samples (~120 Hz), clicks (with accessibility labels when available), key-down instants (no characters unless opted in), scrolls, frontmost-app changes, cursor-image changes, markers |
| `transcript.json` | Word-timed transcript |
| `analysis/storyboard.json`, `analysis/<scene>.jpg` | Scenes (times, actions, on-screen text, speech, narration line) and one representative frame each |
| `history.jsonl` | Append-only transactions |
| `proposals/*.json` | Pending, applied or rejected proposals |
| `media/` | `screen.mov` (HEVC), `mic.m4a`, `system.m4a`. **Never modified by editing.** |
| `media/voiceover/<clip>.mp3` | Synthesized narration clips, one per scene line |
| `cursors/*.png` | Recorded cursor images |
| `renders/<id>/` | Outputs, `manifest.json`, measured reports |
| `.lock` | `flock` lock that serialises writers across processes |

Conventions: timeline items use **source (recording) seconds**, so edits stay attached to content when cuts move the output. Positions are normalised to the recorded screen with a top-left origin.

## Engine: typed operations → transactions with exact inverses

Every change is an `EditOperation`, a flat JSON shape that's easy for agents to write, e.g. `{"op":"add_zoom","start":3,"end":6,"scale":2}`. There are 21 kinds covering zooms, cuts, speeds, trim, style, captions, markers and rename. An operation may set `time_base: "output"`, and the engine converts through the current time map. That's handy when an agent is reasoning about rendered frames.

`Engine.apply(ops, author:, expectedRevision:)`:

1. takes the bundle's lock and re-reads `project.json` from disk;
2. rejects stale writers (`expectedRevision` ≠ current), so an agent can't clobber a user's edit;
3. applies the ops to a value copy with validation (`OperationApplier`);
4. **diffs before/after as JSON**, giving forward patches and inverse patches with recorded old values. Arrays of identified items diff by identity, so adding one zoom is a single `add`;
5. writes the document atomically and appends a `HistoryRecord` (author, label, operations, patches, revisions).

Because inverses are derived mechanically from the actual state change, any operation, including future ones, is undoable for free:

- **Undo/redo** is linear across all authors. Stacks are reconstructed from the log, so they persist and are shared between the app and the CLI.
- **Selective revert** applies one old transaction's inverse only if every path it touched still holds the value it left (`verify`). Otherwise it reports a conflict. Reverts are transactions too, so they're undoable.
- **Proposals** store validated operations without applying them. `preview(ops)` gives the hypothetical document, which render, frame, contact-sheet and quality tools all accept, so a proposal can be watched and measured before anyone accepts it.

## Approvals and risk

Every tool has a `Risk`: `read`, `reversible` (engine edits, new files inside the project), `capture`, `destructive`, `external`.

`ApprovalStore.authorize` gates by risk and author kind. Agents pass freely through read and reversible actions. Capture, destructive and external actions return `approval_required` with a request bound to a fingerprint of the exact parameters, single-use and expiring.

Humans approve in the app (banner with Approve/Deny) or with `glint approve <id>`, which refuses to run without an interactive TTY. There is no approve tool on the MCP surface. The CLI treats non-TTY callers (an agent's shell) as agents. A durable policy (`~/Library/Application Support/Glint/policy.json`) can pre-authorise capture for agents.

This is a guard for cooperative agents, not a security boundary against hostile local code; see [GAPS.md](GAPS.md).

## API keys and distribution

Keys for Anthropic and ElevenLabs are never compiled into the app or stored in the repo. `Secrets` looks in the environment, then the macOS Keychain (service `dev.glint.Glint`), then a 0600 file in the support folder. Builds signed with a Team ID use the Keychain; ad-hoc development builds and anything run with `GLINT_HOME` use the file, so they never raise Keychain prompts. `scripts/release.sh` signs the app and its CLI helper with a Developer ID under the hardened runtime (microphone is the only entitlement), scans the bundle for key-shaped strings and for values from a local `.env`, and packages a DMG and a zip; with `GLINT_NOTARY_PROFILE` it notarises and staples both.

## Capture

`RecordingSession` combines an `SCStream` (BGRA, sRGB, `showsCursor = false`, up to 60 fps, system audio and optional mic) feeding `AVAssetWriter`s (HEVC + AAC) with an `InputTracker`:

- **Clock:** all timestamps are host clock. The first frame's PTS becomes t=0, and tracker events are rebased onto it at stop.
- **Static endings:** ScreenCaptureKit only delivers changed frames, so the last frame is re-appended at the stop time.
- **Input tracking** polls `CGEventSource` at 120 Hz, which needs no permission. It samples `NSCursor.currentSystem` at 20 Hz into deduplicated PNGs and records frontmost-app changes.
- **Agent actions:** agents can report actions with `glint_record_action`. In `pointer: "agent"` mode the cursor path is synthesised from those reports, for apps driven over CDP or accessibility where the real cursor never moves.
- **App path:** the app can also start from `SCContentSharingPicker` (`RecordingSession(filter:)`), which avoids the macOS "bypass private picker" prompt.

## Motion

- **`TimeMap`** maps source↔output time from in/out points, cuts and speed segments. It drives the composition, renderer, planners and quality checks.
- **`CursorPath`:**
  - resampled to 120 Hz and Gaussian-smoothed with zero phase (offline, so no lag);
  - blended back to the raw path within ±150 ms of each press and release, so the drawn cursor is exactly where the user clicked;
  - an idle-fade opacity track, plus click ripples and a press "squash".
- **`CameraPath`:**
  - a fixed-step (240 Hz) spring simulation over the **output** timeline, so transitions keep their feel after speed changes. Deterministic: preview and export get identical paths.
  - springs act on log-scale (perceptually even zoom) and on centre x/y;
  - follow-cursor targets the position 0.3 s ahead, with a dead zone;
  - the viewport is clamped to the screen;
  - `canvas.baseScale > 1` gives reframed square/vertical variants that follow the cursor.

## Rendering: one path for preview, export and stills

`EditComposition.build` creates an `AVMutableComposition` (insert and scale per time-map piece, audio mix with gains and loudness normalisation) plus an `AVMutableVideoComposition` whose custom compositor (`GlintCompositor`) calls `SceneRenderer.render(plan:screen:outputTime:)`. A `RenderPlan` is an immutable snapshot (document, map, cursor path, camera path, layout, background, cursor images, caption cache).

Each frame is drawn in this order:

1. background gradient or image (with dither noise against banding);
2. blurred rounded-rect shadow;
3. the screen through **one** source→output affine transform (camera × placement, so there's no double resampling), masked to rounded corners;
4. click ripples and the cursor (scaled with the camera);
5. captions, outside the camera, with word highlight and fades.

Fast camera moves get sub-frame motion blur: 4–12 tent-weighted samples, with alpha-only weights because Core Image colour matrices work on unpremultiplied values.

The same composition feeds `AVPlayer` in the app, `AVAssetReader` → `AVAssetWriter` for export (H.264/HEVC/ProRes) and `AVAssetImageGenerator` for frames, contact sheets and GIF (ImageIO, centisecond-exact delays).

Variants (`landscape`, `landscape-4k`, `square`, `portrait`, `gif`, `preview`) are size/codec presets plus *in-memory* style operations. They never modify the project.

## Planning and quality

- **`ZoomPlanner`:** clicks and typing bursts (anchored at the last click) are clustered in time and space. Each cluster becomes a zoom from 0.7 s before to 2.2 s after its actions. Neighbours within 2 s merge if they fit one view, otherwise they butt together so the camera pans. Scale adapts to the cluster's extent, and the final second is skipped.
- **`CutPlanner`:**
  - Mic silences (adaptive threshold) become cuts, or speed-ups when there's on-screen activity during them.
  - Without a voice track, idle stretches are sped up.
  - Silent typing gets a 2.5× speed-up.
  - Filler words from the transcript are cut.
  - Dead starts and ends are trimmed.
- **`CaptionBuilder`:** splits lines by character limit, sentence punctuation and pauses.
- **`SceneSegmenter`** (pure): clusters clicks, typing bursts and scrolls into scenes separated by input gaps (4 s), markers and app switches; merges scenes under 3 s and splits ones over 28 s; titles come from markers, click labels or OCR headings. Scenes tile the kept range so a narration line always has picture under it. **`SceneAnalyzer`** (GlintAnalysis) adds a frame per scene and its text via Vision OCR, on device.
- **`Narrator`** (GlintAnalysis): one Anthropic Messages call with every scene's frame and facts, a word budget per scene (2.5 words/s) and a JSON schema for the reply, so lines come back typed and timed. **`ElevenLabs`** synthesizes each line with the `with-timestamps` endpoint, so every word has a time (`previous_text`/`next_text` keep prosody continuous across scenes).
- **`NarrationFit`** (pure): retimes each narrated scene so the picture lasts as long as its clip plus a 0.45 s tail: idle stretches are slowed (down to 0.45×) or sped up (up to 3×) first, then the whole scene. Its speed segments are tagged `fit narration` and replaced on every re-fit, and it never overrides speeds a person set. Clips are anchored to a source instant but play at 1× on the output timeline; captions are derived from the clip words through the time map.
- **Mix:** `EditComposition` adds one audio track per clip at the clip's output time, applies `audio.voiceoverGain`, and ducks the recorded tracks with volume ramps (0.25 s down before a clip, 0.35 s up after; merged across touching clips). Export loudness normalisation measures the voiceover as its own group.
- **`EditQuality`** (no render needed) checks zoom coverage, short zooms, out/in "pumping", **cursor-in-view while zoomed** (sampled against the simulated camera), peak camera speed, dead air, jump fragments, caption reading speed and line length, and duration vs target. Each check has a verdict, a value, a threshold and a `fix` hint.
- **`RenderInspector`** checks the actual file: duration vs edit, resolution, codec, bitrate, black frames (dark *and* featureless), frozen stretches, sharpness (Laplacian variance), motion energy, and BS.1770 loudness and clipping.

## Surfaces

- **MCP** (`glint mcp`):
  - Supports initialize, tools/list (JSON schemas plus read-only/destructive hints), tools/call (text JSON + `structuredContent` + **image content** for frames and contact sheets), resources (workflow, operations, style, quality docs), prompts (`polish_recording`) and progress notifications.
  - Each request runs in its own task, so status calls answer during long renders.
  - The client name becomes the author (`agent:claude-code`).
  - Capture tools (`glint_list_sources`, `glint_record_*`) are forwarded to Glint.app over a user-only Unix socket (`CaptureBroker`/`CaptureHost`), so Screen Recording is Glint's permission rather than the agent host's. The app serves them with the same registry and approval store, and finalizes a take if the agent disconnects.
- **Agent setup** (`AgentSetup`, shared by the app's Agents panel and `glint connect`): Claude Code through `claude mcp add-json --scope user`, Codex by editing only `[mcp_servers.glint]` in `config.toml` (with a 900 s tool timeout), and Claude Desktop through `claude_desktop_config.json`, with backups, stale-path detection and a handshake self-test.
- **CLI:**
  - Friendly subcommands map onto the same tool handlers.
  - `glint call <tool> '<json>'` is exactly what an MCP client does, and `glint tools --markdown` generates [AGENTS.md](AGENTS.md).
- **App:**
  - Home has projects, a demo project, and an Agents panel (Connect/Connect All for Claude Code, Codex and Claude Desktop, Screen Recording status, and the command-line link). Settings has Agents and Narration (API keys) tabs.
  - Recording uses a source list or the system picker, with a floating HUD and a menu-bar extra.
  - The editor has a live preview, a sidebar with Style, Voice and Agent tabs, and a timeline. The Voice tab walks scenes → script → voice: each scene with its frame and an editable line, a brief for the writer, a voice picker with samples, and Generate. The timeline is in source time, with thumbnails, a waveform, speed bands, hatched cuts, draggable and resizable zoom chips, range selection → cut/zoom/speed, captions, and a Voice lane with draggable clips.
  - One accent colour (light blue), system fonts, no gradients or glows: lane colours are the only other hues and each means one thing.
  - The Chat tab runs Claude Code or Codex headless on the open project (`AgentChatRun`, `ChatParser`), streaming their messages and tool calls, with pending proposals under the conversation. The Activity tab shows proposals (preview/apply/reject), history with author badges and per-transaction revert, and approval banners.
  - The editor polls the bundle every 0.6 s, so CLI and MCP edits appear live with an attribution banner.
