# Production enhancements (November 2026)

This records the audit behind this round of work, every enhancement that was selected, what "done" means for each, and the evidence it is done. It covers main after commit `02a235c`. **None of this is in the public 0.4.0 release.** It ships when a new release is cut.

Status key: **Done**: implemented, reachable from the app and from CLI/MCP where it applies, and tested as stated. **Done, untested by input**: built and screenshotted, but the drag and click interactions were not driven by a person or by UI automation. This Mac doesn't grant Accessibility to the build host, so nothing could send input to the app. **Not done**: out of scope, with the reason.

## Audit (before this work)

Read: README, ARCHITECTURE, AGENTS, GAPS, TESTING, `competitor-profiles/` and the sources. Main findings:

| Area | Finding | Consequence |
|---|---|---|
| Edit model | One recording only; `media.duration` was the timeline length everywhere | No imported shots, B-roll, append or scene replacement |
| Overlays | No annotations, no redaction | Can't explain or protect content; competitors all have callouts and blur |
| Audio | Recorded tracks plus generated voiceover only | No music bed, no imported voiceover |
| Captions | No SRT/VTT, no transcript editing; one font | Captions can't leave Glint; filler cuts only by planner |
| Timeline | No trim/caption/speed drag handles | Precise edits needed the inspector or ops |
| Capture | One file per track finalized at stop; window moves misalign input; no pause; no preflight | A crash lost the take; wrong cursor positions on moved windows |
| Agents | Scenes matched to old ones by time, IDs not stable; evidence = none | Can't re-record one scene or say what the video proves |
| Jobs | Renders synchronous per call; no cancel or retry | Long unattended runs restart from zero |
| Autopilot | A failed transcription was "skipped"; the result had no status | An unchecked draft read as a success |
| Approvals | The voiceover fingerprint used Swift `hashValue` (seeded per process) | An approval granted from another process could never match |
| Billing | Voiceover re-synthesized every line on each call | Paid TTS repeated for unchanged lines |

## Enhancements

### 1. Editing parity

| # | Enhancement | Acceptance criteria | Status | Evidence |
|---|---|---|---|---|
| 1.1 | Shot model (`MediaClip`, `ClipLayout`, program timeline) | Legacy projects load unchanged and their timing is identical; several shots play end to end; preview, stills and export agree | Done | `ClipModelTests.legacyDocumentsLoadWithDefaultsAndUnchangedTiming`, `MultiShotTests.importedShotsPlayInOrderWithCorrectTiming` (pixels at 3 output times, exported duration) |
| 1.2 | Clip ops: insert, update (trim, rename, gain, scene), remove, move, split, replace | Every timeline item stays on its content across each op; a trimmed tail stays trimmed when shots are appended; invalid shots rejected with a message | Done | `insertingAShotKeepsEditsOnTheirContent`, `appendingKeepsATrimmedTailTrimmed`, `moveRemoveAndSplitRemapItems`, `clipValidation` |
| 1.3 | Import movie as a shot (copied in, original untouched), part of a file, different shapes letterboxed | Inserted at playhead or end; 16:9 inside 16:10 shows bars, not stretching | Done | `importedShotsPlayInOrderWithCorrectTiming`; app Media tab and drag-and-drop; `glint add-clip`, `glint_import_clip` |
| 1.4 | Program-time events and transcript (each shot's own take events; cursor only on shots with events) | Planners, quality, scenes and the renderer see one consistent timeline | Done | `programEventsComeFromEachShotsTake`, recipe e2e (take click mapped into the edit) |
| 1.5 | Imported movies are never "idle" | No idle speed-ups or end trims applied to a shot without input data | Done | `ImportedShotPlanningTests` |
| 1.6 | Music bed, imported voiceover, effects: gain, loop, fades, ducking under narration | Bed fills the video, no audio past the picture, loudness measured in export | Done | `musicBedAndImportedVoiceAreMixed`, `AudioEnvelopeTests` |
| 1.7 | Transitions: dip to black/white at an instant (fade in/out at the ends) | Full colour at the centre, none away from it | Done | `transitionDipsToBlack`. Crossfades between shots are **not** implemented: the composition uses one picture track. |
| 1.8 | Reusable style presets (built-in + saved, `merge_style`) | Apply is one undoable change; unknown sections rejected | Done | `mergeStylePresetAndUnknownSections`, MCP `glint_apply_preset` test; Style tab presets |

### 2. Callouts and privacy masks

| # | Enhancement | Acceptance criteria | Status | Evidence |
|---|---|---|---|---|
| 2.1 | Annotations: text, arrow, box, spotlight highlight | Drawn in content space (move with the zoom), fade in/out, validated geometry and time | Done | `calloutsAreDrawnAndFollowTheZoom` (pixels before/after a 2× zoom), `annotationsAndRedactionsValidate` |
| 2.2 | Redaction: pixelate, blur, solid; time-scoped | In preview frames, stills and the exported file; text unreadable by OCR after masking; never moved onto other content by a clip edit | Done | `redactionMasksPreviewStillsAndExport` (OCR reads the header before, not after; solid colour in the decoded MP4), `replacingASceneKeepsManualIntentAndDropsAuto` |
| 2.3 | Edit on the preview (select, move, resize, draw with tools) | Positions correct under zoom and letterboxing | Done, untested by input | Coordinate mapping tested: `previewCoordinatesRoundTripUnderZoom`. Drawing and dragging: `OverlayCanvas.swift`, screenshots only |
| 2.4 | Inspector and list for every callout and mask | All fields editable; low-strength warning on blur/pixelate | Done, untested by input | `OverlayInspector.swift` |

### 3. Captions, transcript, timeline

| # | Enhancement | Acceptance criteria | Status | Evidence |
|---|---|---|---|---|
| 3.1 | SRT/WebVTT export timed to the edited output; import back | Cues follow cuts and speed changes; split at cuts; round trip stable; bad files rejected | Done | `exportedCuesFollowTheEditedOutput`, `exportedSubtitlesMatchTheRenderedTimeline` (vs the built composition), `parseRejectsGarbage` |
| 3.2 | Cut by transcript (word ranges, phrase) | Neighbouring words never clipped | Done | `transcriptCutsSpareNeighbours`, `transcriptEditAndSubtitleToolsRoundTrip`; Captions tab transcript |
| 3.3 | Caption styling: font, weight, size, colours, position, look | Rendered with the chosen design | Done | `CaptionStyle.font/weight`, `Artwork.captionFont`; Captions tab |
| 3.4 | Timeline drag: trim in/out, caption and speed handles, overlay and audio lanes, shots lane, snapping | One undoable op per drag | Done, untested by input | `TimelineEditor.swift`; screenshots |
| 3.5 | Keyboard and accessibility: shortcut sheet (⌘/), Space/Delete/S/I/O/B/H/A/T/R/Esc, labels | Keys don't fire while a text field has focus | Done, untested by input | `ShortcutsHelp.swift`, `GlintApp.swift` menus |
| 3.6 | Facecam: drag the bubble to snap to a corner | Existing facecam behaviour unchanged | Done, untested by input | `PipelineTests.facecamBubbleIsComposited` still passes |

### 4. Capture reliability

Details: [CAPTURE-RELIABILITY-NOTES.md](CAPTURE-RELIABILITY-NOTES.md).

| # | Enhancement | Acceptance criteria | Status | Evidence |
|---|---|---|---|---|
| 4.1 | Pause/resume across screen, audio, camera and input | Gapless files, events rebased, elapsed excludes pauses | Done | `pausedSamplesAreDroppedAndLaterOnesRetimed` (4.0 s movie from 6 s with a 2 s pause, frame at the cut checked by pixel); live `glint pause`/`resume` on a real window take |
| 4.2 | Crash-resilient writing (2 s fragments, journal, events checkpoint) and recovery | Recovery exercised on real interrupted artifacts | Done | `interruptedTakeIsRecoveredFromFragments` (mid-write copy → 4.0 s, abandoned writer → 8.0 s, renders); live SIGKILL of `glint record` recovered 6.0 s |
| 4.3 | Preflight: permission, source, mic/camera, folder, disk | `record_start` refuses on a failure | Done | `preflightReportsAndBlocksHardFailures`; Record sheet |
| 4.4 | Moved-window coordinate tracking | Input normalized to the window frame at that instant | Done | `CaptureTimelineTests`; live run logged moves |
| 4.5 | Device errors: camera disconnect, stream stop, denied mic, unknown camera | The take is kept; warnings and errors surface in status, stop result and app | Done (camera unplug and a stream dying mid-take were not reproduced on hardware) | Code paths + unit tests of the error mapping |

### 5. Agent-native production

| # | Enhancement | Acceptance criteria | Status | Evidence |
|---|---|---|---|---|
| 5.1 | Versioned demo recipes with stable scene IDs, steps, preconditions, expected outcomes | Validation (unique IDs, no credentials in fixtures), version bump only on change | Done | `validationAndVersioning` |
| 5.2 | Evidence with `verified` / `failed` / `needs_review` | A click or a vision opinion never verifies; verified needs an observed value; failed wins; unknown never passes; stale takes don't count | Done | `aClickNeverVerifiesAndUnknownNeverPasses` |
| 5.3 | Bind scenes from `scene:<id>` markers; OCR check of visible-text outcomes | Shots tagged with scene IDs; OCR verifies found text and leaves misses for review | Done | `markersBindScenes`, `RecipeWorkflowTests.recordBindVerifyRefresh` |
| 5.4 | Refresh one scene from a new take, keeping manual edits elsewhere | Untouched scenes' items stay on their content; manual items inside placed proportionally; auto dropped; take evidence imported; undo restores | Done | `recordBindVerifyRefresh` (fixture e2e: pixels from the new take, zoom shifted exactly, evidence reset, undo) |
| 5.5 | Scene IDs stay stable across re-analysis | Tagged shots become scenes with the recipe ID; previous IDs reused by match | Done | `SceneAnalyzer` change; recipe e2e |
| 5.6 | Honest scope | No autonomous app exploration claimed | Done | Docs: the agent drives the app; Glint records, checks and preserves |

### 6. Durable jobs, repair and autopilot

| # | Enhancement | Acceptance criteria | Status | Evidence |
|---|---|---|---|---|
| 6.1 | Render jobs with stages, progress, cancel, retry, interruption detection, document snapshot | Cancel leaves no partial file; retry skips completed stages whose artifacts still hash the same; tampered artifacts re-run; later edits don't change the job's output | Done | `renderJobCheckpointsCancelsAndResumes` |
| 6.2 | Idempotency keys | Same key + params → same job; different params → refused | Done | `idempotencyAndInterruption`, job test step 5 |
| 6.3 | Production jobs: quality → bounded deterministic repair → draft render → inspection → evidence | Repairs are attributed, undoable transactions, never cuts; ends `succeeded` only when everything passes | Done | `productionJobNeverPassesAnUncheckedDraft`, `repairPlansAreBoundedAndLocal` |
| 6.4 | Autopilot status: `ready` / `needs_review` / `draft` / `failed`; required steps; `expected_revision` | Asked-for steps that fail → `failed`; no recipe → `needs_review` | Done | `autopilotReportsNeedsReviewWithoutARecipeAndFailsRequiredSteps`; CLI exits 1 on failed, 3 on approval |
| 6.5 | Billing safety: unchanged voiceover lines aren't re-sent; stable approval fingerprint | No ElevenLabs call when every line already has a clip with the same text and voice | Done | `Narration.swift`, `StableHash` test |

### 7. App usability

| # | Enhancement | Status | Evidence |
|---|---|---|---|
| 7.1 | Sidebar tabs: Style, Media, Captions, Voice, Recipe, Chat, Activity | Done, untested by input | Screenshots of each tab (sidebar agent run) |
| 7.2 | Export on durable jobs with live progress, Cancel, Retry, stages, review items; production check | Done, untested by input | `ExportSheet`, `JobsPanel.swift`; Activity screenshot shows Done and Interrupted jobs |
| 7.3 | Home: Import a movie, drag-and-drop; interrupted recordings banner | Done, untested by input | `MovieImport.swift`, `RecoveryView.swift` |
| 7.4 | Recording: preflight in the sheet, Pause in HUD and menu bar | Done, untested by input | `HomeView.swift` RecordSheet, `AppModel.swift` |
| 7.5 | Empty, loading and error states; plain language; light-blue direction | Done | Each new lane and panel has a one-line empty hint; no new gradients, glows or sparkles |

### 8. Tests and checks

`swift test`: 137 tests in 40 suites pass (67 in 18 before). `swift build` and `scripts/build-app.sh` succeed. No lint tool is configured. Type checking is the Swift compiler: the build has no new warnings (the existing `ChatPanel.swift` capture warnings are unchanged). `git diff --check` and a trailing-whitespace scan of new files are clean. See [TESTING.md](TESTING.md).

## Integration review corrections

- Clip edits preserve every surviving interval of a privacy mask, callout, caption, speed or zoom; inserted footage is not included. Source-time boundary markers follow the original shot. Regression tests cover tiny mask fragments, overlapping source ranges, custom caption text and undo/redo identity.
- Imported orientation metadata is applied per shot before fitting, masking and rendering. Fixed and cursor-following zooms use the current shot's fitted rectangle. A real rotated-movie fixture checks preview pixels, a mask and decoded export pixels.
- Source and edited durations must be finite and at most six hours. Motion paths guard allocation, and composition rejects clip endpoints beyond the media file.
- Evidence is bound to the recipe and scene content it checked. Legacy evidence without this context needs review. Production jobs verify their captured recipe/document and rerun quality checks on retry. Job creation, snapshots, claims, cancellation and retry share a cross-process lock.

## Not done, and remaining limits

- **Crossfades between shots**, picture-in-picture B-roll, device frames, keyframed camera paths.
- **Transcribing imported shots' audio**: transcripts cover the original recording's microphone/system audio only.
- **Facecam per shot**: only the original recording's camera is shown; imported takes have no facecam.
- **Autonomous app exploration**: Glint doesn't plan or drive apps. A coding agent drives; Glint records, checks evidence and preserves edits.
- **Evidence checks Glint runs itself** are limited to on-screen text (OCR on the last frame of a scene). State outcomes need an external assertion or a person.
- **Untested by input**: every drag, draw and click interaction in the new UI. They compile and were screenshotted; a manual pass is needed.
- **Hardware not exercised**: a camera unplugged mid-take, the screen capture dying on its own, the disk filling during a take.
- **Out of scope**: Windows/Linux, hosted rendering or team workspaces, training generative models, a true-peak limiter.
