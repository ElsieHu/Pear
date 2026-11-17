import Foundation

/// Pure, in-memory playback clock and sampling policy.
///
/// Nothing in this type talks to Music. The position is derived from the last
/// sampled anchor plus elapsed wall time, and the rules below decide when a
/// fresh sample is allowed at all. Keeping the policy pure makes the
/// "never sample while paused or while Music is closed" guarantee testable
/// on every build.
public enum PlaybackClock {

    /// Calibration cadence while Music is actively playing. The low end of
    /// the 10-30 s window: a stalled or buffered song can otherwise let the
    /// locally interpolated position drift away from the real one.
    public static let calibrationInterval: TimeInterval = 10.0

    /// A track change often delivers several distributed notifications in a
    /// row. Collapse the burst into one sample this long after the last one.
    public static let eventDebounce: TimeInterval = 0.10

    /// Locally interpolated player position, in seconds.
    ///
    /// While playing, wall time advances at the same rate as Music's own
    /// clock. When paused or stopped the anchor is frozen; keeping the
    /// displayed position still needs no cross-process work at all.
    public static func position(anchor: TimeInterval,
                                anchorDate: Date,
                                now: Date,
                                playing: Bool) -> TimeInterval {
        guard playing else { return anchor }
        return anchor + max(0, now.timeIntervalSince(anchorDate))
    }

    /// Whether a calibration timer may exist. Paused, stopped, fast-forward,
    /// rewind and "Music is closed" all cancel it entirely.
    public static func keepsCalibrating(state: String, appRunning: Bool) -> Bool {
        appRunning && state == "playing"
    }

    /// Whether a calibration sample is due right now.
    public static func calibrationDue(state: String,
                                      appRunning: Bool,
                                      now: Date,
                                      lastCalibration: Date,
                                      interval: TimeInterval = calibrationInterval) -> Bool {
        guard keepsCalibrating(state: state, appRunning: appRunning) else { return false }
        return now.timeIntervalSince(lastCalibration) >= interval
    }

    /// Calibration carries the track's persistent ID but no metadata. A
    /// changed ID means a song change notification was missed, which is the
    /// only case where calibration may escalate to a full metadata read.
    public static func trackChanged(lastID: String, currentID: String) -> Bool {
        !currentID.isEmpty && currentID != lastID
    }
}
