import Foundation

/// Decides when a pause should hide the floating lyrics.
///
/// Only an **explicit** pause reported by the Music app counts. A network
/// stall while streaming does not: Music keeps `player state` at `playing`
/// and the playback position simply stops advancing, so treating "position
/// is not moving" as a pause would hide the pill every time a song buffers.
/// Fast-forward, rewind and any unrecognised state also keep the pill up.
///
/// The short grace window absorbs the state flicker around a play/pause
/// toggle and around track changes, so the pill does not blink off and back
/// on. Recovery is immediate: it is never delayed by the grace period.
enum PauseVisibility {
    /// Seconds an explicit pause must persist before the pill is hidden.
    static let grace: TimeInterval = 1.2

    /// AppleScript returns the English enum term on this macOS build, but
    /// accept a localised "已暂停" / "已停止" too rather than silently never
    /// hiding the pill if that ever changes.
    static func isExplicitPause(_ rawState: String) -> Bool {
        let s = rawState.lowercased()
        return s.contains("paused") || s.contains("stopped")
            || s.contains("暂停") || s.contains("停止")
    }

    static func hides(pausedSince: Date?, now: Date = Date()) -> Bool {
        guard let pausedSince else { return false }
        return now.timeIntervalSince(pausedSince) >= grace
    }
}
