# Architecture

Glint is a native macOS screen recorder and editor whose every capability sits behind one shared project engine. The SwiftUI app, the `glint` CLI and the MCP server are three thin surfaces over the same code. They work on the same files, and can do so at the same time.

```
                 ┌────────────── surfaces ──────────────┐
  SwiftUI app (GlintApp)      glint CLI (glint)        MCP server (glint mcp, stdio)
         │                          │  (ArgumentParser)        │ (JSON-RPC 2.0)
         └──────────────┬───────────┴──────────┬───────────────┘
                        ▼                      ▼
              GlintAgent: GlintService  ·  ToolRegistry (34 tools, risk-classed)  ·  Autopilot  ·  Docs
                        │
      ┌─────────────────┼──────────────────┬───────────────────────┐
      ▼                 ▼                  ▼                       ▼
  GlintCore         GlintCapture        GlintRender            GlintAnalysis
  (pure Swift)      ScreenCaptureKit    Core Image/Metal        SpeechTranscriber,
  document, ops,    + AVAssetWriter,    compositor, AVFoundation  loudness/silence,
  engine/history,   input tracking,     composition, export,     render inspection
  proposals,        cursor images       frames, GIF
  approvals, time
  map, motion,
  planners, quality
```

Dependencies point inward. GlintCore imports nothing but Foundation, so all edit logic, planning, motion and quality checking is deterministic and unit-testable without media.

## The project bundle

A project is a folder package `Name.glint/` (UTI `dev.glint.project`):

| Path | Contents |
|---|---|
| `project.json` | `ProjectDocument`: media info, recording info, `timeline` (in/out, cuts, speeds, zooms, captions, markers), `style` (background, frame, cursor, zoom/camera, captions, audio, canvas), and a `revision` counter |
| `events.json` | `EventLog`: pointer samples (~120 Hz), clicks (with accessibility labels when available), key-down instants (no characters unless opted in), scrolls, frontmost-app changes, cursor-image changes, markers |
| `transcript.json` | Word-timed transcript |
| `history.jsonl` | Append-only transactions |
| `proposals/*.json` | Pending, applied or rejected proposals |
| `media/` | `screen.mov` (HEVC), `mic.m4a`, `system.m4a`. **Never modified by editing.** |
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
- **`EditQuality`** (no render needed) checks zoom coverage, short zooms, out/in "pumping", **cursor-in-view while zoomed** (sampled against the simulated camera), peak camera speed, dead air, jump fragments, caption reading speed and line length, and duration vs target. Each check has a verdict, a value, a threshold and a `fix` hint.
- **`RenderInspector`** checks the actual file: duration vs edit, resolution, codec, bitrate, black frames (dark *and* featureless), frozen stretches, sharpness (Laplacian variance), motion energy, and BS.1770 loudness and clipping.

## Surfaces

- **MCP** (`glint mcp`):
  - Supports initialize, tools/list (JSON schemas plus read-only/destructive hints), tools/call (text JSON + `structuredContent` + **image content** for frames and contact sheets), resources (workflow, operations, style, quality docs), prompts (`polish_recording`) and progress notifications.
  - Each request runs in its own task, so status calls answer during long renders.
  - The client name becomes the author (`agent:claude-code`).
- **CLI:**
  - Friendly subcommands map onto the same tool handlers.
  - `glint call <tool> '<json>'` is exactly what an MCP client does, and `glint tools --markdown` generates [AGENTS.md](AGENTS.md).
- **App:**
  - Home has projects, an agent-connect card and a demo project.
  - Recording uses a source list or the system picker, with a floating HUD and a menu-bar extra.
  - The editor has a live preview, an inspector and a timeline. The timeline is in source time, with thumbnails, a waveform, speed bands, hatched cuts, draggable and resizable zoom capsules, range selection → cut/zoom/speed, and captions.
  - The agent panel shows proposals (preview/apply/reject), history with author badges and per-transaction revert, and approval banners.
  - The editor polls the bundle every 0.6 s, so CLI and MCP edits appear live with an attribution banner.
