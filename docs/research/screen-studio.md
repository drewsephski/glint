# Screen Studio 4.1.0 — Reverse-Engineering Study

Target: `/Applications/Screen Studio.app` (bundle id `com.timpler.screenstudio`, version `4.1.0-5005`, Electron, arm64).
Purpose: inform the design of an independently implemented native macOS screen recorder/editor.
Date of study: 2026-11-09.

Everything here describes behavior, data shapes and parameters in our own words. No proprietary code,
assets or branding were copied. The app was not launched, modified, or used to record. No licensing or
protection logic was bypassed (the deep-link/licensing surface is only mentioned to list it).

Confidence labels:

- **CONFIRMED**: read directly from shipped artifacts (Evidence ID or file path plus symbol/string cited).
- **INFERRED**: a reasoned conclusion from several confirmed facts, not seen as a single statement.
- **UNKNOWN**: not determined.

---

## 0. Method and artifact map

- REA `analyze_javascript_application` (summary) on `app.asar` → parent Evidence `ev_456fd056…` (E1).
  The REA graph is **partial**: the renderer bundles are obfuscated with a string-table indirection
  (every property name goes through a rotated string array). Because of that, REA seed traces for literal
  strings found nothing (E5, E6). This does not mean the features are absent.
- To read the code, the asar was extracted with `@electron/asar` into a scratch directory. A small Python
  script written for this study resolved the string-table indirection statically. It parses the array
  literal and solves the rotation checksum with its own arithmetic evaluator, then writes readable copies.
  No target code was executed.
- The main process ships as V8 bytecode (`dist-electron/index.arm64.jsc`, loaded through a `vm.Script`
  cached-data shim in `dist-electron/index.js`). Only its strings were read (`strings`).
- The native helpers in `app.asar.unpacked/bin/` were inspected with `otool -L` and `strings`. The Swift helper
  embeds many doc-comment-like descriptions, which turned out to be the richest source of evidence.

| Component | Path (inside `Contents/Resources/`) | Role |
|---|---|---|
| Main process | `app.asar/dist-electron/index.arm64.jsc` | V8 bytecode; IPC (tRPC-style procedures), windows, protocol, whisper spawning |
| Preload | `app.asar/dist-electron/preload.js` | bridge |
| Renderer/editor | `app.asar/dist/*.js` (Vite chunks, hashed names, obfuscated) | React + MobX editor, WebGPU (TypeGPU) compositor |
| Recorder/encoder service | `app.asar.unpacked/bin/screen-studio-native` (universal Swift exe, 26 MB) | ScreenCaptureKit, AVFoundation, CGEventTap, VideoToolbox, Metal, CoreML, Speech, Vision |
| N-API addon | `bin/native-node.node` | AppKit/IOSurface/QuartzCore helpers |
| N-API addon | `bin/shared-surfaces.node` | IOSurface sharing between processes (links only IOSurface, Foundation) |
| Speech models service | `bin/arm64/screen-studio-speech` + `mlx.metallib`, `MossFormer2_SE_48K_float16.safetensors`, `tf-restormer.safetensors` | MLX/Metal voice enhancement |
| Person matting | `bin/arm64/person-matte/pp-mattingv2-ss{8,9,10}-refined/*.mlmodelc` | camera cutout (Core ML) |
| Transcription | `bin/whisper-darwin-arm64` (links Accelerate only) | whisper.cpp CLI |
| ffmpeg | `bin/ffmpeg-darwin-arm64` (links VideoToolbox, AudioToolbox …) | auxiliary media processing |
| Face detect | `bin/facefinder.cascade` | pico-style cascade face finder |

---

## 1. Recording pipeline

### 1.1 Capture APIs — CONFIRMED

- `screen-studio-native` links **ScreenCaptureKit, AVFoundation, CoreMediaIO, VideoToolbox, Metal, CoreML,
  Vision, Speech, SoundAnalysis, IOSurface, CoreAudio, AudioToolbox** (`otool -L`).
- Strings: `Creating SCContentFilter from configuration`, `Created SCStream`, `SCStreamConfiguration sourceRect:`,
  `setMinimumFrameInterval:`, `setQueueDepth:`, `setShowsCursor:`, `setCapturesAudio:`,
  `setExcludesCurrentProcessAudio:`, `setColorSpaceName:`, `SCFrameStatus summary for last 5 seconds`.
- Source files named in the binary: `Recorder/DisplayRecorder.swift`, `WindowRecorder.swift`,
  `LegacyDisplayRecorder.swift`, `SystemAudioRecorder.swift`, `WebcamRecorder.swift`,
  `CameraCapture.swift`, `RecordKitMicrophoneRecorder.swift`, `LegacyMicrophoneRecorder.swift`,
  `InputRecorder.swift`, `CursorRecorder.swift`, `FocusRecorder.swift`, `ExternalDeviceRecorder.swift`,
  `SegmentedAssetWriterDelegate.swift`, `StreamingJSONWriter.swift`, `BackpressureBuffer.swift`, `Polyrecorder.swift`.
- The recorder runs in a **separate process** ("a crash there ends the recording, never the app") and talks to
  Electron over stdio (`Broadcasted over stdout that session started.`). The renderer reaches it through
  `nativeClient.send` / `nativeClient.connection` and `capture.*` procedures (`capture.prepareRecording`,
  `capture.isScreenCaptureKitSupported`, `capture.recover.*`).
- **Recording modes** (renderer `YEiLxxgG.js`, class with `typeAndSession`): `display`, `window`,
  `externalDevice`, plus a legacy display path. iOS devices are recorded over USB through
  `MobileDevice.framework` ("MobileDevice.framework lacks a function RecordKit uses"). The name **RecordKit**
  points to a third-party recording SDK being used for some inputs (INFERRED).
- **Channel model** (native validation strings): one each of `display` | `window` | `legacyDisplay`, `webcam`,
  `systemAudio`, `input`, `focus`, plus microphones ("Only one webcam channel is supported", …).

### 1.2 Frame rate — CONFIRMED

- The video descriptor's `fps` is the display's `displayRefreshRate` for display capture, and
  `initialDisplayRefreshRate` for window capture. External (iOS) devices are fixed at **60** (`YEiLxxgG.js`, getter
  `fps`). So recordings run at the panel refresh rate: 60 Hz, or 120 Hz on ProMotion.
- The native helper computes `minFrameDuration` from the refresh rate ("Computed minFrameDuration is invalid.
  displayRefreshRate:") and checks the frame cadence ("Actual frame duration much shorter than expected").
- Frames that did not change are not duplicated in the writer ("Frame repeater", "Got repeated frame with time
  before or at lastTime"). INFERRED: the output is variable-frame-rate with repeated frames handled at playback.

### 1.3 Codec / container of raw recordings — mostly CONFIRMED

- Writer: `AVAssetWriter` with `AVAssetWriterInputPixelBufferAdaptor`, and `AVOutputSettingsAssistant` presets
  `.preset1920x1080` / `.preset3840x2160` (string "Can't create AVOutputSettingsAssistant with .preset…").
- **Segmented fMP4 / HLS**: `setPreferredOutputSegmentInterval:`, `setOutputFileTypeProfile:`,
  `SegmentedAssetWriterDelegate`, `MediaPlaylistWriter`, `#EXT-X-PLAYLIST-TYPE:VOD`,
  `#EXT-X-INDEPENDENT-SEGMENTS`, `#EXT-X-MAP`, "Playlist writer … initialization segment arrived".
  The editor reads them through a custom scheme (`screenstudio-playlist://recording.mp4`), and validation
  messages mention a missing "HLS segment" / "HLS playlist". Older projects use flat files
  (`channel-1-display-0.mp4`).
- Codec: "The HEVC encoder can't turn open GOPs off, recording H.264 at the preset's bit rate." INFERRED: the
  recorder prefers HEVC (`hvc1`) and falls back to H.264 (`avc1`) at the preset bitrate. Segment interval value:
  UNKNOWN.
- Audio: AAC `.m4a` per channel (`channel-1-system-audio-0.m4a`). If a file's duration drifts from the
  session's by more than 0.05 s, it is stretched to match ("File duration is within 0.05 seconds of session
  duration", "Stretched audio file to session duration"). Gaps in audio timestamps are filled with silence
  ("Gap filling failed…").

### 1.4 System audio, microphone, camera — CONFIRMED

- **System audio**: an SCStream with `capturesAudio` and `excludesCurrentProcessAudio`
  (`SystemAudioRecorder.AudioSampleBufferQueue`). Permission text: "Screen & System Audio Recording permission".
- **Microphone**: `AVCaptureDevice` discovery by `uniqueID` with timeouts, Core Audio HAL observer
  (`AudioHALDeviceObserver.swift`), level meter (`LevelReporter`), at most 2 channels
  ("More than 2 audio channels is not supported").
- **Microphone post-processing presets** (project schema enum): `voice`, `loud`, `noise-reduction`, `podcast`,
  `channel-fix`. They are rendered offline into cached `.m4a` files (`media.renderAudio`, name suffixed by a preset hash).
  The neural stages run in the speech-models service on macOS 14+ Apple silicon: **MossFormer2** (denoise and
  de-reverb, 48 kHz) and **TF-Restormer** (bandwidth extension to about 17 kHz). There is also loudness
  normalization ("Brings speech to `targetDb`"), spectral matching ("25 third-octave levels"), and de-essing.
- **Camera**: `AVCaptureSession` + `AVCaptureVideoDataOutput`, a maximum-height setting
  (`RecordingOptions.cameraMaximumHeight`), a recorded camera-vs-mic **delay** ("Measures the camera's delay from up
  to a minute of the recording"), and face tracking (Vision plus `facefinder.cascade`). Person matting
  (PP-MattingV2 Core ML on the Neural Engine) produces the "cutout camera" layout. Mattes are cached under
  `cache/camera-matte/` as H.264.
- Camera preview frames go to the UI through a ring of shared IOSurfaces (`CameraPreviewEvent`,
  "held until it is written again three frames on").

### 1.5 Project package (`.screenstudio`) — CONFIRMED

`Info.plist` (E3) declares document types `screenstudio` ("Screen Studio Project") and `screenstudiopreset`,
both `LSTypeIsPackage = true`. File names collected from main-process strings and validation messages:

```
MyProject.screenstudio/
  project.json                 # editor state (versioned, see 1.6)
  recording/
    metadata.json              # sessions + per-channel descriptors (also metadata-raw.json, screen-studio-recording.json)
    cursors.json               # cursor image catalogue (id -> image, hotSpot, …)
    cursors/                   # cursor PNGs
    channel-1-display-0.mp4    # or an HLS playlist (.m3u8) + fMP4 segments
    channel-1-system-audio-0.m4a
    channel-?-webcam/microphone files (outputFilename recorded per session)
    mousemoves-0.json  mouseclicks-0.json  keystrokes-0.json   # per session index
    recording-markers.json
  transcripts/                 # per audio source
  cache/  (camera-matte/, rendered audio presets, …)
  preview/  Preview.png thumbnail.png
  assets/                      # imported images/audio, voice-overs
```

`recording/metadata.json` (renderer `YEiLxxgG.js`, `en` session class) holds an array of **sessions**. Pause/resume
creates new sessions, and their durations add up to the recording timeline. Each session has:
`session {processTimeStartMs, processTimeEndMs, unixStartMs}`, one of
`display {bounds, recordingScale, displayRefreshRate, outputFilename, durationMs}` /
`window {initialWindowBounds, initialDisplayRefreshRate, …}` / `externalDevice {videoSize, …}`,
`windowBoundChanges[] {processTimeStartMs, windowBounds, recordingScale}`,
`externalDeviceBoundChanges[] {contentRect, videoRotationAngleForHorizontalLevel}`,
`microphone/systemAudio/externalDeviceAudio/webcam {outputFilename}`, `keystrokes[]`, `mouseclicks[]`, `mousemoves[]`.
Event times are `processTimeMs` (a monotonic process clock). The editor converts them to timeline time with
`recordingTimeMs = processTimeMs - session.processTimeStartMs + session.recordingStartMs`.

### 1.6 `project.json` schema — CONFIRMED (`DhCS0mTK2.js` migrator, `DgH-sR-Y2.js` zod schemas)

The top level is `{ project, recording }`. `project.version` is semver, currently `"4.0.0"`. A migrator chain upgrades
3.x configs (detected by the presence of `recordingCrop`). The project contains:

- `id, name, createdAt, updatedAt, lastSavedAt, data.recordingFlags[]` (e.g. a "ScreenContinuity" flag).
- `config`:
  - `crop.rect01` (normalized rect).
  - `cursor`: `hide, size(48), set{id:"macos-tahoe"|"touch", variants}, rotationMode("velocity"|"directional"),
    rotateOnXMovementRatio(0.5), baseRotation(0), useDefaultIfAppHasLowResolution(true), alwaysUseDefault(false),
    hideNotMovingAfterMs(null), loopPositionBeforeEndMs(null), stopMovementInLastPartMs(0),
    removeShakeTreshold(500), optimizeOriginalTypes(true), followRecordedPositionOnHover(true),
    clickEffect(null | {type:"ripple", pullSize01?} | {type:"circle"})`.
  - `animations`: `mouseMovementSpring`, `screenMovementSpring` (spring objects, see §3.4), `motionBlurAmount(1)`.
  - `styles`: `screenBorderRadius(16)`, `cameraBorderRadiusRatio01(0.25)`, `screenInset{size, origin01, alpha .5, color}`,
    `background{type: color|gradient|image|system|unsplash, color, gradient{start,end,stops}, blur}`,
    `shadow{intensity .3 [0–.6], distance 25 [0–100], angle 90 [0–180], blur 20 [0–30], isDirectional}`.
  - `output{aspectRatio:"auto"|number, paddingRatio01 (0.10 when migrated; UI slider 0–0.25), avoidEmptyZoomArea}`.
  - `camera{hide, mirror, aspectRatio, enableFaceTracking, hideDuringSilenceMs, lut, lutIntensity, grain, sharpen01,
    crop01, delayAdjustmentMs, background{blurAmount01, edgeFalloff01 .2}}`.
  - `captions{font serif|sans-serif|mono, sizeRatio .05, color, backgroundColor, position01{.5,1},
    wordsReveal line-by-line|word-by-word, lineGrowth entire-line|left-anchored|centered,
    wordEntrance appear|fade-in|slide-in, enableTranscript, showSoundLabels, enableShortcuts, hiddenShortcuts,
    showShortcutsWithSingleLetters, shortcutsSizeRatio .1}`.
  - `audio{volume, muteMicrophone, microphoneAudioPreset, muteSystemAudio, backgroundAudioFileName,
    backgroundAudioVolume .05, muteBackgroundAudio, clickSoundEffect apple-magic-mouse|logitech-mx-master|null,
    clickSoundEffectVolume .25}`.
  - `device{enableMockup true, frameKey}`. `processing{improveRecordingQuality01 .5, autoMaskSensitiveData,
    sensitiveDataExpandPx 8, sensitiveDataCustomPhrases[], autoMaskFaces}`. `zooms{startAnimationEarly false}`.
  - `defaultLayout{type camera-overlay|split-screen|cutout-camera, cameraOverlay{overlayCameraPosition01 (8 anchor
    points), overlayCameraSizeRatio01, overlayCameraPaddingRatio01 .5, overlayCameraAspectRatio, overlayZoomedCameraScale .8},
    splitScreen{splitDirection auto|horizontal|vertical, splitFlip, splitScreenRatio01, enablePadding},
    cutoutCamera{cutoutCameraPositionX01 1, cutoutCameraSizeRatio01 .5, cutoutCameraZoomedScale .8}}`.
- `scenes[]` (type `"recording"`): `id, name, index, zooms[], slices[], layouts[], masks[], voiceOvers[]` (see §4).

---

## 2. Cursor and input tracking

### 2.1 Capture — CONFIRMED / INFERRED

- Clicks, keystrokes and moves come from a **CGEventTap** (`Recorder.EventTap`, `CGEventTapAction`,
  `eventTapForEvents`, "needs the Accessibility permission to record your clicks and keystrokes"). Events are
  converted to `NSEvent` for decoding ("Can't create NSEvent from CGEvent").
- The **cursor image** is sampled separately by `CursorRecorder`, which keeps a "cursor timeline". Input events are
  matched to the nearest captured cursor ("Input event occured after last cursor capture, falling back to last
  known cursor"). When the cursor shape changes without a move, synthetic move events are inserted
  ("Generated mouse move events for cursor changes between mouse moves"). System cursors are preloaded and
  written as PNGs to `recording/cursors/` with a `hotSpot`. Visible-pixel bounds are measured ("the box of the
  pixels at least as opaque as …"). SVG cursors are measured by the renderer.
- System cursor recording is turned off in SCStream (`setShowsCursor:`), and the cursor is re-rendered in the editor.
  INFERRED: `showsCursor=false`.
- **Sampling rate**: moves are event-driven. Each event tap callback produces an entry, so the rate follows the HID/OS
  coalescing rate, typically 60–125 Hz, rather than a fixed timer. INFERRED. No fixed polling constant was found:
  UNKNOWN.
- Event JSON fields (native key strings + renderer usage):
  - moves/clicks: `{type: mouseMoved|mouseDragged|mouseDown|mouseUp, x, y, cursorId, button, processTimeMs, unixTimeMs}`
    in global screen points. The editor subtracts the initial capture bounds (`getMouseEventsRelativeToInitialBounds`).
  - keystrokes: `{type: keyDown|keyUp, character, isARepeat, activeModifiers, processTimeMs}`.
- Files are written incrementally with a streaming JSON writer (`StreamingJSONWriter.swift`), which survives crashes
  (`capture.recover.*`).

### 2.2 Cleaning the cursor path — CONFIRMED (`B39sgn5K.js` functions around `removeShakeTreshold`)

1. **Outlier/"shake" removal** (`removeShakeTreshold`, default 500). An event is dropped when *both* of the next two
   events are more than the threshold away by Manhattan distance (|dx|+|dy|). If the dropped event is a
   `mouseDown`, the matching `mouseUp` is dropped too. A threshold of 0 disables this step.
2. **Decimation for zoom grouping**: consecutive moves closer than **10 px** (Euclidean) are collapsed. Clicks are always kept.
3. **Hide when idle** (`hideNotMovingAfterMs`, default off): the cursor shows only if some event lies within that many ms of
   the playhead. It is also hidden per slice (`slice.hideCursor`), and before the first event.
4. **Loop to start** (`loopPositionBeforeEndMs`): a copy of the first position is appended near the end, so a
   looping clip returns the cursor to where it began.
5. When the cursor id changes on mouse-up to a different id and the next move comes more than 250 ms later, an `arrow`
   cursor is inserted. This avoids I-beam/hand cursors "sticking".

### 2.3 Smoothing — CONFIRMED

- The cursor position is driven by a **damped spring** toward the recorded position (`mouseMovementSpring`).
  `null` means no smoothing ("None"). A slice can disable it (`disableSmoothMouseMovement`).
- Defaults and UI presets (`CpXpNcFh.js`, `Brm6UpoL2.js`): see §3.4. Default (`me` config) = stiffness 125, damping 12,
  mass 1.5, clamp on, precision 0.002.

### 2.4 Cursor rotation/tilt — CONFIRMED (`Os`, `ks` constants)

- `velocity` mode: an exponential moving average of horizontal velocity (time constant **120 ms**, integrated in
  **16 ms** sub-steps). Tilt = clamp(vx[px/ms] × **12°** × `rotateOnXMovementRatio`(0.5), ±**20°**). The tilt is
  then sprung (k=120, c=8, m=1). Emission is skipped when the change is below 0.0015 rad. Startup is held calm for
  500 ms. An entry "teleport" is detected above 15 px/ms.
- `directional` mode: the arrow turns toward the heading (align rate 5e-5/px, saturation 3 px/ms, angular
  damping 100 ms, max turn 0.4°/ms, max ±135° from a neutral heading of −112.5°, min travel 4 px). Spring k=320, c=28, m=1.

### 2.5 Size — CONFIRMED

`size` is in output px (default **48**). Legacy multipliers are mapped: values ≤5 become `max(v,0.5)×16`, and values >128 become
`min(v/16,128)`. When an app's cursor bitmap has low resolution, the bundled vector set is used instead
(`useDefaultIfAppHasLowResolution`). Bundled sets: `assets/cursors/sets`, `cursor-macos.svg`, `touch-cursor.svg`.

### 2.6 Click effects — CONFIRMED (GPU shader params in `B39sgn5K.js`)

- **circle**: visible **450 ms**. The radius eases out cubic from 0.002 to 0.03 (× a scale), and the opacity is
  `smoothstep(0,.15,t)·(1−smoothstep(.15,.9,t))`.
- **ripple** (screen-space displacement): visible **1000 ms**. Amplitude is `e^(−3t)·sin(9.4t)` with t in seconds over 1 s,
  and the ring expands at 0.2× per second. Wave width 0.05, pull 0.015, chromatic split 0.004. The default
  `pullSize01` is 0.04.
- Click **sounds**: a down, up and click `.wav` for two mouse models. Default volume 0.25.

---

## 3. Automatic zoom and camera

### 3.1 Generating zoom ranges — CONFIRMED (`DXXvn2Sd2.js`: `Le`, `Re`, `ze`, `Be`, `Ve`; merge in `CnUZYiys2.js`)

- Input: **click events only** (`mouseclicks`, both down and up). Typing does **not** create zooms (no keystroke input
  found in the generator; INFERRED absence). External-device recordings get no auto zooms.
- Clicks in the final **1000 ms** are ignored.
- Each click at time *t* produces a window **[t − 300 ms, t + 2500 ms]**, clamped to `[1, duration − 800 ms]`.
- Windows are sorted and merged repeatedly until stable. Ranges that touch are joined, and a range is extended
  when the next one starts within **2500 ms** of its end (`fillGap = 2.5 s`). The result: clicks less than about
  2.5 s apart become one zoom.
- Each range gets: `zoom = 2.0` (default level), `type = "follow-click-groups"`, `hasInstantAnimation = false`,
  `isDisabled = false`.
- Zoom level limits in the editor: **min 1, max 4, step 0.2**. Zoom items: min duration 100 ms; a new manual zoom
  lasts 3000 ms. Layout items: min 500 ms.

### 3.2 Where the camera points — CONFIRMED (`B39sgn5K.js`: `es` group class, `ts`, `qo`, `Qu`, `td`, `nd`)

- Zoom `type`: `follow-click-groups` and `follow-mouse` (both "auto"), or `manual` (`manualTargetPoint` in 0–1 of the
  cropped screen; snapping, ⌘ to disable). `presentation`: `screen` ("Classic") or `loupe` ("Glass Loupe", radius01 .35,
  bevel .2, chromatic aberration .5, with a slow drift of ±1.25 % over a 12–18 s period).
- Auto targeting:
  1. Take the decimated events inside the zoom range. Include the last event before the start, re-stamped at the start.
  2. Walk them in time order and **group** them. An event joins the current group while the group's bounding box stays
     within **half of the visible source area at that zoom level** (in each axis). Otherwise a new group starts, and the
     previous group's end time is set to this event's time.
  3. A group's center is the **dwell-time-weighted mean** of its positions. Each sample is weighted by the time until
     the next sample, or 100 ms for the last one.
  4. At playhead *t*, the camera targets the center of the latest group whose first event is ≤ *t*, falling back to the
     next group. The target is (center, scale = zoom).
- The camera reaches its targets through the **screen movement spring** (§3.4). This applies to the zoom scale as well as
  the position, including enter and exit. The result is a smooth pan between click clusters instead of
  per-frame following.
- `startAnimationEarly`: the zoom begins **350 ms** (`animationLeadInMs`) before the range, so it is fully in when
  the playhead reaches it. `hasInstantAnimation`: the spring is replaced by an instant snap during the range plus 50 ms.
- With the full-screen camera layout, the previous zoom is held until 85 % of that layout segment.

### 3.3 Motion blur — CONFIRMED (TypeGPU shader + config)

- Strength = `motionBlurAmount` (0–1, default 1) × (playback fps / 60). It applies to moving elements (screen and
  cursor) along the motion path.
- Quality per mode, as sample budgets: export 16 samples with a 4-texel fetch span. Paused preview uses 16, and
  playing preview uses 6 samples with a 16-texel span. "Smear" quality is 32 for export and 4 during playback.
- Sharpening and "detail" passes are faded by motion. Full strength applies at ≤4 device px of motion, falling to
  zero strength at 28 px (other variants: 4→8 and 10→30).

### 3.4 Spring physics — CONFIRMED (`CpXpNcFh.js`)

- Model: a mass-spring-damper, `a = (−k·(x − target) − c·v) / m`, integrated with **semi-implicit Euler at 1 ms
  fixed steps** inside `advanceTimeBy` (a hard cap of 10 000 steps). Rest is reached when |v| and |x − target| are both
  below `precision × max(1, |Δ|)`, where Δ is the jump distance at retarget. Then the value snaps to target.
- `clamp: true` means no overshoot. While moving toward the target faster than `|Δx|·√(k/m)`, damping is raised to
  critical (`2√(k·m)`).
- Settle time is precomputed by simulating 0 → 1000 (cached per config). Calls longer than the settle time snap to target.
- Sets of springs animate numeric leaves of nested objects (rects, colors).

| Preset (UI name) | stiffness | damping | mass | Used for |
|---|---|---|---|---|
| Project default (both screen and cursor) | 125 | 12 | 1.5 (clamp, precision 0.002) | screen camera + cursor |
| Screen "Focused" | 250 | 40 | 2.25 | quick-settling camera |
| Screen "Smooth" | 170 | 50 | 3 | fluid camera |
| Cursor "Smooth" | 470 | 70 | 3 | cursor |
| Cursor "Medium" | 340 | 60 | 3 | cursor |
| Cursor "Rapid" | 530 | 40 | 1 | cursor |
| Cursor "None" | — | — | — | raw positions |
| Instant | 1 | 1 | 0 | mass 0 → snap |
| Captions | 425 | 12 | 1.5 (clamp) | caption layout |
| Misc. UI | 6000/350/1; 430/30/1; 500/32/1.6 | | | panels, timeline |

UI ranges: rigidity (stiffness) 5–600, smoothness (damping) 5–200, momentum (mass) 0.1–15.

---

## 4. Timeline model — CONFIRMED (`DXXvn2Sd2.js`, `DhCS0mTK2.js`)

- A project holds `scenes[]` that play one after another. Each scene has independent **timeline collections**
  (`TimelineCollection`), and every item is stored in **source time** (`sourceStartMs`, `sourceEndMs`):
  - **slices** (clips): `{id, timeScale, sourceStartMs, sourceEndMs, volume, systemAudioVolume,
    externalDeviceAudioVolume, hideCursor, disableSmoothMouseMovement}`. Min 100 ms.
    - **Trim/cut** = gaps between slices (source ranges not covered by any slice). **Split** = one slice becomes two.
      Adjacent slices can be merged (`mergeWith`).
    - **Speed**: `timeScale` multiplies duration (playback = source × timeScale), so speed = 1/timeScale.
    - A resolver maps time in both directions (`sourceToPlaybackTime`, `playbackToSourceTime`) by piecewise-linear
      mapping over the slice links.
  - **zooms**: `{id, zoom, type, presentation, manualTargetPoint, loupeOptions, hasInstantAnimation, isDisabled, range}`.
  - **layouts** (camera layout segments): `{id, version 2, type camera-overlay|screen-only|fullscreen-camera|split-screen|cutout-camera, per-type overrides, range}`. Min 500 ms, default 3000 ms.
  - **masks**: `{id, type sensitive-data|highlight, bounds, blur, highlightMaskOpacity, isDisabled, range}`. Masks
    animate with a spring. There is also auto sensitive-data masking by OCR, with an expand of 8 px and custom phrases, and auto face masking.
  - **voiceOvers**: `{id, sourceStartMs, voiceoverDurationMs, fileName, timeScale, volume, source, attachMode, hideRecording}`.
    Generation (`speech.generateVoiceoverForProject`, `speech.voices`) is a cloud TTS feature (INFERRED).
  - **captions / shortcuts** come from the transcript and keystrokes, not from timeline items. Keyboard
    shortcuts are grouped when the same shortcut repeats within 2000 ms.
- **Undo/redo**: patch based. Each `history.update(target, change)` records undo/redo patches (immer-style).
  Patches are coalesced through a **100 ms** debounced buffer into one step. The stack holds at most **1000** steps,
  and redo is truncated on a new edit. Every model setter goes through `project.history.update`.

---

## 5. Preview rendering — CONFIRMED / INFERRED

- The editor compositor is **WebGPU**: `getContext('webgpu')`, `requestAdapter`, `importExternalTexture`. Shaders are
  written with **TypeGPU** (44 `'use gpu'` functions; `__TYPEGPU_META__`). WGSL appears in several chunks.
  There is no WebGL usage in app code.
- Decoded frames arrive as **IOSurfaces** shared from the native decoder/scrubber process
  (`shared-surfaces.node`, `sharedSurfaces.getVideoFrame`, "Shared surfaces are BGRA or video-range NV12"). They are
  wrapped as `VideoFrame` and imported as external textures (INFERRED from both sides). A decode cache keeps up to
  36 frames, with 6 decoded ahead during export.
- Stage: background (solid, gradient, bundled wallpapers, macOS system wallpaper via the `wallpaper` module,
  Unsplash, custom image, blur, "frost"), screen rect inset by padding (`paddingRatio01`), rounded corners
  (`screenBorderRadius` in source px × pixel scale; UI 0–128, suggested 0/12/16/20/26), and a drop shadow
  (intensity, distance, angle, blur; directional option). The shadow throw is limited by a max-reach ratio.
- Device frames: bitmaps under `assets/devices/` (MacBook, iMac, iPad, iPhone…). There are also **parametric** iPhone
  frames described numerically (outer size, screen offset/size, screen and frame corner radii, roundness .6, body inset,
  export density 4). They are used for iOS-device or Continuity recordings, and `enableMockup` defaults to true.
- Camera: overlay, split, cutout (matte), or full screen. Optional LUT, grain, sharpen, and background blur for cutouts.
  The camera is hidden during silences longer than `hideDuringSilenceMs` (silence threshold 0.1, 50 ms windows, 500 ms margins).

---

## 6. Export — CONFIRMED (`CHdhxnRg.js`, `KYxD90AB2.js`, native strings)

- Frames are rendered by the same WebGPU compositor in a render worker (`--render-worker`). The GPU converts them to
  planar 4:2:0 BT.709 full range, and they are handed to the native encoder as IOSurface handles. Each encode runs in its own process.
- **Encoders**:
  - H.264: a linked Rust "**screenvideo-encoder** 0.1.0 – fast H.264 encoder" (`RustH264Writer`). It can share work with
    the VideoToolbox hardware encoder at matched quality ("hybrid"). The split is planned from a per-frame motion
    score (0–255), so results are deterministic.
  - HEVC: hardware (VideoToolbox) only. ProRes: AVAssetWriter (hardware ProRes engine where available).
  - GIF: an in-house encoder with one OkLab palette, position-fixed blue-noise dithering, unchanged pixels carried over,
    and lossy LZW budgeted by texture. Palette frames are sampled first.
  - Audio: mixed in native code with the same renderer used for preview, as AAC 48 kHz stereo. The audio is muxed beside the video.
- **Formats/presets**:

| Format | FPS options | Heights | Quality modes |
|---|---|---|---|
| MP4 (H.264 / HEVC / both) | 60, 50, 30, 25, 24, 20, 10 | 720, 1080, 2160 | studio, social-media, web-high, web-low (web ≤ 1080p) |
| ProRes (422 LT / 422 / 422 HQ / 4444) | same | 720, 1080, 2160 | studio |
| GIF (loop by default) | 50, 30, 25, 20, 15, 10 | 480, 720, 1080 | studio, social-media |

  Defaults: MP4 60 fps 720p social-media H.264; ProRes 60 fps 1080p 422 HQ; GIF 15 fps 480p social-media;
  shareable-link 1080p60 social-media. Width follows the stage aspect ratio.
- **Rate control**:
  - Bitrate budget = width × height × fps × bpp, with bpp per frame of web-low **0.0075**, web-high **0.0175**,
    social **0.05**, studio **0.3**.
  - The software H.264 path uses **CRF**: web-low 42, web-high 30, social 24, studio 14.
  - The hardware path (HEVC) uses bitrate: max(0.93 × budget, w·h·fps·0.01).
  - Size estimates use a log-interpolated CRF→bpp table at 1080p60 (14→0.0816, 24→0.0221, 30→0.011, 42→0.0038) scaled
    by (pixels/1080p)^0.78 × (fps/60)^0.57.
  - ProRes rates are 1.21/2.09/3.36/4.74 bits per pixel per frame at 1080p, scaled by pixels^0.84.
  - MP4 audio is about 165 kb/s. ProRes audio is PCM 48 kHz/24-bit stereo.
- Targets: file, clipboard, or a shareable link (upload to the vendor cloud).

---

## 7. Automation / scripting surface — CONFIRMED / INFERRED

- **No public CLI or scripting API** was found. No AppleScript dictionary (`.sdef`) exists in Resources (CONFIRMED by
  listing). Internal flags in the main process: `--render-worker`, `--export-frames-addon=`, `--start-hidden`,
  `--stage-bench`, `--prod`. These are internal; INFERRED not user-facing.
- **URL scheme**: the main process calls `setAsDefaultProtocolClient` and handles `open-url` → IPC `deeplinks.deeplinkOpened`.
  Known routes are only **license activation**: `activate/:key` and `activate-by-token/:token` (`D-mRfixG.js`).
  The scheme name is INFERRED to be `screenstudio`. Note: `Info.plist` has **no `CFBundleURLTypes`** (E3), so system-wide
  registration of the scheme is uncertain (UNKNOWN).
- **Document opening**: `.screenstudio` / `.screenstudiopreset` packages through Finder (`project.fileOpenRequest`).
- **Global shortcuts** (`globalShortcut.register`) for start, stop, pause and markers. Preset import/export
  (`presets.import/create/apply/sync`).
- Electron fuses (E2): `RunAsNode` **enabled**, `EnableNodeOptionsEnvironmentVariable` enabled, `EnableNodeCliInspectArguments` enabled,
  embedded ASAR integrity validation **disabled**, `OnlyLoadAppFromAsar` disabled. This is a security posture observation only.

---

## 8. Captions and transcription — CONFIRMED

- Three engines, used in this order (main-process strings):
  1. **Cloud**: "Transcript Generation (ElevenLabs)", `beginCloudTranscribeIfNeeded`. On failure: "falling back to system".
  2. **macOS speech recognizer** in the native helper. It needs **macOS 26** ("Speech transcription needs macOS 26 or
     later"), works per locale (`en_US`), downloads models on demand, and streams words as they are recognized (`onWord`).
  3. **Local whisper.cpp** (`whisper-darwin-arm64`, flags `--model --language --prompt --max-len --output-srt
     --output-file --no-timestamps --print-progress`). It uses ggml **base/small/medium** models downloaded from the vendor
     CDN, with input as 16 kHz mono 16-bit WAV.
- Transcripts are stored per source (microphone session, voice-over) under `transcripts/`. They can be edited
  (`captions.updateTranscript`, "Edit by transcript") and exported as SRT (`captions.exportTranscriptAsSRT`).
- Caption rendering: a rolling window of words within **1200 ms** of the playhead (at most 120 words each way). Words are laid
  out on lines with a 450 ms fade proximity, 8 px minimum gaps, and a 6.5 px-per-character width estimate. Words
  appear line-by-line or word-by-word with appear/fade/slide entrances. Layout uses a spring (k 425, c 12, m 1.5).
  Fonts: system SF, Instrument Serif, Geist Mono.
- Speech ranges and silence detection are also used for camera auto-hide and silence trimming (`project.silenceChunks`,
  `media.speechRanges`).

---

## Design implications for our implementation

Concrete defaults worth matching (our own parameterization; values are behavioral targets, not code):

1. **Capture**: use ScreenCaptureKit with the system cursor turned off. Capture at the display's refresh rate (min frame
   interval 1/refresh). Write **segmented fMP4 (HLS VOD playlist)** through AVAssetWriter, so a crash leaves playable
   segments. Prefer HEVC and fall back to H.264 when closed GOPs are needed. Keep one file per channel (display or
   window, system audio, mic, camera) and per session (pause = new session).
2. **Recorder process isolation**: run capture in a helper process with a streaming JSON event writer plus a
   recover/finalize step for unfinished recordings.
3. **Input logging**: CGEventTap (listen-only) for `mouseMoved/Dragged/Down/Up` and `keyDown/keyUp` (character,
   repeat, modifiers). Use a monotonic `processTimeMs` and store the wall clock once per session. Capture cursor images
   separately (PNG + hotspot, deduplicated by id), and insert a synthetic move when only the cursor shape changes.
4. **Path cleaning**: drop single-sample jumps (both next two samples >500 px away by Manhattan distance), collapse moves
   under 10 px for zoom logic, and force an arrow cursor if a non-arrow cursor persists more than 250 ms after mouse-up.
5. **Spring**: implement a deterministic, time-based spring (mass, stiffness, damping, optional no-overshoot clamp,
   relative precision 0.002) with 1 ms fixed sub-steps, so preview and export match frame for frame. Default for
   **both** the camera and cursor: **k = 125, c = 12, m = 1.5, clamp on**. Offer presets around Focused (250/40/2.25)
   and Smooth (170/50/3) for the camera, and cursor presets 470/70/3, 340/60/3, 530/40/1, plus "off".
6. **Auto-zoom generation**: per click, **[−300 ms, +2500 ms]**. Skip the last 1 s, keep a 0.8 s safety margin at the end,
   and merge when gaps are ≤ **2.5 s**. Default zoom **2.0×** (range 1–4, step 0.2), with an optional lead-in of **350 ms**.
7. **Camera targeting**: cluster pointer samples while the cluster fits in **half the zoomed viewport**. Aim at the
   dwell-weighted centroid of the active cluster, and let the spring do all motion, including zoom-in and zoom-out.
8. **Motion blur**: scale by `amount × fps/60`. Use 16 samples for export and about 6 for live preview. Fade sharpening
   from 4 px to 28 px of per-frame motion.
9. **Cursor polish**: 48 px default size. Velocity tilt with a 120 ms EMA, 12° per px/ms × 0.5, capped at ±20°, sprung
   with k = 120, c = 8, m = 1. Click circle 450 ms (cubic ease-out radius, smoothstep in and out). Ripple 1 s, damped
   sine (decay 3/s, 9.4 rad/s).
10. **Stage defaults**: padding 10 % (slider 0–25 %), screen corner radius 16 px, shadow intensity 0.3 / distance 25 /
    angle 90° / blur 20, camera overlay size about 35–50 % of the short side with 0.25 roundness, camera scale 0.7–0.8
    while zoomed.
11. **Timeline**: keep everything in source time. Represent clips as ordered slices with `timeScale` (cuts are gaps), and
    add parallel zoom, layout, mask and voice-over tracks. Use a piecewise-linear source↔playback resolver. Implement
    patch-based undo with a 100 ms coalescing window and a 1000-step cap.
12. **Export**: offer MP4 (H.264/HEVC), ProRes and GIF at 10–60 fps and 720/1080/2160 heights (GIF 480–1080).
    Quality maps to **bits per pixel per frame** of 0.0075/0.0175/0.05/0.3, or for x264-like CRF 42/30/24/14. Use
    VideoToolbox for HEVC and ProRes, AAC 48 kHz stereo audio, and render on the GPU into 4:2:0 BT.709 surfaces passed
    zero-copy (IOSurface) to the encoder.
13. **Transcription**: use Apple's on-device speech recognizer where available (macOS 26), with whisper.cpp (16 kHz mono)
    as the fallback. Keep transcripts per audio source, and support SRT export and transcript-driven editing.

---

## Evidence ledger

| ID | Source | What it supports |
|---|---|---|
| E1 | REA `ev_456fd0562542dfe442cc07de202c04c80c6a5fb328f981d431bff02315caa512` (summary `ev_56cc66f232b62e659b2db991e49c7def3f01772ae771760533319a7b2ef4c9e9`) | app.asar inventory: 3201 relevant files, 1750 parsed JS, graph partial; asar sha256 `3664b314…5359` |
| E2 | REA `ev_550740735a091f94514d93462e16fd36651425e36b3e9960f62ca17d7b3f331c` | Electron fuse states (§7) |
| E3 | REA `ev_be06914ef30716216e69e16488b46d7ca52f7df941b821de8c6e2ea3c9f95794` | Info.plist: document types, no URL types, usage strings, min macOS 12.0. (The tool's `subject` metadata names another app, but `source_path` is this app's plist; values verified.) |
| E4 | REA `ev_6fb7e182301c7c430a3030dc9ac859301b370bbce681a6b9f85451ee8b8fad0e` | Native addons: `bin/native-node.node`, `bin/shared-surfaces.node`, keytar, node-mac-permissions |
| E5/E6 | REA traces `ev_724cd7652e4fac4fa2e27106ab7aa01df196dd2be4d2bc3f0a64421ededf431d`, `ev_8916d7bb3f6829c8872dbc5f5a86158e9fbd13bbbf8da9f2dae67c9b6ef16a78` | No-match because of obfuscated string tables (limitation, not absence) |
| F1 | `dist/DhCS0mTK2.js` (project migrator) | project.json v4 shape and 3.x→4.0 defaults (§1.6) |
| F2 | `dist/DgH-sR-Y2.js` (zod schemas) | cursor, captions, camera, audio, layout, processing and zoom config defaults; parametric device frames |
| F3 | `dist/CpXpNcFh.js` | spring integrator, clamp rule, settle-time cache, spring presets |
| F4 | `dist/DXXvn2Sd2.js` | auto-zoom generator (300/2500/1000/800 ms, zoom 2), undo history (100 ms, 1000), slices/timeScale, min durations |
| F5 | `dist/CnUZYiys2.js` | range merge with fillGap; source↔playback resolver |
| F6 | `dist/B39sgn5K.js` | click grouping, dwell-weighted center, shake removal, 10 px decimation, cursor tilt, click effects, motion-blur quality, lead-in/instant-snap windows |
| F7 | `dist/DcSzqHBq.js`, `dist/BbPLqgNs2.js` | zoom editor: types, Classic/Loupe, level 1–4 step 0.2 |
| F8 | `dist/Brm6UpoL2.js` | animation UI presets and slider ranges, motion blur 0–100 % |
| F9 | `dist/CHdhxnRg.js`, `dist/KYxD90AB2.js`, `dist/Bov2FPQs2.js` | export formats, fps/height tables, defaults, bpp/CRF/ProRes rate models |
| F10 | `dist/YEiLxxgG.js` | recording session model, fps source, event offsetting, audio preset rendering |
| F11 | `dist/oLirRMcf2.js` | caption word window constants; WebGPU canvas context |
| F12 | `dist/D-mRfixG.js`, `dist/DSvfDBmw2.js` | deep-link routes (license activation only) |
| F13 | `dist/vPAFtiYS.js`, `dist/zX0Wg68M.js` | WebGPU device and external textures; shared-surface VideoFrame bridge |
| N1 | `bin/screen-studio-native` (`otool -L`, `strings -arch arm64`) | frameworks; SCStream config setters; AVAssetWriter/HLS segmenting; CGEventTap; cursor recorder; ProRes/GIF/MP4 encoders; Rust H.264 encoder; macOS 26 speech; MossFormer2/TF-Restormer; camera delay/matte |
| N2 | `bin/whisper-darwin-arm64`, `bin/arm64/screen-studio-speech`, `bin/ffmpeg-darwin-arm64`, `bin/shared-surfaces.node`, `bin/native-node.node` (`otool -L`) | linked frameworks per helper |
| M1 | `dist-electron/index.arm64.jsc` strings | package file names, whisper flags/models, ElevenLabs fallback, `setAsDefaultProtocolClient`, `open-url`, internal CLI flags |

No REA binary sessions were opened (only static JS/plist/fuse analyses), so none needed closing.
