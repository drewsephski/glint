# Known gaps and next steps

Honest status of what's missing or partial, roughly in priority order.

## Recording

- **Crash safety** is implemented (2 s movie fragments, a journal and an events checkpoint, recovery from Home or `glint recover`). Up to about the last 2 s before a crash can be lost. A camera unplugged mid-take and the disk filling during a take were not reproduced on hardware.
- **Facecam**: the camera records to its own track and is drawn as a bubble (circle, square or wide) in a corner, styled under `style.facecam`. Not done yet: dragging the bubble on the preview or placing it freely, hiding or resizing it over a time range, full-screen and side-by-side camera layouts, background blur or removal, face-aware framing, and showing the live bubble when the content was chosen in the system picker (Glint's windows can't be reliably left out of that capture). Camera capture is untested against a real device in CI: tests use a drawn camera track.
- **Keystroke overlay**: Glint records keystroke *timing* only, which is permission-free and private by design. Showing pressed keys needs an Input Monitoring event-tap mode (opt-in) plus rendering.
- **Window capture** follows a moved window when the window ID is known. Takes started from the system picker can't, because the picker doesn't report which window was chosen.
- **Accessibility click labels** are implemented but untested here (permission not granted). The agent path (`glint_record_action` with `label`) covers automation.
- **The macOS "bypass private picker" prompt** appears for direct `SCShareableContent` capture. Agent capture now runs in Glint.app (forwarded by `glint mcp`), so the prompt names Glint rather than the agent's host; the app's own flow offers the system picker. With `GLINT_CAPTURE=local`, or when the app can't be reached, capture falls back to the hosting process and its permission state.
- **Agent setup** covers Claude Code, Codex and Claude Desktop. Other MCP clients (Cursor, Windsurf, VS Code, Zed) get copy-paste JSON rather than a Connect button.
- **Pause/resume** works across all tracks. Pauses and warnings are kept in `events.json` and `recording.json`, not in `project.json`.

## Editing

- Callouts, privacy masks, dip transitions, shots, music and imported voiceover are implemented (see [ENHANCEMENTS.md](ENHANCEMENTS.md)). Still missing: crossfades between shots (one picture track), picture-in-picture B-roll, device frames, automatic detection of sensitive content.
- Imported shots: no transcription of their audio, no facecam (only the original recording's camera), no cursor unless the shot is a Glint take with input events.
- Timeline: no ripple editing on an output-time view; no keyframed manual camera paths. The new drag interactions were built and screenshotted but not driven by UI automation.
- Captions: one line per segment; no per-word timing edit UI (moving a caption spreads its words evenly).
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

- **Autonomous app exploration** (an agent that discovers a running app, plans a walkthrough and drives it) is not built in. Glint provides the primitives: capture, `glint_record_action`, markers, recipes with stable scene IDs, evidence, scene refresh, proposals, jobs, renders and measurement. The e2e harness shows the pattern with a scripted driver.
- **Evidence Glint checks itself** is on-screen text only (OCR on a scene's last frame). State outcomes need an assertion from the driver or a person; OCR misses become "needs review", not "failed".
- **Approvals are a cooperative-agent guard, not a security boundary**: any process running as the user can edit files in the support directory. The TTY requirement on `glint approve` and the absence of an approve tool prevent *well-behaved* agents from self-approving.
- MCP runs over stdio only (no HTTP transport), with no `listChanged` notifications and no resource subscriptions for live project state. Agents poll `glint_project_info`.
- No sharing or upload destinations yet. The only `external` actions are the two narration services.
- Durable jobs run in the process that started them (the MCP server, the app, or a waiting CLI). There's no separate job daemon: a job whose process exits shows `interrupted` and is resumed with `glint_job_retry`. Automatic repair covers only the deterministic fixes listed in the quality docs.

## Platform and engineering

- **macOS 26 minimum** (SpeechTranscriber, current SwiftUI). macOS 15 support would need `SFSpeechRecognizer` fallbacks.
- Preview rebuilds the composition on each committed edit (≈50–150 ms on short projects). Long recordings (> 30 min) are unprofiled; `CameraPath` and `CursorPath` are O(duration) arrays at 120 Hz.
- Development builds are ad-hoc signed (TCC permissions may reset across rebuilds). `scripts/release.sh` signs with a Developer ID and notarises when a notary profile is configured; there is no auto-update yet.
- UI is English only.
