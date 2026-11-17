import Foundation
import Combine
import AppKit

/// `tell application "Music"` starts the app when it is not running. Every
/// query is guarded by the process list, so quitting Music never makes Pear
/// bring it back.
private enum MusicAppProcess {
    static var isRunning: Bool {
        NSRunningApplication
            .runningApplications(withBundleIdentifier: "com.apple.Music")
            .contains { !$0.isTerminated }
    }
}

/// The currently playing track, as reported by the Music app.
public struct CurrentTrack: Sendable, Equatable {
    public let title: String
    public let artist: String
    public let album: String
    public let duration: TimeInterval
    /// Music app persistent ID (library scoped). Used for change detection.
    public let persistentID: String

    public init(title: String, artist: String, album: String, duration: TimeInterval, persistentID: String) {
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration
        self.persistentID = persistentID
    }
}

/// One event-driven read of state + position + track metadata.
public struct MusicSnapshot: Sendable {
    public let state: String
    public let position: TimeInterval
    public let title: String
    public let artist: String
    public let album: String
    public let duration: TimeInterval
    public let persistentID: String
    /// When `position` was actually sampled inside Music. It must travel with
    /// the snapshot: by the time it reaches the main actor the position is
    /// already stale, and anchoring to `Date()` there makes every lyric line
    /// lag by the AppleEvent round-trip.
    public let capturedAt: Date
}

/// Lightweight calibration sample: state, position and the track identity
/// only. Metadata is never refreshed by a calibration, but the ID lets the
/// event source notice a song change whose notification was missed.
public struct MusicPlaybackSample: Sendable {
    public let state: String
    public let position: TimeInterval
    public let persistentID: String
    public let capturedAt: Date
}

/// Talks to the Music app through in-process, precompiled AppleScript.
///
/// No command-line interpreter is launched and no child process is created.
/// `read()` is only called when something actually happened (a distributed
/// notification, a workspace event or a user action); periodic calibration
/// uses the much smaller `readPlayback()` and stops entirely when paused.
public enum MusicScript {

    /// Script failures show up in the log file instead of silently returning
    /// nil, which used to look like "no permission".
    public nonisolated(unsafe) static var diagnosticHandler: ((String) -> Void)?
    /// Low-frequency operational log lines from the event source.
    public nonisolated(unsafe) static var infoHandler: (@Sendable (String) -> Void)?

    private static let engine = MusicScriptEngine()

    /// True when the Music app is already running.
    public static func appIsRunning() -> Bool { MusicAppProcess.isRunning }

    /// A snapshot meaning "Music is not running".
    ///
    /// Returning this instead of `nil` matters: a nil is treated as a failed
    /// read and the monitor keeps its previous track, which would leave the
    /// last song's lyrics frozen on screen after Music quits.
    private static var stoppedSnapshot: MusicSnapshot {
        MusicSnapshot(state: "stopped", position: 0,
                      title: "", artist: "", album: "",
                      duration: 0, persistentID: "",
                      capturedAt: Date())
    }

    /// One round-trip for state + position + track metadata.
    ///
    /// Variable names matter: `st` collides with a term in the Music app's
    /// AppleScript dictionary and makes the entire script fail to compile
    /// (error -2741). Every name below has been checked against it.
    static let combined = """
    tell application "Music"
        set pstate to (player state as text)
        set pp to "0"
        try
            set pp to (player position as text)
        end try
        set nm to ""
        set ar to ""
        set al to ""
        set du to "0"
        set pid to ""
        try
            set t to current track
            set nm to (name of t)
            set ar to (artist of t)
            set al to (album of t)
            set du to (duration of t as text)
            set pid to (persistent ID of t)
        end try
        return pstate & "||" & pp & "||" & nm & "||" & ar & "||" & al & "||" & du & "||" & pid
    end tell
    """

    /// Calibration-only round-trip: no track metadata, no artwork, no library
    /// lookups. The persistent ID is a cheap guard against a missed song
    /// change notification.
    static let playback = """
    tell application "Music"
        set pstate to (player state as text)
        set pp to "0"
        try
            set pp to (player position as text)
        end try
        set pid to ""
        try
            set pid to (persistent ID of current track)
        end try
        return pstate & "||" & pp & "||" & pid
    end tell
    """

    static let playPause = "tell application \"Music\" to playpause"
    static let nextTrack = "tell application \"Music\" to next track"
    static let previousTrack = "tell application \"Music\" to previous track"

    /// Full read, used on real events only.
    static func read() -> MusicSnapshot? {
        guard MusicAppProcess.isRunning else { return stoppedSnapshot }
        let started = Date()
        guard let raw = engine.execute(combined), !raw.isEmpty else { return nil }
        // `player position` is sampled somewhere inside the AppleEvent call.
        // Approximate that instant with the mid-point of the round trip.
        let elapsed = Date().timeIntervalSince(started)
        let capturedAt = started.addingTimeInterval(elapsed / 2)
        let parts = raw.components(separatedBy: "||")
        guard parts.count >= 7 else { return nil }
        return MusicSnapshot(state: parts[0],
                             position: Double(parts[1]) ?? 0,
                             title: parts[2],
                             artist: parts[3],
                             album: parts[4],
                             duration: Double(parts[5]) ?? 0,
                             persistentID: parts[6],
                             capturedAt: capturedAt)
    }

    /// Position-only calibration sample.
    static func readPlayback() -> MusicPlaybackSample? {
        guard MusicAppProcess.isRunning else {
            return MusicPlaybackSample(state: "stopped", position: 0,
                                       persistentID: "", capturedAt: Date())
        }
        let started = Date()
        guard let raw = engine.execute(playback), !raw.isEmpty else { return nil }
        let elapsed = Date().timeIntervalSince(started)
        let capturedAt = started.addingTimeInterval(elapsed / 2)
        let parts = raw.components(separatedBy: "||")
        guard parts.count >= 2 else { return nil }
        return MusicPlaybackSample(state: parts[0],
                                   position: Double(parts[1]) ?? 0,
                                   persistentID: parts.count >= 3 ? parts[2] : "",
                                   capturedAt: capturedAt)
    }

    /// The one and only full snapshot source.
    static func mergedSnapshot() -> MusicSnapshot? { read() }

    @discardableResult
    static func run(_ source: String) -> String? { engine.execute(source) }

    /// Seeking passes its value as an AppleEvent argument to a precompiled
    /// handler; no script text is rebuilt.
    static func seek(to seconds: TimeInterval) { engine.seek(to: seconds) }

    static func report(_ message: String) { engine.report(message) }
    static func info(_ message: String) { infoHandler?(message) }
}

/// Watches the macOS Music app for the currently playing track and keeps a
/// locally interpolated playback position.
///
/// State changes arrive from `MusicEventSource`: distributed notifications
/// for song changes / play / pause / seek, workspace events for launch and
/// quit, plus a low-frequency calibration while playing. Between those the
/// position is computed in memory from the last anchor, at the UI's own
/// redraw rate. No polling loop and no child process.
@MainActor
public final class AppleMusicMonitor: ObservableObject {
    @Published public private(set) var track: CurrentTrack?
    @Published public private(set) var isPlaying = false
    /// Raw `player state` text. Unlike `isPlaying` (true only for "playing"),
    /// this lets the app tell an explicit pause from a network stall.
    @Published public private(set) var playerState = ""

    /// Identity key that changes whenever a *different* song starts.
    public var trackIdentity: String? {
        track.map { "\($0.persistentID)|\($0.title)|\($0.artist)" }
    }

    // Local interpolation anchors.
    private var anchorPosition: TimeInterval = 0
    private var anchorDate: Date = .distantPast

    private var events: MusicEventSource?

    public init() {}

    public func start() {
        // Typed @Sendable so these closures do not inherit main-actor
        // isolation; the hop back is explicit.
        events = MusicEventSource(
            onSnapshot: { [weak self] snapshot in
                Task { @MainActor in self?.apply(snapshot) }
            },
            onCalibration: { [weak self] sample in
                Task { @MainActor in self?.applyCalibration(sample) }
            })
        events?.start()
    }

    public func stop() {
        events?.stop()
        events = nil
    }

    // MARK: - Public position access

    /// Smoothly interpolated playback position in seconds. Pure computation:
    /// no Music query and no process creation on the UI's redraw path.
    public var smoothPosition: TimeInterval {
        PlaybackClock.position(anchor: anchorPosition,
                               anchorDate: anchorDate,
                               now: Date(),
                               playing: isPlaying)
    }

    // MARK: - State application

    private func apply(_ s: MusicSnapshot) {
        if s.persistentID.isEmpty || s.title.isEmpty {
            setTrack(nil)
        } else {
            setTrack(CurrentTrack(title: s.title,
                                  artist: s.artist,
                                  album: s.album,
                                  duration: s.duration,
                                  persistentID: s.persistentID))
        }
        setPlaying(s.state == "playing")
        setPlayerState(s.state)

        // Anchors are plain state (not @Published): updating them must not
        // trigger a redraw. Anchor to when the position was *sampled*, not
        // when this main-actor hop happened.
        anchorPosition = s.position
        anchorDate = s.capturedAt
    }

    /// Calibration deliberately leaves metadata alone: only play state and
    /// the position anchor are refreshed.
    private func applyCalibration(_ s: MusicPlaybackSample) {
        setPlaying(s.state == "playing")
        setPlayerState(s.state)
        anchorPosition = s.position
        anchorDate = s.capturedAt
    }

    private func setPlayerState(_ newValue: String) {
        guard playerState != newValue else { return }
        playerState = newValue
    }

    /// `@Published` fires on *every* assignment, even when unchanged.
    private func setPlaying(_ newValue: Bool) {
        guard isPlaying != newValue else { return }
        isPlaying = newValue
    }

    private func setTrack(_ newValue: CurrentTrack?) {
        guard track != newValue else { return }
        track = newValue
    }

    // MARK: - Playback control

    public func togglePlayPause() { events?.run(MusicScript.playPause) }
    public func nextTrack() { events?.run(MusicScript.nextTrack) }
    public func previousTrack() { events?.run(MusicScript.previousTrack) }

    public func seek(to seconds: TimeInterval) {
        let clamped = max(0, seconds)
        events?.seek(to: clamped)
        anchorPosition = clamped
        anchorDate = Date()
    }

    /// Manual refresh from the menu bar / status page.
    public func refreshNowPlaying() { events?.refresh() }
}
