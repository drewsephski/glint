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
- Single-clip timeline: no appending or importing extra clips, no B-roll, no music track. Voiceover clips exist but can't be imported from your own recordings yet (only synthesized from the script).
- Timeline: no drag handles for trim, captions or speed segments (set them precisely through ops or the inspector); no ripple editing on an output-time view; no keyframed manual camera paths.
- Captions: one line per segment and one font; no per-word timing edit UI; no SRT/VTT export yet (the transcript has the data).
- Audio: export loudness normalisation only (preview isn't normalised), capped by 3 dB peak headroom because there's no true-peak limiter (loud peaky voices land 1–2 dB under target); no noise reduction or voice enhancement. Ducking is fixed-shape (ramps and a level), not sidechain.
- Cursor: recorded images or Glint's arrow; no cursor packs, tilt or motion trails.

## Narration

- Scene detection is input-driven: an imported movie with no events falls back to fixed 12 s beats split at markers. Visual change detection (frame differencing) would do better there.
- The script writer sees one frame per scene. Scenes with several distinct states would benefit from two or three frames.
- ElevenLabs only (no Apple on-device voice or OpenAI TTS); one voice per project; no pronunciation dictionary, speed or emotion controls beyond `style.voice` stability/similarity.
- Fit-to-narration retimes the picture; it never shortens a line. When a scene can't stretch enough (minimum 0.45×), the note says so and the line should be trimmed by hand.
- No lip-sync or presenter-removal: a recording with a presenter's voice keeps it under the narration (ducked). Mute the microphone in Audio if the narration should stand alone.
- Narration is bring-your-own-key: each user adds their own Anthropic and ElevenLabs keys (Keychain). There is no hosted proxy, so the app can't offer narration without keys.

## Agents

- **Autonomous app exploration** (an agent that discovers a running app, plans a walkthrough and drives it) is not built in. Glint provides the primitives: capture, `glint_record_action`, markers, `pointer: "agent"`, proposals, renders and measurement. The e2e harness shows the pattern with a scripted driver.
- **Approvals are a cooperative-agent guard, not a security boundary**: any process running as the user can edit files in the support directory. The TTY requirement on `glint approve` and the absence of an approve tool prevent *well-behaved* agents from self-approving.
- MCP runs over stdio only (no HTTP transport), with no `listChanged` notifications and no resource subscriptions for live project state. Agents poll `glint_project_info`.
- No sharing or upload destinations yet. The only `external` actions are the two narration services.
- Render jobs are synchronous per call (progress notifications are sent). There's no job queue or cancel.

## Platform and engineering

- **macOS 26 minimum** (SpeechTranscriber, current SwiftUI). macOS 15 support would need `SFSpeechRecognizer` fallbacks.
- Preview rebuilds the composition on each committed edit (≈50–150 ms on short projects). Long recordings (> 30 min) are unprofiled; `CameraPath` and `CursorPath` are O(duration) arrays at 120 Hz.
- Development builds are ad-hoc signed (TCC permissions may reset across rebuilds). `scripts/release.sh` signs with a Developer ID and notarises when a notary profile is configured; there is no auto-update yet.
- UI is English only.
