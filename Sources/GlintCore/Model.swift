import Foundation

// Conventions used throughout the document:
// - Times are seconds. Fields named `start`/`end`/`time` on timeline items are SOURCE (recording) time unless
//   documented otherwise, so edits stay anchored to content when cuts or speed changes move the output timeline.
// - Positions are normalized to the recorded screen video, origin top-left, x right, y down, in [0, 1].

public struct TimeRange: Codable, Hashable, Sendable {
    public var start: Double
    public var end: Double
    public init(_ start: Double, _ end: Double) { self.start = start; self.end = end }
    public var duration: Double { max(0, end - start) }
    public func contains(_ t: Double) -> Bool { t >= start && t < end }
    public func overlaps(_ o: TimeRange) -> Bool { start < o.end && o.start < end }
    public func clamped(to r: TimeRange) -> TimeRange? {
        let s = max(start, r.start), e = min(end, r.end)
        return e > s ? TimeRange(s, e) : nil
    }
}

public struct NormPoint: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double
    public init(_ x: Double, _ y: Double) { self.x = x; self.y = y }
    public static let center = NormPoint(0.5, 0.5)
    public func distance(to o: NormPoint) -> Double { ((x - o.x) * (x - o.x) + (y - o.y) * (y - o.y)).squareRoot() }
}

public struct NormRect: Codable, Hashable, Sendable {
    public var x: Double, y: Double, width: Double, height: Double
    public init(x: Double, y: Double, width: Double, height: Double) { self.x = x; self.y = y; self.width = width; self.height = height }
    public static let full = NormRect(x: 0, y: 0, width: 1, height: 1)
    public var center: NormPoint { NormPoint(x + width / 2, y + height / 2) }
    public func contains(_ p: NormPoint) -> Bool { p.x >= x && p.x <= x + width && p.y >= y && p.y <= y + height }
}

public struct RGBA: Codable, Hashable, Sendable {
    public var r: Double, g: Double, b: Double, a: Double
    public init(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) { self.r = r; self.g = g; self.b = b; self.a = a }
    public init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6 || s.count == 8, let v = UInt64(s, radix: 16) else { return nil }
        if s.count == 6 {
            self.init(Double((v >> 16) & 0xff) / 255, Double((v >> 8) & 0xff) / 255, Double(v & 0xff) / 255, 1)
        } else {
            self.init(Double((v >> 24) & 0xff) / 255, Double((v >> 16) & 0xff) / 255, Double((v >> 8) & 0xff) / 255, Double(v & 0xff) / 255)
        }
    }
    public var hex: String {
        String(format: "#%02X%02X%02X", Int((r * 255).rounded()), Int((g * 255).rounded()), Int((b * 255).rounded()))
    }
    public static let white = RGBA(1, 1, 1), black = RGBA(0, 0, 0)
}

/// Who made a change. Every transaction and proposal records its author so the UI can show agent activity.
public struct Author: Codable, Hashable, Sendable, CustomStringConvertible {
    public enum Kind: String, Codable, Sendable { case user, agent, system }
    public var kind: Kind
    /// e.g. "app", "cli", "claude-code", "planner".
    public var name: String
    public init(_ kind: Kind, _ name: String) { self.kind = kind; self.name = name }
    public static let app = Author(.user, "app"), cli = Author(.user, "cli"), system = Author(.system, "glint")
    public var description: String { "\(kind.rawValue):\(name)" }
}

public enum Origin: String, Codable, Sendable { case auto, manual, agent }

// MARK: - Media

public struct MediaInfo: Codable, Hashable, Sendable {
    /// Paths relative to the project bundle.
    public var screen: String
    public var microphone: String?
    public var systemAudio: String?
    public var camera: String?
    /// Pixel size of the screen video.
    public var width: Int
    public var height: Int
    /// Backing scale of the recorded display (2 on Retina) — used to size the cursor.
    public var scale: Double
    public var duration: Double
    public var frameRate: Double
    public init(screen: String, microphone: String? = nil, systemAudio: String? = nil, camera: String? = nil,
                width: Int, height: Int, scale: Double, duration: Double, frameRate: Double) {
        self.screen = screen; self.microphone = microphone; self.systemAudio = systemAudio; self.camera = camera
        self.width = width; self.height = height; self.scale = scale; self.duration = duration; self.frameRate = frameRate
    }
}

public struct RecordingInfo: Codable, Hashable, Sendable {
    public var startedAt: Date
    public var source: String          // "display:2", "window:1234", …
    public var sourceName: String?
    /// Display frame in global points (top-left origin), for mapping input events.
    public var displayFrame: [Double]  // x, y, w, h
    public var recordedBy: Author
    public var inputTracking: String   // "poll" (no permission needed) or "eventTap"
    public init(startedAt: Date, source: String, sourceName: String?, displayFrame: [Double], recordedBy: Author, inputTracking: String) {
        self.startedAt = startedAt; self.source = source; self.sourceName = sourceName
        self.displayFrame = displayFrame; self.recordedBy = recordedBy; self.inputTracking = inputTracking
    }
}

// MARK: - Timeline items

public struct ZoomSegment: Codable, Hashable, Sendable, Identifiable {
    /// Encoded as `"cursor"` or `{"x": …, "y": …}`.
    public enum Focus: Codable, Hashable, Sendable {
        /// Follow the (smoothed) cursor, keeping it inside the zoomed view.
        case followCursor
        /// Hold a fixed point.
        case point(NormPoint)

        public init(from decoder: any Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let s = try? c.decode(String.self) {
                guard ["cursor", "follow", "followCursor", "auto"].contains(s) else {
                    throw DecodingError.dataCorruptedError(in: c, debugDescription: "focus must be \"cursor\" or {x, y}")
                }
                self = .followCursor
            } else {
                self = .point(try c.decode(NormPoint.self))
            }
        }
        public func encode(to encoder: any Encoder) throws {
            var c = encoder.singleValueContainer()
            switch self {
            case .followCursor: try c.encode("cursor")
            case .point(let p): try c.encode(p)
            }
        }
    }
    public var id: String
    public var start: Double
    public var end: Double
    /// Magnification (1 = no zoom). Typical 1.5–2.5.
    public var scale: Double
    public var focus: Focus
    public var origin: Origin
    /// Why it exists (e.g. "3 clicks near Save button"). Helps humans review agent/auto output.
    public var reason: String?

    public init(id: String = IDs.make("z"), start: Double, end: Double, scale: Double = 2, focus: Focus = .followCursor, origin: Origin = .manual, reason: String? = nil) {
        self.id = id; self.start = start; self.end = end; self.scale = scale; self.focus = focus; self.origin = origin; self.reason = reason
    }
    public var range: TimeRange { TimeRange(start, end) }
}

/// A range of the recording removed from the output.
public struct Cut: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var start: Double
    public var end: Double
    public var origin: Origin
    public var reason: String?
    public init(id: String = IDs.make("c"), start: Double, end: Double, origin: Origin = .manual, reason: String? = nil) {
        self.id = id; self.start = start; self.end = end; self.origin = origin; self.reason = reason
    }
    public var range: TimeRange { TimeRange(start, end) }
}

/// A range of the recording played at a different rate.
public struct SpeedSegment: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var start: Double
    public var end: Double
    public var rate: Double
    public var origin: Origin
    public var reason: String?
    public init(id: String = IDs.make("s"), start: Double, end: Double, rate: Double, origin: Origin = .manual, reason: String? = nil) {
        self.id = id; self.start = start; self.end = end; self.rate = rate; self.origin = origin; self.reason = reason
    }
    public var range: TimeRange { TimeRange(start, end) }
}

public struct CaptionWord: Codable, Hashable, Sendable {
    public var text: String
    public var start: Double
    public var end: Double
    public init(text: String, start: Double, end: Double) { self.text = text; self.start = start; self.end = end }
}

public struct CaptionSegment: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var start: Double
    public var end: Double
    public var text: String
    public var words: [CaptionWord]
    public var hidden: Bool
    public init(id: String = IDs.make("cap"), start: Double, end: Double, text: String, words: [CaptionWord] = [], hidden: Bool = false) {
        self.id = id; self.start = start; self.end = end; self.text = text; self.words = words; self.hidden = hidden
    }
}

public struct Marker: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var time: Double
    public var note: String
    public var author: Author
    public init(id: String = IDs.make("m"), time: Double, note: String, author: Author) {
        self.id = id; self.time = time; self.note = note; self.author = author
    }
}

public struct Timeline: Codable, Hashable, Sendable {
    /// Kept part of the recording (source time). `nil` end = recording end.
    public var inPoint: Double = 0
    public var outPoint: Double?
    public var cuts: [Cut] = []
    public var speeds: [SpeedSegment] = []
    public var zooms: [ZoomSegment] = []
    public var captions: [CaptionSegment] = []
    public var markers: [Marker] = []
    /// Narration clips (generated voiceover), anchored to source instants.
    public var voiceover: [VoiceoverClip] = []
    public init() {}
}

// MARK: - Style

public struct BackgroundStyle: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable { case gradient, solid, image, none }
    public var kind: Kind = .gradient
    /// One of `BackgroundPresets.names` when kind == .gradient.
    public var preset: String = "dusk"
    public var colors: [RGBA] = []          // custom gradient stops / solid color
    public var angle: Double = 135          // gradient angle in degrees
    public var imagePath: String?           // absolute or project-relative
    public var blur: Double = 0             // background image blur radius (pt)
    public init() {}
}

public struct FrameStyle: Codable, Hashable, Sendable {
    /// Space around the screen, as a fraction of the canvas' shorter side.
    public var padding: Double = 0.075
    /// Corner radius as a fraction of the screen's shorter side.
    public var cornerRadius: Double = 0.018
    public var shadowOpacity: Double = 0.45
    public var shadowRadius: Double = 0.035   // fraction of canvas shorter side
    /// Thin inner border (macOS window look). 0 disables.
    public var borderWidth: Double = 0
    public init() {}
}

public struct CursorStyle: Codable, Hashable, Sendable {
    public enum Appearance: String, Codable, Sendable { case recorded, arrow }
    public var visible: Bool = true
    /// Size multiplier relative to the real cursor size.
    public var scale: Double = 1.6
    /// 0 = raw path, 1 = very smooth.
    public var smoothing: Double = 0.6
    public var appearance: Appearance = .recorded
    /// Fade the cursor out after this many seconds without movement (0 = never).
    public var hideAfterIdle: Double = 2.5
    public var clickEffect: Bool = true
    public var clickColor: RGBA = RGBA(1, 1, 1, 0.85)
    public init() {}
}

public struct ZoomStyle: Codable, Hashable, Sendable {
    /// Spring tuning of camera moves. Higher stiffness = snappier.
    /// Defaults ≈ critically damped (ζ≈1.0) with ω≈7.7 rad/s: a calm, unhurried camera that settles in ~0.65s.
    public var stiffness: Double = 180
    public var damping: Double = 48
    public var mass: Double = 3
    /// Fraction of the zoomed view around the center in which cursor moves don't pan the camera.
    public var followDeadZone: Double = 0.35
    /// Motion blur strength for fast camera moves (0 disables).
    public var motionBlur: Double = 0.3
    public init() {}
}

public struct CaptionStyle: Codable, Hashable, Sendable {
    public enum Look: String, Codable, Sendable { case pill, highlight, plain }
    public var enabled: Bool = true
    public var look: Look = .highlight
    /// Font size as a fraction of canvas height.
    public var size: Double = 0.042
    public var textColor: RGBA = .white
    public var highlightColor: RGBA = RGBA(1.0, 0.82, 0.26)
    public var backgroundColor: RGBA = RGBA(0.06, 0.06, 0.09, 0.78)
    public var position: String = "bottom"   // bottom | top
    public var maxCharsPerLine: Int = 42
    public init() {}
}

public struct AudioStyle: Codable, Hashable, Sendable {
    /// On export, bring the voice (or system audio when there's no mic) to `targetLUFS` integrated loudness.
    public var normalizeLoudness: Bool = true
    public var targetLUFS: Double = -16
    public var microphoneGain: Double = 1
    public var systemGain: Double = 0.8
    public var muteMicrophone: Bool = false
    public var muteSystem: Bool = false
    public var voiceoverGain: Double = 1
    public var muteVoiceover: Bool = false
    /// Lower the microphone/system tracks while a voiceover clip plays.
    public var duckUnderVoiceover: Bool = true
    /// Level the other tracks are ducked to (0…1).
    public var duckLevel: Double = 0.22
    public init() {}
}

public enum Aspect: String, Codable, Sendable, CaseIterable {
    case auto, landscape = "16:9", square = "1:1", portrait = "9:16", classic = "4:3", vertical45 = "4:5"
    public func ratio(sourceWidth: Int, sourceHeight: Int) -> Double {
        switch self {
        case .auto: return Double(sourceWidth) / Double(max(1, sourceHeight))
        case .landscape: return 16.0 / 9
        case .square: return 1
        case .portrait: return 9.0 / 16
        case .classic: return 4.0 / 3
        case .vertical45: return 4.0 / 5
        }
    }
}

public struct CanvasStyle: Codable, Hashable, Sendable {
    public var aspect: Aspect = .landscape
    /// Resting magnification. >1 reframes (e.g. vertical/square variants) and the camera follows the cursor.
    public var baseScale: Double = 1
    public init() {}
}

public struct Style: Codable, Hashable, Sendable {
    public var background = BackgroundStyle()
    public var frame = FrameStyle()
    public var cursor = CursorStyle()
    public var zoom = ZoomStyle()
    public var captions = CaptionStyle()
    public var audio = AudioStyle()
    public var canvas = CanvasStyle()
    public var voice = VoiceStyle()
    /// Style fields that may be nil (and so absent from the encoded style) but are still valid `set_style` paths.
    public static let optionalPaths: Set<String> = ["voice.voiceID", "voice.voiceName"]
    public init() {}
}

// MARK: - Document

public struct ProjectDocument: Codable, Hashable, Sendable {
    public static let formatVersion = 1
    public var formatVersion: Int = ProjectDocument.formatVersion
    public var id: String
    public var name: String
    public var createdAt: Date
    /// Incremented by every applied transaction. Agents pass it back as `expected_revision` to avoid clobbering.
    public var revision: Int = 0
    public var media: MediaInfo
    public var recording: RecordingInfo?
    public var timeline = Timeline()
    public var style = Style()

    public init(id: String = IDs.make("p"), name: String, createdAt: Date = Date(), media: MediaInfo, recording: RecordingInfo? = nil) {
        self.id = id; self.name = name; self.createdAt = createdAt; self.media = media; self.recording = recording
    }

    /// Kept source range after in/out points.
    public var keptRange: TimeRange {
        TimeRange(max(0, timeline.inPoint), min(media.duration, timeline.outPoint ?? media.duration))
    }
}

public enum IDs {
    private static let alphabet = Array("abcdefghjkmnpqrstuvwxyz23456789")
    public static func make(_ prefix: String) -> String {
        var g = SystemRandomNumberGenerator()
        return prefix + "_" + String((0..<6).map { _ in alphabet[Int(g.next() % UInt64(alphabet.count))] })
    }
}
