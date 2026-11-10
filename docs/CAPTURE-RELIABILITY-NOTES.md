# Capture reliability: implementation notes

Notes for whoever updates ARCHITECTURE.md, GAPS.md, AGENTS.md and the site. Everything below is implemented and tested; the "Verified" section says exactly how.

## What changed

### Pause/resume within a take
- One `PauseClock` (GlintCapture) per take, shared by the screen and audio writers (`ScreenRecorder`), the camera (`CameraRecorder`) and the input tracker. The pure time maths is `PauseTimeline` in `GlintCore/CaptureTimeline.swift`.
- Samples stamped (host clock) inside a pause are dropped. Later samples are restamped earlier by the time paused before them (`CMSampleBufferCreateCopyWithNewTiming`), so `screen.mov`, `mic.m4a`, `system.m4a` and `camera.mov` are gapless and stay in sync. Across a cut, an audio buffer that would overlap the previous one is dropped (at most ~21 ms of audio).
- On resume, the newest screen frame seen during the pause is placed at the cut, so the take resumes on the current screen even if nothing changes afterwards.
- Input: clicks, keys, scrolls and pointer samples made while paused are dropped. App focus, cursor image, window frame and markers made while paused move to the cut. Each pause's last pointer position is kept at the cut (`EventLog.rebased`).
- `events.json` gains an optional `pauses: [{at, duration}]`: `at` is in recording time, where the cut is.
- Elapsed time and `max_duration` exclude paused time. Stopping while paused ends the take at the cut.

### Crash safety and recovery
- Every capture writer (`TrackWriter`) sets `movieFragmentInterval = 2 s`, so an interrupted file stays readable up to its last fragment. Fragments are cut by media time, not wall-clock time (measured).
- `recording.json` in the bundle (`RecordingJournal`) records status, pid plus the process start time (so a reused PID isn't mistaken for a live recorder), options, planned media, pauses, warnings and elapsed time. It is written at start, on pause/resume and on each warning, and refreshed every 2 s along with `events.checkpoint.json`. Both writes are atomic.
- On a normal stop the journal becomes `finalized` and stays in the bundle as the take's capture record (pauses, warnings). The checkpoint file is removed. If finalizing fails, the status becomes `interrupted`.
- `GlintService.recoverableRecordings(in:includeStale:)` returns unfinished journals whose owner is dead (or whose status is `interrupted`). It scans the projects folder and the session registry: registry entries of dead processes are moved to `<support>/sessions/stale/`, so takes recorded outside the projects folder are found too.
- `GlintService.recover(_:)` probes each partial file with AVFoundation (track time range and duration), writes `project.json` (keeping the placeholder's id and createdAt) and `events.json` from the checkpoint clipped to the screen duration, and marks the journal `recovered` with plain-language `notes`. Media files are never rewritten.
- `discardRecording` moves the take to the Trash through `deleteProject`, so it is destructive and needs approval (the person's confirmation in the app or CLI counts as approval).
- The app hides interrupted takes from the project grid and lists them in a banner on Home.

### Preflight
- `GlintService.preflight(_:) -> PreflightReport` checks Screen Recording permission (`CGPreflightScreenCaptureAccess`), that the display or window exists, microphone and camera authorization and device (only when asked for), write access to the projects folder (a probe file), and free disk space. Disk space uses `volumeAvailableCapacityForImportantUsage` against an estimate of video bitrate (same formula as the writer) plus audio bitrates (plus about 7 Mbps for the camera) plus 10 % overhead, with 500 MB headroom.
- With `max_duration` the whole take must fit (fail), and fitting with less than 2× margin warns. Without it, less than 2 minutes of room fails and less than 15 minutes warns.
- The estimate uses the target average bitrate, so it errs high: screen content usually encodes well below it.
- `startRecording` runs preflight before the approval gate and throws `ServiceError` "Can't start recording: • <check>: <detail> Fix: …" on any fail. Warnings don't block.
- `RecordingSession` also checks devices before creating the bundle. A denied microphone throws the new `CaptureError.microphoneDenied`. A missing camera ID throws `cameraNotFound`, which now lists the cameras that are available.

### Window recordings follow the window
- For window capture (`window_id`), `InputTracker` polls the window's bounds (`CGWindowListCopyWindowInfo`, which needs no permission) at 10 Hz, and every tick (120 Hz) while the left button is held, because that's when windows get dragged. Pointer, click and scroll positions are normalized against the frame at that instant.
- Frame changes go into the optional `events.json` `windowFrames: [{t, x, y, width, height}]` (global points, top-left origin). A window that closes produces a warning.
- Pure helpers: `CaptureGeometry.normalize(x:y:at:samples:initial:)`.

### Device problems mid-take
- Camera unplugged (`AVCaptureDevice.wasDisconnectedNotification`), interrupted, or a session runtime error: the take continues. A runtime error gets one automatic restart. The camera movie keeps its last picture to the end, and a warning gives the take time.
- An audio track that stops writing gives a warning. The take goes on.
- `SCStream didStopWithError`, or the screen movie stops writing: the take is finalized with what exists. `endReason` becomes `capture_error`, and the error is in `glint_record_status` (`last_finished.error`), in the stop result and in the app's alert. A stop from the macOS screen-sharing menu (`SCStreamError.userStopped`) counts as a normal stop.
- Warnings appear in `glint_record_status` (live), the `glint_record_stop` result, the journal and the app's alert after stopping.

## New and changed tools (MCP and `glint call`)

| Tool | Risk | Args | Notes |
|---|---|---|---|
| `glint_record_pause` | reversible | `session_id?` | Forwarded to Glint.app. Returns the status plus `already_paused`. Pausing an already paused take does nothing. |
| `glint_record_resume` | reversible | `session_id?` | Forwarded. Returns the status plus `was_paused`. |
| `glint_record_preflight` | read | `display_id?`, `window_id?`, `microphone?`, `system_audio?` (true), `camera?`, `camera_id?`, `max_duration?`, `directory?` | Forwarded, and can open the app, because the permission it checks is the app's. Returns `{ok, checks:[{id,title,verdict,detail,fix?}], estimatedBytesPerMinute, estimatedBytes?, freeBytes?}`. Check ids: `screen_recording`, `source`, `microphone`, `camera`, `folder`, `disk`. |
| `glint_recover_recordings` | reversible | `action?` (`list` default, `recover`, `discard`), `project?`, `approval_id?` | Runs in the MCP process. `recover` without `project` recovers all of them. `discard` needs approval. |
| `glint_record_status` (changed) | read | `session_id?` | Adds `paused`, `pauses`, `warnings`, `error`, `endReason` (live). `last_finished` gains `warnings`, `pauses`, `end_reason`, `error` and `recoverable`. |
| `glint_record_stop` (changed) | reversible | `session_id?` | Adds `warnings`, `pauses?` and `error?` to the summary. A take whose finalizing failed is now reported as an error naming the recovery tool, not as `already_stopped`. |
| `glint_record_start` (changed) | capture | unchanged | Runs preflight first and refuses on a fail. |

`CaptureBroker.forwardedTools` now includes `glint_record_pause`, `glint_record_resume` and `glint_record_preflight`. `glint_record_preflight` is also an opening tool. The registry has 4 more tools than before.

## CLI

- `glint pause [--session ID] [--json]` and `glint resume [--session ID] [--json]` control a take in another process: Glint.app, a `glint record` in another terminal, or `glint mcp` with `GLINT_CAPTURE=local`. The request is written to `<support>/sessions/<id>.control` and the host is woken with SIGUSR1. Only hosts that advertise `control` in their registry entry are ever signalled, so an older Glint is never killed by the default SIGUSR1 action. The command confirms by reading the take's journal (3 s timeout).
- `glint preflight [--display N|--window N] [--mic] [--no-system-audio] [--camera] [--camera-id ID] [-d SECONDS] [--dir PATH] [--json]` checks this process's permissions (as `glint record` uses) and exits 1 on a fail.
- `glint recover` lists interrupted takes. `glint recover <path|name>` or `glint recover --all` rebuilds them. `glint recover <path> --discard` asks y/N at a TTY; agents need `--approval`.

## App

- Recording HUD: a Pause/Resume button, a "Paused" state, and elapsed time that excludes pauses. The HUD is now 268 pt wide.
- Menu bar: a "Pause Recording" / "Resume Recording" item. This is the one-line edit in `GlintApp.swift`.
- After a take: warnings, or the capture error, appear in the Glint alert. Stop now ends the app's own session by ID, even when an agent is recording in the app too.
- New Recording sheet: preflight runs whenever the source or a switch changes. Failures and warnings are listed with their fixes, and Record is disabled while any check fails (the System picker stays available). When all is well, a one-line disk estimate is shown.
- Home: an "Interrupted recordings" banner (`RecoveryView.swift`) with Recover, Discard… (with a confirmation dialog, moves the take to the Trash) and Show in Finder.

## Verified

- `swift test`: 111 tests pass in the final run (67 at my baseline; other agents also added tests in this period). My new tests:
  - `Tests/GlintCoreTests/CaptureTimelineTests.swift`: pause timeline maths, event rebasing across pauses, clipping, window-frame normalization, decoding old `events.json` without the new fields, the journal round-trip and recoverability rules, and the disk verdicts.
  - `Tests/GlintMediaTests/CaptureReliabilityTests.swift`:
    - `interruptedTakeIsRecoveredFromFragments`: records a HEVC screen movie and an AAC mic track through `TrackWriter` with the production settings, synthetic frames and host-clock timestamps. It copies the files mid-write (the writers are still `.writing`) and later abandons the writers without `finishWriting`. Both copies are recovered: the mid-write copy gives 4.0 s (a note says 1.2 s was lost) and the abandoned file gives 8.0 s. It checks the project document, that events are clipped (later clicks and markers dropped), the journal status and notes, the summary, and a frame rendered from the partial movie through the real render path. Liveness is checked with a reaped PID (dead), a reused PID (the parent's PID with the wrong start time, treated as dead) and a live owner (not offered, and `recover` refuses).
    - `pausedSamplesAreDroppedAndLaterOnesRetimed`: 6 s of frames and audio with a 2 s pause through `PauseClock` and `TrackWriter`. Result: a 4.0 s movie with 120 evenly spaced frames, the frame at the cut is the one taken at 4 s (checked by pixel value), and the audio is 4.01 s.
    - `preflightReportsAndBlocksHardFailures`: covers an unwritable folder and a missing camera, and shows `startRecording` refusing before any capture.
    - `pauseAndResumeNeedALiveTake`.
- Live run on this Mac, on real ScreenCaptureKit capture of my own test window. I used a scratch `GLINT_HOME` with a capture-allow policy; the scripts are in my scratchpad and were not committed.
  - `glint record --window` was paused with `glint pause` from another process and continued with `glint resume`. The window was moved during the pause and again after it, and the take was stopped with Ctrl-C.
  - Result: 6.7 s saved out of about 9.4 s of wall time. `events.json` has `pauses: [{at: 2.61, duration: 2.62}]` and `windowFrames` entries at 0, 2.61 (the move during the pause, placed at the cut) and 4.78 s. The journal is `finalized`.
  - Frames rendered on either side of the cut show the test window's counter going from 156 to 243 in 0.3 s of output. That is the ≈79-tick paused stretch removed.
  - Second run: `glint record` was SIGKILLed after 7 s. `glint recover` listed the take (6.07 s at the last checkpoint) and `glint recover --all` rebuilt it: 6.0 s of screen video plus the system-audio track. The result renders.

## Limitations and not exercised

- I couldn't exercise these here: camera disconnects and runtime errors on a real device, `SCStream didStopWithError` (for example a display unplugged mid-take), disk-full during writing, and the microphone permission prompt. The code paths compile and follow the documented APIs; the camera path in CI still uses a drawn track.
- The app UI (HUD, menu item, sheet preflight, recovery banner) compiles but I didn't screenshot it.
- Window tracking needs the window ID, so takes started from the system picker (`SCContentSharingPicker`) don't follow a moved window. A resized window is normalized against its new frame, which is exact only if ScreenCaptureKit scales the window content to fill the fixed output size.
- At most the last ~2 s before a crash can be lost: media is fragmented every 2 s of media time and events are checkpointed every 2 s.
- A frozen or hung recorder whose process is still alive isn't offered for recovery. Only dead owners and failed finalizes are.
- I didn't add a subprocess SIGKILL test to `swift test`: nothing there builds the `glint` executable for tests to rely on. The SIGKILL case was run live instead (above), and the abandoned-writer test is the in-process equivalent.
- I didn't touch `RecordingInfo` (Model.swift). Pauses live in `events.json` and in the journal; warnings live in the journal, the status and the stop results. If you want them in `project.json`, add optional `pauses`/`warnings` to `RecordingInfo` and fill them in `RecordingSession.finalize`.

## Docs that are now stale

- GAPS.md Recording: "Crash safety", "Window capture maps input with the window's frame at start" and "Pause/resume within a take isn't supported".
- ARCHITECTURE.md: the tool count (capture adds 4; with the other agents' tools `glint tools` lists 65 at the time of writing), the Capture section (clock, pause, journal, fragments, window tracking) and the bundle table (`recording.json`, `events.checkpoint.json`, and the `windowFrames`/`pauses` fields in `events.json`).
- AGENTS.md: regenerate with `glint tools --markdown`.
