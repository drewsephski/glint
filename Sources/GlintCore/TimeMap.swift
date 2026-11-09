import Foundation

/// Maps between recording (source) time and output time, given in/out points, cuts and speed segments.
/// The same map drives the AVFoundation composition, the renderer and every planner, so they always agree.
public struct TimeMap: Hashable, Sendable {
    /// A contiguous kept source range played at a constant rate.
    public struct Piece: Hashable, Sendable, Codable {
        public var source: TimeRange
        public var rate: Double
        public var outputStart: Double
        public var outputDuration: Double { source.duration / rate }
        public var outputEnd: Double { outputStart + outputDuration }
    }

    public let pieces: [Piece]
    public var outputDuration: Double { pieces.last?.outputEnd ?? 0 }

    public init(document: ProjectDocument) {
        self.init(kept: document.keptRange, cuts: document.timeline.cuts.map(\.range), speeds: document.timeline.speeds)
    }

    public init(kept: TimeRange, cuts: [TimeRange], speeds: [SpeedSegment]) {
        // 1. Kept ranges = kept minus union(cuts).
        var kepts: [TimeRange] = [kept]
        for cut in cuts.sorted(by: { $0.start < $1.start }) {
            kepts = kepts.flatMap { r -> [TimeRange] in
                guard r.overlaps(cut) else { return [r] }
                var out: [TimeRange] = []
                if cut.start > r.start { out.append(TimeRange(r.start, cut.start)) }
                if cut.end < r.end { out.append(TimeRange(cut.end, r.end)) }
                return out
            }
        }
        // 2. Split kept ranges at speed boundaries; later segments win on overlap.
        var bounds = Set<Double>()
        for s in speeds where s.rate > 0 { bounds.insert(s.start); bounds.insert(s.end) }
        let sortedBounds = bounds.sorted()
        var pieces: [Piece] = []
        var out = 0.0
        for r in kepts where r.duration > 1e-6 {
            var edges = [r.start] + sortedBounds.filter { $0 > r.start && $0 < r.end } + [r.end]
            edges = Array(edges)
            for (a, b) in zip(edges, edges.dropFirst()) where b - a > 1e-6 {
                let mid = (a + b) / 2
                let rate = speeds.last(where: { $0.rate > 0 && $0.range.contains(mid) })?.rate ?? 1
                let p = Piece(source: TimeRange(a, b), rate: rate, outputStart: out)
                out = p.outputEnd
                // Merge with previous piece when contiguous at the same rate.
                if let last = pieces.last, abs(last.source.end - a) < 1e-9, last.rate == rate {
                    pieces[pieces.count - 1] = Piece(source: TimeRange(last.source.start, b), rate: rate, outputStart: last.outputStart)
                } else {
                    pieces.append(p)
                }
            }
        }
        self.pieces = pieces
    }

    /// Output time of a source instant, or nil if that instant is cut.
    public func output(forSource t: Double) -> Double? {
        for p in pieces where t >= p.source.start - 1e-9 && t <= p.source.end + 1e-9 {
            return p.outputStart + (min(max(t, p.source.start), p.source.end) - p.source.start) / p.rate
        }
        return nil
    }

    /// Output time of a source instant; cut instants snap to the next kept instant.
    public func outputClamped(forSource t: Double) -> Double {
        if let o = output(forSource: t) { return o }
        if let next = pieces.first(where: { $0.source.start >= t }) { return next.outputStart }
        return outputDuration
    }

    public func source(forOutput t: Double) -> Double {
        guard let first = pieces.first else { return 0 }
        if t <= 0 { return first.source.start }
        for p in pieces where t < p.outputEnd {
            return p.source.start + (t - p.outputStart) * p.rate
        }
        return pieces.last!.source.end
    }

    public func rate(atOutput t: Double) -> Double {
        pieces.first(where: { t < $0.outputEnd })?.rate ?? 1
    }

    /// Map a source range to output ranges (one per piece it touches).
    public func outputRanges(forSource r: TimeRange) -> [TimeRange] {
        pieces.compactMap { p in
            guard let c = r.clamped(to: p.source) else { return nil }
            return TimeRange(p.outputStart + (c.start - p.source.start) / p.rate, p.outputStart + (c.end - p.source.start) / p.rate)
        }
    }

    /// Single output span covering a source range (first to last kept instant), or nil if fully cut.
    public func outputSpan(forSource r: TimeRange) -> TimeRange? {
        let rs = outputRanges(forSource: r)
        guard let f = rs.first, let l = rs.last else { return nil }
        return TimeRange(f.start, l.end)
    }
}
