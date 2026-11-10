# Testing and validation

Everything below ran on 2026-11-09 on macOS 26.5 (Apple silicon), Xcode 26.6 / Swift 6.3.3. Raw logs are in [`test-results/`](test-results/).

## November 2026 additions (`swift test`: 137 tests in 40 suites, all passing on 2026-11-10)

Run on 2026-11-10, same machine. `swift build` and `scripts/build-app.sh` succeed. No lint tool is configured: type checking is the Swift compiler (no new warnings; the earlier `ChatPanel.swift` capture warnings are unchanged), plus `git diff --check` and a trailing-whitespace scan of new files.

| Suite | What it proves |
|---|---|
| `ClipRemapSafetyTests` | Split masks/callouts/zoom/speed/captions retain every surviving source interval, insertion-boundary anchors follow their content, tiny mask fragments remain covered, custom caption text is preserved, undo/redo retains IDs |
| `MediaSafetyTests`, `MediaOrientationSafetyTests` | Invalid and excessive durations rejected before allocations; per-shot aspect focus; real rotation metadata preserved in preview and decoded MP4, including mask coordinates and mixed-orientation joins |
| `JobEvidenceSafetyTests`, `ProductionSafetyTests` | Concurrent job creation/claims, cancellation/retry, snapshot publication; quality failures survive retry; live edits and recipe changes cannot certify old renders; stale evidence and OCR are rejected, masks affect OCR, each output file is checked |
| `ClipModelTests` | Older `project.json` files without the new keys load with defaults and identical timing; inserting, moving, removing and splitting shots keeps zooms, cuts and caption words on their content; a trimmed tail stays trimmed after an append; scene replacement places manual items proportionally, drops auto items and never moves a redaction; invalid shots are rejected; events come from each shot's own take |
| `OverlayOperationTests` | Callout and redaction validation (geometry inside 0–1, time inside the program, minimum strength, required fields); `time_base: output` converts item times; presets merge and unknown sections are rejected; undo/redo and stale `expected_revision` cover the new items |
| `SubtitleTests` | SRT/VTT cues follow cuts and 2× speed on the output timeline, split at cuts, skip hidden captions and round-trip; malformed files are rejected; transcript cuts never clip neighbouring words |
| `AudioEnvelopeTests` | Music fades in/out and ducks to the set level under narration; looping fills the video |
| `RecipeEvidenceTests` | Recipe validation (stable unique IDs, no credentials) and versioning; a reported click or a vision opinion never verifies; verified needs an observed value; a later failure wins; missing evidence is needs review; evidence from a replaced take is stale; markers bind scenes |
| `JobStoreTests` | Idempotency keys (same job, or a conflict for different parameters); a running job whose process died reads as interrupted; repair plans only touch zooms and never cut |
| `ImportedShotPlanningTests` | An imported movie without input events is never sped up as "idle" |
| `CaptureTimelineTests`, `CaptureReliabilityTests` | Pause maths and event rebasing; window-frame normalization; old `events.json` still decodes. A screen movie and mic track written with the production writer settings, copied mid-write and abandoned unfinished, are both recovered into valid projects that render. A paused take is gapless with correctly retimed frames and audio. Preflight blocks hard failures. |
| `OverlayRenderTests` (rendered pixels) | A pixelated header can no longer be read by on-device OCR; a solid mask is exactly its colour in preview frames **and in the decoded exported MP4**; callout boxes and labels are drawn where expected and move with a 2× zoom; preview↔screen coordinates round-trip under zoom; a dip transition reaches black at its centre |
| `MultiShotTests` (rendered pixels) | Three shots (recording, an inserted 16:9 orange shot using part of its file, an appended blue shot) appear at the right output times with a cut applied, the 16:9 shot letterboxed, and the export's duration matching; a looping music bed and an imported voice mix into the export with audio present and nothing past the picture; exported subtitle cues match the built composition |
| `JobTests` | A render job cancelled mid-render leaves no file and no completed stage; retry renders from the job's snapshot despite later edits; an interrupted job resumes without redoing its finished stage (attempts and file times unchanged); a tampered artifact is re-rendered; a production job applies bounded, attributed repairs and ends needs review without a recipe |
| `RecipeWorkflowTests` | End to end with fixtures: save a recipe, bind shots from `scene:` markers, add manual edits, record evidence (a click stays needs review, OCR and an API assertion verify), record a changed take for one scene with its own evidence, refresh it, and check that the new take's pixels are in the edit, the other scene's manual zoom moved exactly with its content, the take's events drive that shot, old-take evidence stopped counting, and one undo restores the original |
| `ProductionToolTests` | The 65 tools have unique names and object schemas, and the operation schema lists every op; MCP calls with the agent author and a revision guard; autopilot reports needs_review without a recipe, failed when asked-for captions are impossible, and refuses a stale revision; transcript and subtitle tools round-trip |

Live capture checks run by the capture agent on this Mac (recording only its own test window, scratch `GLINT_HOME`): `glint pause`/`resume` from another process removed a 2.6 s pause from a real take; a moved window was logged; a `glint record` killed with SIGKILL was rebuilt by `glint recover` to 6.0 s with system audio and renders.

**Not exercised:** the new app drag, draw and click interactions (built and screenshotted; this Mac doesn't let the build host send input to the app); a camera unplugged mid-take, the screen capture dying on its own, and the disk filling during a take.

## Automated suite: `swift test` (37 tests, 10 suites, all passing, 2026-11-09)

| Suite | What it proves |
|---|---|
| `JSONPatchTests` | Diff/apply/inverse round-trips; identity-aware array diffs are minimal; `verify` detects conflicts |
| `TimeMapTests` | Source↔output mapping with cuts, speed and trim |
| `EngineTests` | Apply → undo → redo; stale `expected_revision` rejected; selective revert keeps later edits, and is itself undoable; conflicting revert reported; `time_base: output`; style validation (unknown paths and wrong types rejected, hex colours accepted); proposals (validated up front, applied once, recorded); history attribution |
| `PlannerTests` | Click clustering; far-apart neighbours butt together (no zoom pumping); cut clicks ignored; silence → cut vs activity → speed-up; filler removal that never clips neighbouring words; caption segmentation and non-overlap |
| `MotionTests` | Smoothed cursor passes within 0.002 of the exact click point at full smoothing; camera path deterministic, reaches scale, settles back, stays over the screen |
| `ApprovalTests` | Agent capture needs approval; duplicate requests reused; approvals bound to exact parameters and single-use; reversible agent edits and user capture pass |
| `QualityTests` | Pumping and dead air detected |
| `NarrationTests` | Scenes follow clicks, typing and markers and tile the kept range (a marker starts a scene exactly); cut clicks and trims are respected; fit stretches a scene to a longer line by slowing its idle stretches (never the typing) and compresses a scene with a shorter one, and re-planning replaces the earlier fit; clip word timings map to source time through speed changes; voiceover operations validate (duplicate id, gain range, start outside the recording), undo exactly, and count as speech for the dead-air check |
| `PipelineTests` (real AVFoundation/Core Image, synthetic media) | **Zoom magnifies the clicked control**: the red "Save" button's pixel area grows ≥ 2.5× in the rendered zoomed frame. **Export duration and resolution match the edit**, with no black frames. **Preview == export**: frames from the live composition and the decoded MP4 differ by < 3% mean absolute error at 3 timestamps. Portrait 360×640 and GIF variants render. Silence detection and BS.1770 loudness on generated signals. **Autopilot with a real spoken voice** (`say`) produces zooms, cut plans and a render whose duration check passes, as separate transactions attributed to the agent. **Narrated demo** (system-voice clips, storyboard, fit, captions): one audio track per clip in the composition, an audio mix with ducking, every clip ends before the picture does, the exported file carries one mixed audio track and matches the edit's duration. |
| `MCPTests` (in-process JSON-RPC) | Handshake, tool list (including the narration tools), schemas and hints; full agent loop: plan → proposal → `render_frame` returns an **image block** → quality → apply → stale revision is a tool error → undo → history attributed to `agent:<client>`; **gated actions**: agent `record_start` and `delete_project` return `approval_required`, nothing happens, there's no approve tool, and the identical call succeeds once after a human approves |

## Real recordings

### 1. Display smoke test (ScreenCaptureKit, real cursor)

`glint record --display 3 --duration 4` while a helper moved the real cursor:

- **Video:** HEVC 1920×1080, 226 frames in 4.018 s (variable frame rate: ScreenCaptureKit skips unchanged frames), plus a system audio track.
- **Events:** 291 pointer samples, 2 distinct cursor images (arrow, I-beam) with hotspots, 1 real click, and frontmost-app changes, all captured with **no Accessibility or Input Monitoring permission**.
- **Render:** auto zoom + landscape 1080p60 rendered in 2.4 s. Duration 4.03 s vs edit 4.02 s.
- **Bugs this found and fixed:**
  - Motion-blur and fade weights darkened frames, because Core Image colour matrices work on unpremultiplied values.
  - The black-frame check flagged a dark-mode UI. It now requires dark *and* featureless.
- **Observed platform behaviour:** macOS showed a "bypass the system private window picker" prompt for the host terminal app. This led to adding the `SCContentSharingPicker` path in the app.

### 2. End-to-end agent walkthrough (`scripts/e2e/agent_walkthrough.py`)

An "agent" (Python, MCP over stdio) records a **real AppKit app window** (`AcmeNotes`). The app's scripted tour glides the real system cursor to each control and actuates it; the agent relays each action with `glint_record_action`.

| Stage | Result (latest run, log in `test-results/e2e-agent-walkthrough.log`) |
|---|---|
| Capture | window 1200×792, 16.2 s; 4 labelled clicks (New Note 2.77 s, Title 4.33 s, Body 6.84 s, Publish 13.88 s), 71 keystrokes, 2 markers, ~345 pointer samples |
| Autopilot | 2 speed-ups (typing), 2 zooms, start/end trimmed → 10.07 s output |
| Edit quality | 94/100. Cursor in view 97% of zoomed frames, peak camera speed ~1.5 canvas/s, no pumping, no dead air; *warn*: ~91% zoom coverage (an accurate observation for a constantly active demo) |
| Landscape 1920×1080 | 10.08 s vs edit 10.07 s, H.264, rendered in 4.6 s, **100/100** |
| Portrait 1080×1920 | 10.08 s, follows the cursor (base scale 1.75), rendered in 4.3 s, **100/100** |
| GIF 960×540 | 10.08 s, 144 frames, **100/100**. The first run measured 10.57 s because of centisecond delay rounding; frames are now stepped in whole centiseconds. |

The contact sheet ([`images/e2e-contact-sheet.jpg`](images/e2e-contact-sheet.jpg)) shows the camera easing onto New Note, following to the Title field (with the recorded I-beam cursor), panning across the body while typing, travelling to Publish, then pulling back to the full window on the gradient.

### 3. On-device transcription

Apple `SpeechTranscriber` transcribed the synthetic narration word-for-word, with timings ("Here is our quarterly dashboard." / "First, I save the report." / "Um, now let's search for enterprise…"). The cut planner removes the "Um", and captions render with the active word highlighted ([`images/frame-captions.png`](images/frame-captions.png)).

Reviewing that real output turned up a bug: the recogniser had stretched the "Um," token over the 1.4 s pause before it, and the first filler cut also clipped 40 ms of the next word. Filler cuts now never reach into neighbouring words and cover at most the last 0.6 s of the token; the pause is left to the silence planner. A regression test covers this (`fillerCutsNeverClipNeighbouringWords`).

### 4. Loudness: cross-checked against ffmpeg

Rendering the voiced demo: Glint's inspector reported **−17.2 LUFS integrated, −3.3 dBFS peak**, identical to ffmpeg's independent `ebur128` meter (−17.2 LUFS, −3.3 dBFS).

Getting there exposed three bugs, all now fixed:

1. Normalisation silently skipped documents saved before the setting existed. A `Double?` with a default decodes as `nil`. Settings are now non-optional, and `readDocument` merges missing keys from defaults.
2. A mono voice played on stereo channels is +3 dB louder by BS.1770; normalisation now compensates.
3. The inspector measured a mono downmix, which overstates peaks for correlated channels. It now uses per-channel true sample peaks and per-channel loudness.

The result sits 1.2 dB under the −16 target because a 3 dB peak-headroom cap applies; there's no true-peak limiter yet.

### 5. App

`build/Glint.app` was launched on real projects and captured with `screencapture -l` ([`images/`](images/)). Verified:

- Editor preview, inspector, timeline (thumbnails, waveform, speed band, hatched cut, zoom capsule, captions).
- While the app was open, CLI "agent" edits appeared live with an attribution banner; a proposal showed with its rationale; an agent's destructive request appeared as an Approve/Deny banner and the CLI exited with code 3.
- **Bugs found and fixed:**
  - A crash from an invalid waveform sample rate. Audio decoding now clamps the rate instead of letting AVFoundation throw.
  - No window was created when launched with a file argument. Opened files now go through `onOpenURL`.

## Not covered by automated or real tests

- The `SCContentSharingPicker` flow and the app's interactive drag gestures need a person to click; they're exercised only by compiling and by code review.
- Microphone capture: it's implemented through `captureMicrophone`, but no mic recording was made here, so as not to capture the room.
- Accessibility click labels (`AXUIElementCopyElementAtPosition`): Accessibility isn't granted on this machine.
- Long recordings (> 5 min) were not profiled.
