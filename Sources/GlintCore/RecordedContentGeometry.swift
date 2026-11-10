import Foundation

public struct CaptureContentSample: Codable, Hashable, Sendable {
    public var t: Double
    public var rect: NormRect

    public init(t: Double, rect: NormRect) {
        self.t = t
        self.rect = rect
    }
}

/// Capture padding is not part of the shot. Look up geometry in FILE time so trimmed, reordered and repeated
/// takes keep their own bounds, independent of cuts and speed changes on the program timeline.
public struct RecordedContentGeometry: Sendable {
    private let clips: ClipLayout
    private let logs: [String: EventLog]
    private let mediaWidth: Int
    private let mediaHeight: Int

    public init(document: ProjectDocument, logs: [String: EventLog]) {
        clips = ClipLayout(document: document)
        self.logs = logs
        mediaWidth = document.media.width
        mediaHeight = document.media.height
    }

    public func crop(at sourceTime: Double) -> NormRect? {
        guard let segment = clips.segment(at: sourceTime), let path = segment.clip.events,
            let log = logs[path]
        else { return nil }
        let time = segment.fileTime(sourceTime)
        if let sample = log.captureContent?.last(where: { $0.t <= time }) {
            let r = sample.rect
            guard [r.x, r.y, r.width, r.height].allSatisfy(\.isFinite),
                r.x >= 0, r.y >= 0, r.width > 0, r.height > 0,
                r.x + r.width <= 1.000001, r.y + r.height <= 1.000001
            else { return nil }
            return r
        }
        // Older ScreenCaptureKit recordings used scalesToFit=false: content was downscaled if necessary,
        // then placed at the top left of a fixed-size surface. Never infer padding by looking for black pixels.
        guard let first = log.windowFrames?.first,
            let frame = log.windowFrames?.last(where: { $0.t <= time }),
            [first.width, first.height, frame.width, frame.height].allSatisfy({ $0.isFinite && $0 > 0 }),
            segment.clip.width > 0, segment.clip.height > 0
        else { return nil }
        let width = Double(segment.clip.width)
        let height = Double(segment.clip.height)
        let scale = max(width / first.width, height / first.height)
        let fit = min(1, min(width / (frame.width * scale), height / (frame.height * scale)))
        let w = min(width, frame.width * scale * fit)
        let h = min(height, frame.height * scale * fit)
        // Ignore the encoder's even-pixel rounding, but remove genuine padding after a resize.
        return NormRect(x: 0, y: 0, width: width - w < 2 ? 1 : w / width, height: height - h < 2 ? 1 : h / height)
    }

    public func contentRect(at sourceTime: Double, layout: CanvasLayout) -> NormRect {
        guard let clip = clips.segment(at: sourceTime)?.clip else { return layout.screenRect }
        let crop = crop(at: sourceTime)
        let w = Double(clip.width > 0 ? clip.width : mediaWidth) * (crop?.width ?? 1)
        let h = Double(clip.height > 0 ? clip.height : mediaHeight) * (crop?.height ?? 1)
        return layout.fitted(pixelWidth: max(1, Int(w.rounded())), pixelHeight: max(1, Int(h.rounded())))
    }
}
