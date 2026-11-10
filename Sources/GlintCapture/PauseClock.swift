import Foundation
import CoreMedia
import GlintCore

/// The one pause/resume state a take's screen, audio, camera and input tracks all consult, so a pause cuts every
/// track at the same host instant.
///
/// Each track asks `shift(for:)` with its sample's host timestamp: nil means the sample was taken while paused and is
/// dropped; otherwise the sample is restamped earlier by the time spent paused before it (`retimed(_:by:)`), so the
/// files come out gapless and in sync.
public final class PauseClock: @unchecked Sendable {
    private let lock = NSLock()
    private var timeline = PauseTimeline()
    private var changed: [(Bool) -> Void] = []

    public init() {}

    public var isPaused: Bool { lock.withLock { timeline.isPaused } }
    public var snapshot: PauseTimeline { lock.withLock { timeline } }

    /// Pause at `host` (default now). False if already paused.
    @discardableResult
    public func pause(at host: Double = hostSeconds()) -> Bool {
        let ok = lock.withLock { timeline.pause(at: host) }
        if ok { notify(true) }
        return ok
    }

    /// Resume at `host` (default now). False if not paused.
    @discardableResult
    public func resume(at host: Double = hostSeconds()) -> Bool {
        let ok = lock.withLock { timeline.resume(at: host) }
        if ok { notify(false) }
        return ok
    }

    /// Called (on the pausing thread) with the new paused state.
    public func observe(_ f: @escaping (Bool) -> Void) { lock.withLock { changed.append(f) } }

    private func notify(_ paused: Bool) {
        for f in lock.withLock({ changed }) { f(paused) }
    }

    /// For a sample stamped `pts` on the host clock: nil to drop it (taken while paused), else how much earlier it
    /// moves in the file.
    public func shift(for pts: CMTime) -> CMTime? {
        let t = pts.seconds
        return lock.withLock { () -> CMTime? in
            if timeline.contains(t) { return nil }
            let o = timeline.offset(at: t)
            return o > 0 ? CMTime(seconds: o, preferredTimescale: 1_000_000_000) : .zero
        }
    }

    /// Gapless host time for an instant (inside a pause: the cut).
    public func collapse(_ host: Double) -> Double { lock.withLock { timeline.collapse(host) } }
    public func collapse(_ host: CMTime) -> CMTime { CMTime(seconds: collapse(host.seconds), preferredTimescale: 1_000_000_000) }

    /// Seconds spent paused up to now.
    public var totalPaused: Double { lock.withLock { timeline.totalPaused(now: hostSeconds()) } }
}

/// A copy of `sb` with every timestamp moved earlier by `shift` (nil if CoreMedia refuses the copy).
func retimed(_ sb: CMSampleBuffer, by shift: CMTime) -> CMSampleBuffer? {
    guard CMTimeCompare(shift, .zero) != 0 else { return sb }
    var count: CMItemCount = 0
    guard CMSampleBufferGetSampleTimingInfoArray(sb, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count) == noErr, count > 0 else {
        return retimed(sb, to: CMTimeSubtract(sb.presentationTimeStamp, shift))
    }
    var timing = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: count)
    guard CMSampleBufferGetSampleTimingInfoArray(sb, entryCount: count, arrayToFill: &timing, entriesNeededOut: &count) == noErr else { return nil }
    for i in timing.indices {
        if timing[i].presentationTimeStamp.isValid { timing[i].presentationTimeStamp = CMTimeSubtract(timing[i].presentationTimeStamp, shift) }
        if timing[i].decodeTimeStamp.isValid { timing[i].decodeTimeStamp = CMTimeSubtract(timing[i].decodeTimeStamp, shift) }
    }
    var out: CMSampleBuffer?
    guard CMSampleBufferCreateCopyWithNewTiming(allocator: nil, sampleBuffer: sb, sampleTimingEntryCount: count, sampleTimingArray: &timing, sampleBufferOut: &out) == noErr else { return nil }
    return out
}

/// A copy of a single-frame `sb` presented at `t`.
func retimed(_ sb: CMSampleBuffer, to t: CMTime) -> CMSampleBuffer? {
    if CMTimeCompare(sb.presentationTimeStamp, t) == 0 { return sb }
    var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: t, decodeTimeStamp: .invalid)
    var out: CMSampleBuffer?
    guard CMSampleBufferCreateCopyWithNewTiming(allocator: nil, sampleBuffer: sb, sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleBufferOut: &out) == noErr else { return nil }
    return out
}
