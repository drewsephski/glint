# Known gaps and next steps

Honest status of what's missing or partial, roughly in priority order.

## Recording

- **Crash safety.** Writers produce one file per track; if the process dies mid-take the movie isn't finalised. Next step: segmented fragmented-MP4 writers with recovery on launch (both Screen Studio and reelbird do this).
- **Camera (webcam)**: capture, picture-in-picture bubble and camera layouts are not implemented.
- **Keystroke overlay**: Glint records keystroke *timing* only, which is permission-free and private by design. Showing pressed keys needs an Input Monitoring event-tap mode (opt-in) plus rendering.
- **Window capture** maps input with the window's frame at start; a window moved during recording misaligns cursor coordinates. Next step: track the window frame over time.
- **Accessibility click labels** are implemented but untested here (permission not granted). The agent path (`glint_record_action` with `label`) covers automation.
- **The macOS "bypass private picker" prompt** appears for direct `SCShareableContent` capture by the hosting process (e.g. a terminal running an agent). The app's user flow offers the system picker; agent capture inherits the host's permission state.
- **Pause/resume** within a take isn't supported.

## Editing

- No annotations (arrows, boxes, text), blur/redaction masks, device frames, or transitions.
- Single-clip timeline: no appending or importing extra clips, no B-roll, no music or voice-over tracks.
- Timeline: no drag handles for trim, captions or speed segments (set them precisely through ops or the inspector); no ripple editing on an output-time view; no keyframed manual camera paths.
- Captions: one line per segment and one font; no per-word timing edit UI; no SRT/VTT export yet (the transcript has the data).
- Audio: export loudness normalisation only (preview isn't normalised), capped by 3 dB peak headroom because there's no true-peak limiter (loud peaky voices land 1–2 dB under target); no noise reduction or voice enhancement; no ducking.
- Cursor: recorded images or Glint's arrow; no cursor packs, tilt or motion trails.

## Agents

- **Autonomous app exploration** (an agent that discovers a running app, plans a walkthrough and drives it) is not built in. Glint provides the primitives: capture, `glint_record_action`, markers, `pointer: "agent"`, proposals, renders and measurement. The e2e harness shows the pattern with a scripted driver.
- **Approvals are a cooperative-agent guard, not a security boundary**: any process running as the user can edit files in the support directory. The TTY requirement on `glint approve` and the absence of an approve tool prevent *well-behaved* agents from self-approving.
- MCP runs over stdio only (no HTTP transport), with no `listChanged` notifications and no resource subscriptions for live project state. Agents poll `glint_project_info`.
- No external sharing or upload yet (the `external` risk class and policy exist for it).
- Render jobs are synchronous per call (progress notifications are sent). There's no job queue or cancel.

## Platform and engineering

- **macOS 26 minimum** (SpeechTranscriber, current SwiftUI). macOS 15 support would need `SFSpeechRecognizer` fallbacks.
- Preview rebuilds the composition on each committed edit (≈50–150 ms on short projects). Long recordings (> 30 min) are unprofiled; `CameraPath` and `CursorPath` are O(duration) arrays at 120 Hz.
- Ad-hoc code signing: not notarised; TCC permissions may reset across rebuilds.
- UI is English only.
