import Foundation

/// Motion paths are sampled in memory at 120 Hz. Bound both source and edited duration before allocating
/// them; a slow-motion edit must obey the same limit as its source. Six hours permits long recordings
/// while keeping a single camera path below 83 MB.
public enum TimelineLimits {
    public static let maximumDuration: Double = 6 * 60 * 60

    public static func contains(_ duration: Double) -> Bool {
        duration.isFinite && duration >= 0 && duration <= maximumDuration
    }
}
