# Foundations: frameworks, open-source options, and the build-vs-fork decision

Date: 2026-11-09 · Machine: macOS 26.5 (25F84), Apple silicon, Xcode 26.6 (Swift 6.3.3, macOS 26.5 SDK).

## 1. macOS capture and rendering frameworks

| Need | Options evaluated | Chosen | Why (evidence) |
|---|---|---|---|
| Screen capture | `SCStream` (12.3+), `SCRecordingOutput` (15+), `AVCaptureScreenInput` (deprecated), CGDisplayStream (deprecated) | **`SCStream` → our own `AVAssetWriter`** | Frames carry host-clock PTS, so input events logged on the same clock line up exactly with frames (`hostSeconds()` = `CMClockGetHostTimeClock`). `SCRecordingOutput` writes for you, but only reports "did start", which is too coarse for cursor sync. Both reference apps confirmed the same choice: ScreenKite imports `SCStream` + `AVAssetWriter` and not `SCRecordingOutput` ([screenkite.md §1.1](screenkite.md)); Screen Studio's native helper uses ScreenCaptureKit + AVAssetWriter ([screen-studio.md §1.1](screen-studio.md)). |
| Mic + system audio | `SCStreamConfiguration.capturesAudio`, `.captureMicrophone` (15+), AVCaptureSession | **SCStream outputs `.audio` / `.microphone`** | One clock for all tracks; written to separate AAC files so voice can be analysed and mixed independently (same layout as both reference apps). |
| Source choice | `SCShareableContent`, `SCContentSharingPicker` (14+) | **Both** | Observed during testing: a direct `SCShareableContent` capture from a terminal-hosted process makes macOS 15+ show *"…is requesting to bypass the system private window picker…"*. The app therefore offers the system picker for user-initiated recordings (`RecordingSession(filter:)`), while direct capture stays available for agents and scripts. |
| Input events | `CGEventTap` (needs Input Monitoring), `NSEvent` global monitors (keys need Accessibility), IOHID, **polling `CGEventSource`** | **Polling at 120 Hz**: pointer via `CGEvent(source:nil).location`, buttons via `CGEventSource.buttonState`, typing/scroll via `secondsSinceLastEventType` | Needs **no permission** and never sees *which* keys were pressed, yet gives exact typing timing, which is all the zoom and speed planners need. Verified on this machine with `AXIsProcessTrusted() == false` and `CGPreflightListenEventAccess() == false`: the tracker still logged clicks, pointer paths and cursor images. When Accessibility is granted, click targets are named via `AXUIElementCopyElementAtPosition`. |
| Cursor appearance | Bake into video (`showsCursor`), redraw from metadata | **Redraw**: `NSCursor.currentSystem` images fingerprinted and saved as PNG plus hotspot | Smooth, scalable, hideable cursor after the fact (both reference apps do this). |
| Compositing | Core Image on Metal, raw Metal shaders, WebGPU (Screen Studio), custom Metal compositor (ScreenKite) | **Core Image (`CIContext(mtlDevice:)`) inside a custom `AVVideoCompositing`** | One code path serves `AVPlayer` (preview), `AVAssetReader` (export) and `AVAssetImageGenerator` (frames, GIF), so preview equals export. Verified by test: mean absolute pixel difference < 3% between preview frames and decoded exports. CI's lazy graph lets us apply a single source→output transform (no double resampling). Raw Metal would add control at much higher cost; it's the upgrade path for advanced effects. |
| Cuts / speed | Manual frame scheduling, `AVMutableComposition` `insertTimeRange` + `scaleTimeRange` | **AVMutableComposition** built from one `TimeMap` | The same map drives composition, renderer, planners and quality checks. Pitch-preserving speed via `audioTimePitchAlgorithm = .spectral`. |
| Encoding | AVAssetWriter (VideoToolbox HW), AVAssetExportSession, ffmpeg | **AVAssetWriter**: H.264 / HEVC / ProRes 422; GIF via ImageIO | Hardware encoders, bitrate control, progress. ffmpeg would add a GPL/LGPL dependency for no gain. |
| Speech-to-text | `SpeechAnalyzer` + `SpeechTranscriber` (26+), `SFSpeechRecognizer`, whisper.cpp / WhisperKit, cloud | **SpeechTranscriber** (on-device, `audioTimeRange` per run), **whisper CLI** fallback | Verified here: it transcribed `say`-generated narration correctly, on-device. Screen Studio and ScreenKite both include Apple's recognizer among their providers. |
| Loudness / silence | Accelerate vDSP | **vDSP**; ITU-R BS.1770 gated loudness; adaptive-threshold silence detection | Export normalises the voice to −16 LUFS with a −1 dBFS peak cap. |
| Agent interface | MCP Swift SDK, hand-rolled JSON-RPC | **Hand-rolled stdio JSON-RPC** (protocol 2025-06-18) | ~200 lines with no dependency churn. Supports tools, image content, structured content, resources, prompts and progress. |

## 2. Open-source alternatives

### btahir/reelbird (MIT): evaluated in depth

- **Snapshot:** commit `870dd585` (2026-11-07). Swift 6.2 tools, macOS 15+, no third-party Swift dependencies.
- **Size:** ~50k lines of Swift. App 20.7k, Core 7.1k, Capture 5.5k, Render 5.3k, CLI/MCP 4.4k, Share 4.0k, AI 2.1k; tests ~14.3k.
- **Strengths:** a serious, well-structured native codebase: segmented crash-safe writers, Metal compositor, SpeechAnalyzer captions, CLI and MCP server, clean module boundaries (Core is pure Swift).
- **Builds on this machine (Xcode 26.6 / Swift 6.3.3 / macOS 26.5 SDK):** after guarding two macOS 27 SDK symbols (`LanguageModelError`, `AssetInputSequenceProvider`), all library targets and the CLI compile. The 20k-line **app target crashes the compiler** (`swift-frontend` signal 11) and also fails with "closure captures 'services' before it is declared".
- **Tests on this machine:** the share tests fail strict-concurrency checks ("passing closure as a 'sending' parameter risks data races"), and another suite hits "unable to type-check this expression in reasonable time". So the suite couldn't run without porting. The code targets a newer toolchain (Swift 6.4 / macOS 27 SDK) than this machine has.
- **Architectural fit with the defining requirement:**
  - The edit model is a single mutable `edit.json`. Undo lives in the app (`EditorModel` owns an `UndoManager`), while the CLI and MCP write `edit.json` directly (`set_edit`).
  - There is no shared operation log, no derived inverses, no selective revert, no proposals, and no approval or risk model. Agent edits and user edits can silently overwrite each other (no revision check).
  - Retrofitting that means changing the core document model *and* rewiring the 20k-line app UI that mutates it.
- **Product focus:** instant share links (S3/R2 upload while recording, HLS, a hosted "Pro" service), plus step guides. Its identity is spread through code, assets and copy (the robin, reelbird.app, cloud/).

### Others

- **Openscreen** (installed v2.1.2, MIT per its listing): Electron + web stack. That rules it out as a foundation under the "genuinely native" requirement.
- **Cap** (AGPLv3 core per its pricing/licence pages, as cited by reelbird's comparison table, checked 2026-10-12): Rust/Tauri with a webview UI. AGPL obligations make it unsuitable as the base for a product that may ship closed components.
- **Screen Studio** and **ScreenKite** are proprietary. They were studied for behaviour only ([screen-studio.md](screen-studio.md), [screenkite.md](screenkite.md)), and no code was used.

## 3. Decision

**Clean implementation (Glint), informed by reelbird's design and both reference apps.**

- The defining requirement is a shared, agent-native engine: typed operations, transactions with exact inverses, selective revert, proposals, revision checks and approvals, *used equally* by the UI, CLI and MCP. That's the centre of the system, not a feature you bolt on. Building it first and putting every surface on top was cheaper and more robust than retrofitting it under reelbird's existing app.
- reelbird's app target doesn't build on the available toolchain. Porting 20k lines of SwiftUI against a compiler crash is open-ended work that wouldn't advance the requirement.
- License isn't the blocker (MIT is compatible). Code quality isn't either: reelbird is good. The mismatch is in the core model and the product's identity.
- What carried over is ideas, not code:
  - a pure-Swift core module;
  - one renderer for preview and export;
  - an open folder-based project format;
  - a CLI and MCP server in one binary;
  - planning zooms from logged input;
  - SpeechAnalyzer captions.

  These patterns also show up independently in ScreenKite and Screen Studio.
- Revisit if needed: reelbird's segmented crash-safe writer and audio DSP are good candidates to adapt (MIT, with attribution) once the toolchains line up.
