# ScreenKite 2.3.2 (build 737): static reverse-engineering study

Scope: a static, read-only study of the locally installed `/Applications/ScreenKite.app`, done to inform an
independent native macOS screen recorder and editor. The app was not launched, modified, or used to record.
Nothing was decrypted, and no licensing or protection was bypassed. All prose here is our own description;
no proprietary code, assets, or branding were copied.

Binary under study: `Contents/MacOS/ScreenKite`, universal (x86_64 + arm64), 239 MB.
SHA-256 `736cf94ff073de03f67cce027ac050d3aeac51bae8edec562096ea06483f17cf`. The internal Swift module is
`KeyVisualStudio` (the app was formerly named "KeyVisual Studio"). Minimum OS is macOS 15.0. It was built
with the macOS 27.2 SDK.

## Method and limits

- **REA MCP**: `open_binary`, `inspect_signature`, `inspect_plist` (twice), `demangle_swift` and
  `close_binary` worked. `inspect_macho` timed out at 60 s on the 239 MB binary.
- **No pseudocode**: Hopper is REA's only deep provider here, and macOS refused it Automation permission
  ("Not authorized to send Apple events to Hopper"). As a result **no pseudocode or disassembly was
  available**, so numeric defaults that live only in code are marked UNKNOWN.
- **Swift metadata**: we wrote our own parser for the `__swift5_fieldmd` section, resolving `__swift5_reflstr`
  strings and nominal-type context descriptors. It recovered **16,886 field descriptors**: type names plus
  stored-property and enum-case names. This is the main schema evidence (EV-10). About 1,165 types have
  names that could not be resolved (indirect symbolic references). They are identified below by their field
  sets.
- **Other sources**: imported symbols from `xcrun dyld_info -imports` (8,948 imports, EV-11), `strings` on the
  arm64 slice (223k strings, EV-12), resource bundle listings, and JSON resources.
- **Labels**: each finding is marked CONFIRMED (direct artifact evidence), INFERRED (a reasonable reading of
  names or structure), or UNKNOWN.

---

## 1. Capture

### 1.1 ScreenCaptureKit
- **CONFIRMED: SCStream-based capture.** The app imports `SCStream`, `SCStreamConfiguration`,
  `SCContentFilter`, `SCShareableContent`, `SCDisplay`, `SCWindow`, `SCRunningApplication`,
  `SCScreenshotManager` and `SCStreamFrameInfoStatus` (EV-11).
- **CONFIRMED: selectors used.** The selectors present are `addStreamOutput:type:sampleHandlerQueue:error:`,
  `startCaptureWithCompletionHandler:`, `streamConfigurationWithPreset:`, `setShowsCursor:`,
  `setCapturesAudio:`, `setExcludesCurrentProcessAudio:`, `setSampleRate:`, `setChannelCount:`,
  `setMinimumFrameInterval:`, `setQueueDepth:`, `setPixelFormat:`, `setColorSpaceName:`,
  `setColorMatrix:`, `setSourceRect:`, `setScalesToFit:`, `setPreservesAspectRatio:`, `setIncludeMenuBar:`,
  `setCaptureResolution:` and `setBackgroundColor:`.
- **CONFIRMED: content filters.** The filter initializers present are
  `initWithDisplay:excludingApplications:exceptingWindows:`,
  `initWithDisplay:includingApplications:exceptingWindows:` and `initWithDesktopIndependentWindow:` (EV-12).
- **CONFIRMED: no SCRecordingOutput, SCContentSharingPicker or AVCaptureScreenInput.** None of the three
  appears in imports or strings (EV-11, EV-12). The app writes files itself with `AVAssetWriter`. It has a
  custom display/window/area picker made of overlay panels: `WindowSelectionCoordinator`,
  `DisplaySelectionOverlay`, `AreaSelector` (with aspect-ratio lock and custom size) and
  `WindowSelectionOverlay`.
- **CONFIRMED: capture pipeline types (EV-10).**
  - `KeyVisualStudio.ScreenInput` (the SCStream output) holds `filter`, `config`, `recordSystemAudio`,
    `recordHDR`, `idleFrameExtender`, `silentFrameRepeater`, `clockAligner`, `screenSampleQueue` and
    `audioSampleQueue`.
  - `ScreenInputRuntimeState` counts complete, idle, dropped, blank and fatal frame callbacks.
  - **INFERRED:** SCStream only delivers frames when the screen changes, so the app repeats or extends the
    last frame to keep a constant-rate file.
  - `RecordingConfiguration` holds `destinationURL`, `filter`, `streamConfig`, `captureFrameRate`,
    `displayMaximumFramesPerSecond`, `displayRefreshMatchOutcome`, `outputFileType`, `recordMicrophone`,
    `microphoneDeviceID`, `recordCamera`, `cameraDeviceID`, `recordSystemAudio`, `outputPreferences`,
    `audioOutputConfiguration`, `driftCorrection`, `cadence` and `multiSourcePlan`.
  - An unnamed writer type holds `writer`, `screenInput`, `cameraInput`, `systemAudioInput`, `micAudioInput`,
    `backpressureBuffers`, `sampleTimingGuardEnabled`, `lastAppendedVideoPTS`, `screenVideoCodec` and
    `didReportSoftwareEncoder`. This is one multi-input `AVAssetWriter` with PTS guards and backpressure.
  - `RecordingCadenceTracker` and `RecordingEncoderSaturationReporter` detect dropped frames and encoder
    overload.
  - `CaptureFrameRateCapability` holds `width`, `height`, `scale`, `physicalMemoryBytes`,
    `isLowPowerModeEnabled` and `encodeBudget`. It picks allowed frame rates per machine, with a "match
    display refresh" option.
- **CONFIRMED: recorder settings.** The settings UI fields are: include menu bar, hide desktop files, hide
  self, hide Control Center, high-res, record HDR, stereo mic, improve mic audio, countdown, keep overlays
  outside the capture area, confirm before stopping, pause creates a new segment, window alignment and snap
  threshold, auto-zoom default multiplier, typing-focus auto zoom (experimental), and manual-zoom modifier
  and hold delay (`RecorderSettingView`, EV-10).
- **CONFIRMED: output options.**
  - Video encoder enum `Encoder {h264, h265}`.
  - Container `VideoFormat {mov, mp4}`.
  - `AudioFormat {aac, alac, flac, opus, mp3}` and `AudioQuality {normal, good, high, extreme}`.
  - Option fields `withAlpha`, `pixelFormat`, `remuxAudio`, a naming template, and an action after recording.
- **CONFIRMED: time-lapse.** `RecorderSettings.TimeLapse {intervalSeconds, projectFPS, speedMultiplier}`.
- **CONFIRMED: scrolling screenshots.** `ScrollCaptureController` (stitched strips, auto-scroll speed,
  header detection) uses `VNTranslationalImageRegistrationRequest` (imported) to register strips.
- **CONFIRMED: secondary display capture.** `SecondaryDisplayCapture` records a second display as a
  separate source.

### 1.2 Audio, microphone, camera and device sources
- **CONFIRMED: microphone.** Captured through AVCaptureSession (`MicrophoneInput`) with a fallback to
  `AVAudioEngine` (`AuxiliaryMicrophoneCapture.usingAudioEngine`). `MicrophoneSampleBroadcaster` fans one
  mic stream out to the recorder, the teleprompter and level meters. `BluetoothMicrophoneRouteHolder` and
  `MicrophoneQualityHintRow.__isNarrowbandBluetooth` warn when a Bluetooth headset drops audio to
  narrowband.
- **CONFIRMED: system audio.** Comes from SCStream audio and is written to its own file. The modes are
  `SystemAudioCaptureMode {allApps, selectedApps}`.
- **CONFIRMED: camera.**
  - `CameraRecorder` uses AVCaptureSession and `AVCaptureVideoDataOutput` with its own AVAssetWriter. It has
    format-pinning logic (`CameraRecorderFormatSelector`), frame-rate conformance checks, cadence repair
    (`cameraCadenceHeldFrame`) and lead-in padding.
  - Frame-rate presets: `CameraFrameRatePreset {fps23_98, fps24, fps25, fps29_97, fps30, fps50, fps59_94, fps60}`.
  - Device types imported: `AVCaptureDeviceTypeBuiltInWideAngleCamera`, `ContinuityCamera` and `External`.
- **CONFIRMED: other device sources.**
  - iPhone/iPad over USB: `media/raw/idevice_0.mov`, plus a `CMIOObjectSetPropertyData` import (the usual
    way to enable screen-capture devices).
  - iOS Simulator: `SimulatorRecorderProcess` launches the simulator's own recorder, `Codec {h264, hevc}`.
  - Android: a downloaded helper app built on scrcpy, plus ADB (strings "ScreenKite Android Preview.app/
    .../scrcpy", "--force-adb-forward").
  - A `device-pose-track.bin` records device orientation over time.
- **CONFIRMED: raw file names (EV-12).** `screen_display_0.<ext>`, `microphone_primary.<ext>`,
  `media/raw/system_audio_0.m4a` and `media/raw/idevice_0.mov`. Recording-in-progress segments are named
  `*.open.*`. A multi-source sidecar (`metadata/multi-source.json`, `MultiSourceBundleIntegrator.Sidecar
  {formatVersion, takeID, clock, screenFileTimeOrigin, sources}`) aligns the sources on one clock.

### 1.3 Project document format
- **CONFIRMED: document types (EV-02).**
  - `.skbundle` has UTI `com.screenkite.projectbundle`, conforms to `com.apple.package`, MIME
    `application/vnd.screenkite.projectbundle`, and uses `NSDocumentClass =
    KeyVisualStudio.ScreenKiteProjectDocument` (NSDocument).
  - `.skpreset` has UTI `com.screenkite.inspector-preset` and conforms to `public.json`.
  - Quick Look preview and thumbnail extensions handle `com.screenkite.projectbundle` (EV-04).
- **CONFIRMED: package layout.** Reconstructed from path strings (EV-12):
  ```
  Foo.skbundle/
    project.json | project.bin          # manifest (JSON or an opaque binary form)
    metadata/session.json               # ProjectMetadataSession
    metadata/pointer-track.jsonl        # append-only event logs, one JSON object per line,
    metadata/keyboard-track.jsonl       #   each with a format header line
    metadata/manual-zoom-track.jsonl
    metadata/system-track.jsonl
    metadata/capture-frame-track.jsonl
    metadata/focus-track.jsonl          # accessibility focus/caret snapshots
    metadata/interaction-track.jsonl    # rich click records (app/window/AX element)
    metadata/drawing-track.jsonl        # live annotation strokes
    metadata/multi-source.json
    device-pose-track.bin
    media/raw/…  media/processed/  media/overlays/  media/background-music/  media/click-sounds/
    media/cursor-packs/  media/voiceover-*  media/ai-voiceover-*  media/replacement-*
    thumbnails/project-thumbnail.editor.json
    external-media.json, cursor-hover-changes.json, recovery.json (+ recovery.previous.json while recording)
  ```
- **CONFIRMED: two manifest forms.** `ProjectBundleManifestSupport` has
  `CryptoError {keyUnavailable, invalidHeader, missingCiphertext, decryptFailed}` and the strings "No
  project.bin or project.json found", "Do not hand-author `project.bin`".
  - **INFERRED:** `project.bin` is an encrypted or sealed manifest. We did not try to read it.
- **CONFIRMED: manifest root fields** (an unnamed type matched to `ProjectManifest.CodingKeys`, EV-10):
  `formatVersion, appBuild, duration, canvas, tracks, clips, markers, inputMetadata, editingAssistance,
  thumbnail, extensions, recordingGroupDissolved, aiAssistanceUsed, multicamGroups, layerOrderVersion`.
  The sub-types:
  - `Canvas {width, height, pixelAspectRatio, colorSpace, preset, referenceWidth, referenceHeight, fittingMode, placementAnchor, origin}`.
    `AspectPreset {auto, 16x9, 9x16, 1x1, 4x3, 3x4, 4x5, 21x9, custom}` and `HDRTransferFunction {pq, hlg}`.
  - `Track {id, kind, media, role(primaryVideo|secondaryVideo), transform{scale, translation, rotationDegrees}, isEnabled, zIndex, volume, isMuted, audioRole(replacement|voiceover), channelMix, name, language, …}`.
  - `Clip {id, track, sourceRange, timelineRange, timeScale, annotations, metadata, operations, animation, multicamGroupID, videoAngleID, audioAngleIDs, slipOffset}`.
  - `Marker {id, time, duration, type(chapter|bookmark|comment|segment|exportSelection), title, notes, color, origin(human|agent), confidence, suggestedAction}`.
  - `InputMetadata {directory, formatVersion, session, pointer, keyboard, manualZoom, system, captureFrame, focus, interaction, drawing, devicePose, summary}`.
    Each entry is a file reference with a `checksum`.
  - `ProjectExtensions {appearance, cameraSettings, autoZoom, transcript, frameRate, keyboardShortcuts, cursorOverlay, cursorPipeline, clickSounds, motionBlur, mockupPresentation, audioDucking, backgroundMusic, captionAI, privacy, additional}`.
    This is the editor's "look" state, kept apart from the timeline.
- **CONFIRMED: session metadata.** `ProjectMetadataSession {formatVersion, appBuild, startedAt, updatedAt,
  duration, startUptime, mediaTimebase, metadataTimeOffset, captureFrame, captureFrameSource, canvasSize,
  pixelScale, referenceDisplayID, displayDiagnostics, recorderSettings, recordedMedia, interactionCapture}`.
  - `RecordedMedia` holds `{trackID, file, kind, role, sourceTimeline, recordingStartUptime, recordingEndUptime, captureFrameIndexBlock}`.
  - `DisplayDiagnostics` holds `{… pointPixelScale, recordingScale, absoluteCoordinateSpace(appKitGlobal|topLeftGlobal) …}`.
- **CONFIRMED: Screen Studio import.** `ScreenStudioV4Project`, `ScreenStudioZoomRange`,
  `ScreenStudioRecorderSession` and the CLI command `project import-screenstudio`. It reads
  `.screenstudio/project.json` and `recording/metadata.json`.
- **CONFIRMED: crash recovery.** The `.skbundle.tmp` workspace has a recorder heartbeat (`recovery.json`
  with `pid`, `heartbeatUptime`), and the strings say the JSONL logs are append-only with a tolerated
  truncated last line. There is a `recover` CLI subcommand with `strict|best-effort` modes.

## 2. Cursor and input tracking
- **CONFIRMED: event APIs (EV-11, EV-12).**
  - `CGEventTapCreate` / `CGEventTapEnable`, used by `RecordingKeyboardEventTap {handler, tap, runLoopSource}`.
  - `NSEvent addGlobalMonitorForEventsMatchingMask:` and the local equivalent.
  - `CGEventCreate` with `CGEventGetLocation` for polled pointer position.
  - `CGEventSourceSecondsSinceLastEventType` for idle detection.
  - Carbon `RegisterEventHotKey` for global shortcuts (the KeyboardShortcuts package).
  - **IOHID is not used** (no IOHID imports).
- **CONFIRMED: pointer sampling is timer-driven, not only event-driven.**
  - `PointerMoveSamplerEngine.Configuration {samplingInterval, staleMoveThreshold, positionEpsilon, timerLeeway}`.
  - A "drag boost" mode (`PointerDragBoostMonitor`, `drag_boost_*` telemetry) raises the sampling rate
    during drags.
  - `PointerMoveResampler {targetInterval, maxInterpolationDuration}` resamples the samples to an even
    rate. The exact rates are UNKNOWN.
- **CONFIRMED: sample schema.**
  - `ProjectPointerSample {timestamp, action(move|down|up|scroll), captureSpaceLocation, captureFrameIndex, isWithinCapture, cursorIdentifier, absoluteLocation, displayID, provenance}`.
  - `ProjectKeyboardSample {timestamp, action, keyCode, modifiers, semantic, characters, isAutorepeat, provenance, app}`.
  - Moving-window or area capture is handled by `ProjectCaptureFrameSample {index, timestamp, origin, size}`.
    Pointer samples refer to the capture frame in effect at that moment.
- **CONFIRMED: cursor image capture and identification.**
  - The app reads `NSCursor currentSystemCursor` / `currentCursor` and `hotSpot`.
  - It fingerprints the image (`CursorImageFingerprint {hash, normalizedRGBA}`, `CursorHashSignature`) and
    caches the results (`ProjectSessionCursorState.resolutionsByImageHash`).
  - It maps the result to `CursorIdentifier {custom, arrow, iBeam, pointingHand, openHand, closedHand, crosshair}`.
  - **INFERRED:** `setShowsCursor:` turns off the baked-in cursor, and the editor re-renders a vector or
    raster cursor from this metadata. That is what lets cursor size, style and smoothing change after
    recording.
- **CONFIRMED: cursor rendering settings (EV-10, EV-12).**
  - `CursorOverlaySettings {isEnabled, symbolName, tintHex, storedSize, clickScale, clickDuration, symbolMode, smoothing{isEnabled, stiffness, damping, mass}, clickRipple{style(ring|filled|waterDrop), colorHex, sizeMultiplier, duration, opacity}, hideRules{hideWhenIdle, hideAfterSeconds, hideOnKeyboard, fadeDuration}, stylePreset(macOSDefault|spotlight|minimal|halo|target|custom), cursorPackId, cursorThemeId, followRecordedHover}`.
  - `CursorPipelineSettings {scale, hideWhenStatic, hideAfterSeconds, loopPositionBeforeEndSeconds, stopMovementBeforeEndSeconds, rotateOnXMovementRatio, baseRotationDegrees, removeShakeThreshold, useDefaultCursorWhenLowRes, alwaysUseDefaultCursor}`.
  - The size is in "points at 1080p" per the tool doc string.
  - Rendering helpers: `CursorHeadingFollow` (tilts the cursor with movement direction),
    `CursorPressSpringSchedule` and `CursorHoverSpringSchedule`, `CursorDragIntervalDetector`, and a Metal
    `kvs_waterDropRipple` kernel.
  - Assets: SVG cursor themes (`cursor-themes/{tabler,lucide}`, 10 shapes each), raster packs
    (`cursor-packs/{lavender,tint}`), and click sounds (two mouse models, down and up WAVs) applied as an
    audio track (`ProjectClickSoundSupport.Blueprint`).
- **CONFIRMED: keystroke overlay.**
  - `KeyboardShortcutHUDSettings {fontSize, verticalPosition(top|bottom), horizontalAlignment, backgroundOpacity, padding, showShortcuts, renderMode(shortcuts|allKeys), sizeRatio, displayDuration, showModifiersAlone, hiddenShortcutEventIDs, keycapStyle(flat|glass)}`.
  - Display types: `KeystrokeDisplayEvent {timestamp, duration, combination, signature, isHidden}` and
    `KeystrokeOverlayGeometry.Cap`, which lays out one keycap per key.
- **CONFIRMED: accessibility focus tracking for typing-aware zoom.**
  - `AXUIElementCopyAttributeValue` and related calls, with `AXFocusedUIElement`, `AXSelectedTextRange`
    and `AXBoundsForRange` (EV-12).
  - `ProjectFocusSample {trigger(keyboardDown|pointerDown|pointerUp|focusSnapshot), role, subrole, isTextInput, pointSource(selection|element), capturePointOfInterest, captureElementFrame, captureSelectionFrame, …}`.
  - `InteractionSample` records app, window, AX element, ancestors and click count for each click.

## 3. Auto zoom
- **CONFIRMED: project-level state.** `AutoZoomState {isEnabled, defaultZoom, defaultCameraZoomOut, motionPreset, alwaysKeepZoomedIn, defaultSnapToEdgesRatio, clickZoomEnabled, maximumEffectDuration, effects}`.
  The manifest also has a `followSafeZoneRatio` key.
- **CONFIRMED: zoom segment schema.** `ZoomEffect {id, startTime, duration, centerPoint, centerPath[{timeOffset, point}], coverageRect, isEnabled, isAutoGenerated, followCursor, manualTargetPoint, mouseAnchor, startZoom, endZoom, cameraZoomOut, isInstantAnimation, motionPresetOverride, snapToEdgesRatio, presentation, loupeOptions}`.
  - `ZoomPresentation {classic, loupe}`. Loupe is a circular magnifier with glass optics, bevel and
    chromatic aberration (`MetalLoupeGlassKernel`, `kvs_loupeGlass`).
- **CONFIRMED: motion model.**
  - `AutoZoomMotionPreset {focused, smooth, snappy}` (per clip, plus `inherit`).
  - `AutoZoomSpringConfiguration {stiffness, damping, mass}`.
  - `AutoZoomCameraTransformCalculator {stiffness, damping, mass, cropSpring, currentPosition, velocity…, RuntimeMode(active|none|holdTail)}`.
    This is a damped spring that runs over sampled time, not keyframe easing. The spring constants for each
    preset are UNKNOWN (compiled-in).
- **CONFIRMED: generation pipeline.**
  - `AutoZoomAnalyzer.Configuration {defaultZoom, captureFrame, maximumZoomMultiplier, defaultCameraZoomOut, clickZoomEnabled, maximumEffectDuration, defaultSnapToEdgesRatio}`.
  - Then `AutoZoomCursorCluster {startTime, endTime, center}`, `AutoZoomTypingBurst`, and
    `AutoZoomProposalBuilder`, which produces `{merged, keptIDs, review}`.
  - `AutoZoomRegenerationMerger` keeps user-edited zooms when regenerating.
  - `AutoZoomTimelineBuilder` produces `AutoZoomTimeline {cameraTransforms, …}`, cached by a key that
    hashes the cursor samples (`AutoZoomTimelineCache`).
- **CONFIRMED: behaviour from UI text.**
  - "Each click zooms in for about 3 seconds, and clicks close together share one zoom".
  - Hold a modifier key during recording for manual zoom (`RecordingManualZoomModifier {option, control, command, shift}` with `holdDelaySeconds`).
    After a manual zoom, clicks stop adding zooms to that recording.
  - An experimental mode keeps zoom on the typing caret.
- **CONFIRMED: zoom scale range.** The GUI and agent range for `zoomScale` is **1.0–4.0**. Centers are
  normalized 0–1 with a top-left origin, relative to the recorded frame and not the padded canvas. The
  default `followCursor` is true when cursor samples exist. One example uses a "fixed 2x zoom" (EV-12).
  The default zoom value itself is UNKNOWN.
- **CONFIRMED: Screen Studio zoom import.** The import maps `glideDirection`, `glideSpeed` and
  `threeDSettings` (perspective tilt during zoom) into the app's own model.

## 4. Timeline and editor model
- **CONFIRMED: track kinds.** `TimelineTrackKind {video, audio, soundEffect, overlay, captions, metadata, effect, specialEffect, cameraLayout, backgroundMusic}`.
  - `TimelineTrack {id, name, kind, isEnabled, blocks, zIndex, volume, isMuted}`.
  - Observable UI state is split into `TimelineTrackState`, `TimelineViewportState`, `TimelineSelectionState`
    and `TimelinePlaybackState`.
- **CONFIRMED: time mapping.**
  - `ClipMediaTimeMapping {groupRange, timelineRange, userSpeed, slip, recordingSourceOffset, angle}`.
  - `TimelineTimeMapper` maps between source segments and timeline segments.
  - Clips carry `sourceRange`, `timelineRange`, `timeScale` (speed) and `slipOffset`.
  - **INFERRED:** cuts are clips with gaps or adjusted ranges, and speed is per-clip `timeScale`.
  - Multicam groups and angles are supported (`multicamGroupID`, `switchAngle`).
- **CONFIRMED: clip extras.**
  - `ClipAnimation {fadeIn/Out, opacityTrack, positionTrack, scaleTrack, rotationTrack, cropTrack, volumeTrack, staticCrop}`.
  - `ClipTransition {style(crossDissolve, dip, slide*, push*, wipe*, iris, crossZoom, scale, …), duration, timing(linear|easeIn|easeOut|easeInOut), audioCrossfade}`.
  - `ClipChromaKey`, `ClipColorGrade`, `ClipTakeSet` (alternate takes).
  - `ClipMetadata {textOverlay, caption, mediaOverlay, annotationOverlay, drawingOverlay, cameraLayout, specialEffect, …}`.
- **CONFIRMED: smart editing.**
  - `SilenceDetector.Parameters {thresholdDB, minimumSilenceDuration, breathPadding}`.
  - `EditTranscriptCutSilencesArgs {minGap, padding, thresholdDB, leadPad, trailPad, crossfadeMs, …}`.
  - `TypingSpeedSuggestionAnalyzer` proposes speed-ups over typing bursts.
  - Filler-word detection by an LLM (`FillerWordDecisionItem`).
  - Text-based editing over a word-level transcript (`EditorTranscriptWord`, `editWords`).
  - Audio ducking (`ProjectAudioDuckingSettings {attack, hold, release, lookahead, duckedLevel, sensitivity…}`).
- **CONFIRMED: camera layouts.** `CameraLayout.Mode {pictureInPicture, fullscreen, sideBySideLeft,
  sideBySideRight, advanced, hidden}` with a "magic move" transition (`MagicMoveTiming {fast, balanced, slow}`)
  and an XML layout language (`CameraLayoutXMLCompiler`). `CameraFaceCenteredCropPlanner` keeps the face
  centered with a spring. `CameraSilenceHideWindowPlanner` auto-hides the camera when the speaker is silent.
- **CONFIRMED: undo is AppKit `NSUndoManager`** (`undoManager`, `setActionName:`, `beginUndoGrouping`).
  - Changes go through `EditorMutationRequest {dirtyDomains, syncMode(manifestOnly|manifestAndBundle|…), undoSnapshotOverride, …}`.
  - `UndoHistoryMirror.Step {sequence, actionName, date, kind, manifestFingerprint}`.
  - **INFERRED:** undo is snapshot-based, restoring a whole manifest value rather than inverting each
    operation.
  - Agent turns are grouped into one undo step (`ChatAgentTurnUndoState`, `PythonBatchUndoCoordinator`).
- **CONFIRMED: privacy redaction.** `PrivacyItem {kind(email|phone|address|card|iban|ssn|apiKey|secret|privateKey|face|qrCode|name|…), origin(detected|suggested|manual), keyframes[{time, rect}], holdMode}`.
  On-device detection uses Vision OCR (`VNRecognizeTextRequest`), face detection, and QR/barcode detection.

## 5. Rendering
- **CONFIRMED: custom AVVideoCompositing compositor.**
  - `EditorRendering.KeyVisualVideoCompositor` holds `renderContext, pixelBufferPool, colorSpace, metalDevice, metalContext, backgroundRenderer, contentRenderer, overlayCompositor, frameCache, cachedStaticRegions`,
    plus `RequestPriorityHint {playback, scrubbing, idle}`.
  - The selectors `startVideoCompositionRequest:`, `renderContextChanged:` and `setCustomVideoCompositorClass:` are present.
  - Bundled third-party GPU libraries: MetalPetal (it has its own `MTIVideoComposition.Compositor`) and Harbeth.
- **CONFIRMED: frame cache.** `ComposedFrameCache` is an LRU cache keyed by time range, content hash,
  quality (`preview|export`) and size. `StaticRegionAnalyzer` skips re-rendering regions that do not change.
- **CONFIRMED: Metal kernels** in `CoreVideoEditor_EditorResources.bundle/.../default.metallib` (EV-13):
  `kvs_motionBlur`, `kvs_motionBlurWeighted`, `kvs_zoomBlur`, `kvs_zoomBlurWeighted`,
  `kvs_gaussianBlurHorizontal/Vertical`, `kvs_bicubicResample`, `kvs_colorGrading`, `kvs_chromaKey`,
  `kvs_clipTransition`, `kvs_fillDiagonalGradient`, `kvs_fillSolidAndBlend`, `kvs_fillSolidColor`,
  `kvs_loupeGlass`, `kvs_waterDropRipple`, `skinSmooth*` (guided-filter beauty), and
  `deviceMockupVertex/Fragment`. MPS (Gaussian blur, histogram, median, Sobel, Canny) and Core Image are
  used alongside.
- **CONFIRMED: appearance schema.** `ProjectAppearance` holds:
  - Background: `backgroundKind(wallpaper|gradient|color|transparent|blurredContent)`,
    `wallpaperIdentifier`, `wallpaperTintColor/Opacity`, `animatedGradientSpeed`, `blurAmount`.
  - Framing: `padding` ("percent of the min canvas dimension"), `cornerRadius` (points),
    `screenCornerStyle(smooth|plain|squircle)`.
  - Shadow: `shadowEnabled`, `shadowRadius`, `shadowOpacity`, `shadowColor`, `shadowX/YOffset`.
  - Other: `colorGrading` (with LUT), `contentCropRect` and `autoFullBleedPadding`.
  - 41 bundled wallpaper thumbnails. Full-resolution wallpapers are probably downloaded (INFERRED).
- **CONFIRMED: motion blur.** `MotionBlurSettings {isEnabled, globalAmount, components{cursor, video, camera, zoom}, qualityPreset(performance|balanced|quality), samples, shutterAngle}`.
  `MetalMotionBlurRenderer` has separate pipelines for linear motion blur and radial zoom blur. Default
  values are UNKNOWN.
- **CONFIRMED: device mockups.**
  - 2D SVG frames: 39 `DeviceFrame-*.svg` files.
  - 3D meshes: 21 `.skmesh` files, which look encrypted or compressed (high-entropy header). They are
    rendered with SceneKit (`SCNRenderer`, PBR lighting) and have orbit and dolly gizmos and laptop hinge
    and lid animation.
  - JSON descriptors: `ClayMockups.json`, `MockupFinishes.json` (PBR material slots) and
    `MockupScreenCorners.json` (screen size and corner radius per device).
- **CONFIRMED: HTML overlays.** HyperFrames, an HTML-to-video format, is used for animated overlays
  (lower-third, badge, code-block, terminal, browser-mockup, info-card). Each template has a `template.json`
  with `{compositionID, width, height, durationSeconds, defaultVariables, hasAlpha}` and is rendered
  through WKWebView.

## 6. Export
- **CONFIRMED: custom render loop.** Export renders each frame and appends it to `AVAssetWriter` through
  `AVAssetWriterInputPixelBufferAdaptor` (`SegmentExportPipelinedDriver`, `SegmentExportWriterSetup`,
  `SegmentExportWindowJoiner`). It renders in parallel windows that are joined afterwards.
  `AVAssetExportSession` is also imported, with presets `AppleM4A`, `HighestQuality` and
  `HEVCHighestQuality`. **INFERRED:** that is for audio-only and passthrough jobs.
- **CONFIRMED: output formats.** `{mp4, mov, hevc, hevcWithAlpha, proRes422LT, proRes422, proRes422HQ, proRes4444, gif, fcpxml}`.
  - Audio-only mix: `m4a|wav`. Subtitles: `srt|vtt`.
  - Imported codec constants include H.264 High/Baseline, HEVC Main/Main10, every ProRes flavor, and HDR
    transfer functions (PQ, HLG, BT.2020).
  - Export presets: `CanvasExportPreset {name, width, height, aspectRatio, supportedFrameRates, codec, bitrateMbps, container}`.
- **CONFIRMED: VideoToolbox.** It enumerates encoders (`VTCopyVideoEncoderList`, `…IsHardwareAccelerated`,
  `PerformanceRating`) and can require hardware encoding. If writer setup fails it retries with a fallback
  ladder (`VideoSettingsStrategy {…, conservativeSameCodec, conservativeH264Fallback, conservativeH264SoftwareFallback}`).
  It also has a memory and disk preflight (`ExportResourcePolicy`, `ExportDiskPreflightTelemetry`) and a
  resolution step-down.
- **CONFIRMED: GIF.** `GIFExportSession` writes through ImageIO `CGImageDestination` with the GIF
  delay-time and loop-count keys.
- **CONFIRMED: cloud share.** HLS fMP4 segments come out of an AVAssetWriter delegate
  (`ExportHLSSegment {initialization, media}`, `AVFileTypeProfileMPEG4AppleHLS`). The quotas are
  `CloudExportGate {tooLong, linkLimitReached}`.

## 7. AI features and automation
- **CONFIRMED: transcription is multi-provider.** The providers are `elevenLabs, fishAudio, whisperKit,
  qwen3, moss, appleSpeech, openai, groq, azureOpenAI`.
  - On-device Qwen3 ASR comes in 0.6B and 1.7B packs, runs on MLX from the plugin
    `QwenTranscription.framework` (43 MB), and has a CoreML forced aligner for word timings. It requires
    Apple silicon.
  - WhisperKit (Argmax) is also linked.
  - Apple `SpeechTranscriber` is used on macOS 26 and later. `SFSpeechRecognizer` is used for the
    teleprompter's live follow-along.
  - "MOSS" is a local option that also returns speaker labels (about 0.7 GB).
  - Models are downloaded on demand and checked against SHA-256 hashes.
- **CONFIRMED: speech enhancement ("Improve microphone audio").**
  - `AudioEnhancementV9` with backends `MossFormerBackend` (a MossFormer2 speech-enhancement port to MLX,
    `fp32|int8`, Apache-2.0 LICENSE bundled) and `TFRestormerBackend`.
  - TF-Restormer weights come from Hugging Face `shinuh/tf-restormer-baseline` (MIT). They are loaded from a
    PyTorch zip through a layout manifest, explicitly without evaluating pickle. Config: chunk 4.0 s,
    overlap 0.5 s, alpha 0.2.
  - A DSP "studio" chain follows: high-pass, de-ess, low-shelf, presence, leveler, limiter
    (`VoiceEnhancementReport.StudioConfig`).
- **CONFIRMED: captions and LLM editing.**
  - `CaptionAIDocumentState` handles phrases, translation, bilingual mode and active-word (karaoke)
    highlighting.
  - Caption cleanup, filler-word removal and translation run through a user-configured LLM. The catalog
    `AITextModelCatalog.json` covers OpenAI, Anthropic, Gemini and Azure. They can also run on Apple
    `FoundationModels` (on-device; uses `Tool`, `Generable` and `Transcript`, EV-03).
  - Libraries: SwiftAISDK and AnyLanguageModel.
- **CONFIRMED: built-in agent and MCP server.**
  - `ProjectEditorMCPToolName` has **89 tools**, including `stat, peek, editTimeline, editWords, fx,
    effect, animate, canvas, crop, xform, markers, layout*, mockup*, privacy*, music, tts, stockSearch,
    export, exportWords, hyperframes, pythonBatch, vfxCut, vfxOverlay, multicam, switchAngle`.
  - It speaks MCP over stdio, plus a GUI-hosted server on a 127.0.0.1 port (SwiftMCP plus SwiftNIO).
  - Setup strings include `claude mcp add …` and `codex mcp add …`.
  - Agent edits are checked against a project revision (`MCPProjectRevisionExpectation`) and reported as
    diffs (`MCPMutationChangeReporter.Report`).
  - An in-app chat agent ("Core Agent", a separately downloaded runtime at `SKChatRuntimeBaseURL`) supports
    providers `claude, xai, chatgpt, kimi`.
  - **INFERRED:** strings referencing `~/.codex/auth.json`, `~/.gemini/oauth_creds.json` and
    `~/.grok/auth.json` suggest it can reuse coding-agent CLI sign-ins.
- **CONFIRMED: CLI in the app binary** (`ScreenKite <cmd>`): `mcp`, `tool list|describe|call`,
  `project list|current|open|create-empty|create-from-video|import-screenstudio|clear`,
  `transcription status|export`, `skills list|details|expand`, `sessions list`, `workspace info`,
  `recover`, and `screenkite recording start|stop|pause|resume|cancel|status|sources|doctor|onboard`.
  Recording automation goes over a local socket with a handshake (`RecordingAutomationEndpointMetadata {protocolVersion, socketPath, nonce, …}`) and idempotency keys.
- **AppleScript: INFERRED minimal.** `NSAppleScriptEnabled = YES` and `OSAScriptingDefinition = Scriptable`
  are set, but no `.sdef` file is in Resources. Apple Events are used outbound to open editors and terminals
  (EV-02).
- **App Intents: INFERRED none user-facing.** The framework is linked, with only 8 imported symbols
  (`AppIntent`, `AppShortcutsProvider`) used by SwiftMCP's generic `MCPAppIntentTool`, and there is no
  `Metadata.appintents` folder.
- **URL scheme: CONFIRMED.** `screenkite://` is registered, named for OAuth callback.
- **Other on-device AI: CONFIRMED.** Vision person segmentation (`VNGeneratePersonSegmentationRequest`,
  `VNGenerateForegroundInstanceMaskRequest`) for camera background effects, face landmarks for beauty,
  saliency, and a CLIP-like media search (`SemanticMediaCentral`, image and text encoders).

## 8. UX features worth emulating
1. A cursor drawn from recorded metadata instead of baked into the video. Size, style, smoothing, hide
   rules, click ripple and click sounds all stay editable after recording.
2. Auto zoom from clicks and typing that the user can review: proposals, a "Restore Default Zooms" action,
   and regeneration that keeps edited zooms. Manual hold-key zoom while recording. A loupe as an
   alternative to whole-frame zoom.
3. A spring-based camera, so zoom, pan and cursor-follow share one physical model and stay coherent.
4. Typing speed-up suggestions, silence and dead-air marking and cutting, filler-word removal, and
   text-based editing.
5. A camera layout per segment with magic-move transitions, face-centered crop, and auto-hide on silence.
6. Privacy scanning (OCR, faces, QR) with keyframed redaction boxes and agent-suggested items that need review.
7. Crash-safe recording: append-only JSONL logs, a heartbeat, a recovery tool, and segment files.
8. Diagnostics up front: Bluetooth narrowband mic warning, frame-rate capability menu, encoder saturation
   notices, and low-disk warnings.
9. An agent-first design: a stable CLI, an MCP tool surface, revision-checked mutations, change reports,
   and one undo step per agent turn.
10. Quick Look thumbnail and preview for project bundles. Import from a competitor's format (Screen Studio).

---

## Design implications for our implementation

1. **Capture**: use `SCStream` with our own `AVAssetWriter`, not `SCRecordingOutput`. That gives us PTS
   control, idle-frame repetition, backpressure and multiple inputs. Write screen, mic, system audio and
   camera as **separate files** on one host-time clock, and keep a sidecar with each source's start uptime.
   Set `showsCursor = false` and record cursor metadata separately.
2. **Input metadata**: record pointer, keyboard, focus and capture-frame data as **versioned, append-only
   JSONL** in a `metadata/` folder. Give each file a header line and tolerate a truncated last line.
   - Store pointer samples in capture space plus a capture-frame index, so moving windows and area capture
     map correctly.
   - Sample the pointer on a timer (for example 60–120 Hz, boosted during drags) as well as from events.
   - Identify cursors by hashing the system cursor image.
3. **Project format**: a package UTI (`*.ourbundle`, conforming to `com.apple.package`) with a JSON
   manifest `{formatVersion, canvas, tracks, clips, markers, inputMetadata(refs plus checksums), extensions}`.
   - Keep "look" settings (appearance, cursor, zoom, motion blur) in `extensions`, separate from timeline
     structure.
   - Keep the manifest plain JSON; we have no need for an opaque binary form.
4. **Auto zoom**: cluster clicks (around 3 s per click, merge nearby ones) and typing bursts (caret bounds
   from the AX API), then generate `ZoomSegment {start, duration, scale 1–4, center | followCursor,
   snapToEdges, preset}`.
   - Animate with a critically damped or slightly underdamped **spring** over `{stiffness, damping, mass}`,
     with presets (snappy, smooth, focused).
   - Mark segments as auto or user-edited, so regeneration keeps user edits.
5. **Timeline**: clips are `{sourceRange, timelineRange, timeScale, slip}` on typed tracks.
   - Use a `TimelineTimeMapper` to map source time to timeline time, so cursor and zoom metadata follow
     cuts and speed changes.
   - Use snapshot-based undo with `NSUndoManager`: the manifest is a value type, so register the previous
     snapshot. This is simple and robust, and it groups agent batches easily.
6. **Rendering**: write one Metal-based `AVVideoCompositing` compositor that serves both preview and export.
   - Layers: background, then the content quad (rounded rect or squircle with an SDF shadow), then camera,
     then overlays, then cursor.
   - Add an LRU cache of composed frames and static-region detection for scrubbing.
   - Implement motion blur in the shader as N sub-frame samples over a shutter angle, with separate
     amounts for camera zoom and pan and for the cursor.
7. **Export**: a pixel-buffer-adaptor writer loop with HW encoder discovery (`VTCopyVideoEncoderList`) and a
   fallback ladder (same codec, then H.264 HW, then H.264 SW). Run disk and memory preflight first. Write GIF
   through ImageIO, and also offer ProRes 4444 and HEVC-with-alpha for overlays.
8. **AI**: put transcription behind a provider protocol. Use on-device first (Apple `SpeechTranscriber` on
   macOS 26 and later; WhisperKit or an MLX ASR otherwise), with optional cloud providers. Produce
   word-level timings, since captions, text editing and silence cuts all depend on them. Treat speech
   enhancement as an optional downloaded model plus a deterministic DSP chain.
9. **Automation**: ship a CLI inside the app bundle and an MCP server early. Use the same tool schema for
   both, check every mutation against a revision, and return a change report. This makes both agent use and
   testing easy.
10. **Avoid**: three-way telemetry (Firebase, Sentry with session replay, PostHog and Statsig), reading
    other tools' credential files, and encrypted project manifests. These all work against user trust.

---

## Evidence ledger

| ID | Kind | Source / method | Supports |
|---|---|---|---|
| EV-01 | REA `inspect_signature` | `ev_f21d93be8b578a9fc98bc75400889aed84e3e48fe7523512a6b27d47fea712e8` | Team DH5UQL44AR, hardened runtime, entitlements (camera, audio-input, apple-events, JIT, unsigned exec memory) |
| EV-02 | REA `inspect_plist` | `ev_e41457fb68fc284751da9ff7f0819b70c312986879eb65b35111d09f3a4256f9` (Contents/Info.plist) | UTIs, document types, URL scheme, usage strings, `SKChatRuntimeBaseURL`, AppleScript keys |
| EV-03 | REA `demangle_swift` | `ev_d467ad23a9ef8225f22681f84de634341ed9d6e17ba9cdcf5c15563982047920` | FoundationModels `Tool.call`, AppIntents `AppShortcutsProvider`, `SwiftMCP.MCPAppIntentTool`, `Qwen3ASR.ForcedAlignerTextDecoding`, `WindowVideoReplay` |
| EV-04 | REA `inspect_plist` | `ev_d2b7f9016e5c4e8dce1b9165af2b49b96c42fb85517c376d2adf8af940cc0b75` (Preview appex) | Quick Look preview for `com.screenkite.projectbundle` |
| EV-05 | REA limitation | `inspect_macho` timeout; Hopper Automation denied | No pseudocode; numeric defaults UNKNOWN |
| EV-10 | Swift field metadata | custom `__swift5_fieldmd` parser on arm64 slice (16,886 descriptors) | All type and field names cited (ZoomEffect, AutoZoomState, ProjectManifest keys, CursorOverlaySettings, …) |
| EV-11 | Imports | `xcrun dyld_info -imports` (8,948 symbols) | SCK classes, no SCRecordingOutput or picker, CGEventTap, AVAssetWriter, VT, Vision, Speech, ImageIO GIF keys, CMIO |
| EV-12 | Strings | `strings -a -n 6` on arm64 slice | Bundle paths, CLI usage, MCP strings, provider names, zoom ranges, recovery README, scrcpy/ADB |
| EV-13 | Metal library | `strings` on `CoreVideoEditor_EditorResources.bundle/Contents/Resources/default.metallib` | `kvs_*` kernel names, `deviceMockup*`, `skinSmooth*` |
| EV-14 | Resource files | `CoreVideoEditor_EditorResources.bundle` listing | 39 SVG frames, 21 `.skmesh`, cursor themes and packs, ClickSounds, 41 wallpapers, 11 music items, hyperframes templates, `AITextModelCatalog.json` |
| EV-15 | Resource JSON | `TFRestormerMLX…/provenance.json`, MossFormer LICENSE | Speech-enhancement model origin, license, chunking config |
| EV-16 | Framework strings | `QwenTranscription.framework` binary strings | Qwen3 ASR on MLX, CoreML forced aligner |
| EV-17 | Localized strings | `Resources/en.lproj/Recording.strings` | About 3 s per-click zoom, merging, manual hold-key zoom |
| EV-18 | Linked libs | `otool -L` | ScreenCaptureKit, AVFoundation, VideoToolbox, Metal, MPS, CoreImage, SceneKit, Vision, Speech, FoundationModels, AppIntents, WebKit, Sparkle |
| EV-19 | codesign | `codesign -d --entitlements - --xml` | Same entitlements as EV-01; no sandbox entitlement |

### Open unknowns
- Spring constants for each motion preset, the default zoom, the default padding, corner radius and shadow,
  and the motion-blur samples and shutter angle. These are compiled-in, and pseudocode was unavailable.
- Pointer sampling and resampling intervals.
- How `project.bin` is encoded. It was deliberately not examined beyond the error-type names.
- The `.skmesh` encoding. It looks encrypted or compressed and was not examined further.
