# Testing and validation

Everything below ran on 2026-11-09 on macOS 26.5 (Apple silicon), Xcode 26.6 / Swift 6.3.3. Raw logs are in [`test-results/`](test-results/).

## Automated suite: `swift test` (31 tests, 9 suites, all passing)

| Suite | What it proves |
|---|---|
| `JSONPatchTests` | Diff/apply/inverse round-trips; identity-aware array diffs are minimal; `verify` detects conflicts |
| `TimeMapTests` | Source↔output mapping with cuts, speed and trim |
| `EngineTests` | Apply → undo → redo; stale `expected_revision` rejected; selective revert keeps later edits, and is itself undoable; conflicting revert reported; `time_base: output`; style validation (unknown paths and wrong types rejected, hex colours accepted); proposals (validated up front, applied once, recorded); history attribution |
| `PlannerTests` | Click clustering; far-apart neighbours butt together (no zoom pumping); cut clicks ignored; silence → cut vs activity → speed-up; filler removal that never clips neighbouring words; caption segmentation and non-overlap |
| `MotionTests` | Smoothed cursor passes within 0.002 of the exact click point at full smoothing; camera path deterministic, reaches scale, settles back, stays over the screen |
| `ApprovalTests` | Agent capture needs approval; duplicate requests reused; approvals bound to exact parameters and single-use; reversible agent edits and user capture pass |
| `QualityTests` | Pumping and dead air detected |
| `PipelineTests` (real AVFoundation/Core Image, synthetic media) | **Zoom magnifies the clicked control**: the red "Save" button's pixel area grows ≥ 2.5× in the rendered zoomed frame. **Export duration and resolution match the edit**, with no black frames. **Preview == export**: frames from the live composition and the decoded MP4 differ by < 3% mean absolute error at 3 timestamps. Portrait 360×640 and GIF variants render. Silence detection and BS.1770 loudness on generated signals. **Autopilot with a real spoken voice** (`say`) produces zooms, cut plans and a render whose duration check passes, as separate transactions attributed to the agent. |
| `MCPTests` (in-process JSON-RPC) | Handshake, tool list, schemas and hints; full agent loop: plan → proposal → `render_frame` returns an **image block** → quality → apply → stale revision is a tool error → undo → history attributed to `agent:<client>`; **gated actions**: agent `record_start` and `delete_project` return `approval_required`, nothing happens, there's no approve tool, and the identical call succeeds once after a human approves |

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
