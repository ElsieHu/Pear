import Foundation
import Combine
import AppKit

/// AppleScript's `tell application "Music"` **launches** the app when it is
/// not running. Pear polls once a second in both playing and paused states
/// (a pause now hides the pill, so it must be noticed promptly), so quitting
/// Music while Pear is open made the next tick relaunch
/// it — the app appeared impossible to quit. Check the process list before
/// sending any script; only a running Music app may be queried.
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

/// One poll's worth of state read out of the Music app.
public struct MusicSnapshot: Sendable {
    public let state: String
    public let position: TimeInterval
    public let title: String
    public let artist: String
    public let album: String
    public let duration: TimeInterval
    public let persistentID: String
    /// When `position` was actually sampled inside the Music app. Must travel
    /// with the snapshot: by the time it reaches the main actor the position
    /// is already stale, and anchoring to `Date()` there makes every lyric
    /// line lag by the AppleScript round-trip (a constant few-second offset).
    public let capturedAt: Date
}

/// Talks to the Music app. Deliberately **not** an actor and **not**
/// @MainActor: it owns blocking `osascript` invocations and is meant to be
/// driven from a background queue.
///
/// (An earlier version called these as `@MainActor` methods; Swift 6's
/// isolation check then trapped with EXC_BREAKPOINT as soon as the timer
/// fired off the main thread.)
public enum MusicScript {

    /// Set by the app so script failures show up in the log file instead of
    /// silently returning nil (which used to look like "no permission").
    /// Polling runs once a second, so identical messages are collapsed —
    /// otherwise a single persistent failure floods the log.
    public nonisolated(unsafe) static var diagnosticHandler: ((String) -> Void)?
    nonisolated(unsafe) private static var lastDiagnostic = ""

    /// True when the Music app is already running. Exposed so the UI can
    /// distinguish "not playing" from "permission denied" without guessing.
    public static func appIsRunning() -> Bool { MusicAppProcess.isRunning }

    /// A snapshot meaning "Music is not running".
    ///
    /// Returning this instead of `nil` matters: a nil is treated as a failed
    /// poll and the monitor keeps its previous track, which would leave the
    /// last song's lyrics frozen on screen after Music quits. An empty but
    /// successful snapshot flows through `apply()` and clears them.
    private static var stoppedSnapshot: MusicSnapshot {
        MusicSnapshot(state: "stopped", position: 0,
                      title: "", artist: "", album: "",
                      duration: 0, persistentID: "",
                      capturedAt: Date())
    }

    /// One round-trip for state + position + track metadata.
    ///
    /// Variable names matter: `st` collides with a term in the Music app's
    /// AppleScript dictionary and makes the *entire* script fail to compile
    /// (error -2741, "预期是表达式，却找到 st"). Compile failure means
    /// `osascript` exits non-zero, we return nil, and the app looks exactly
    /// like it has no Automation permission even after the user grants it.
    /// Every name below has been checked against the dictionary.
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

    static func read() -> MusicSnapshot? {
        // Never send a `tell application "Music"` while the app is closed:
        // AppleEvent delivery would start it again. Playback-control scripts
        // still go through `run()` directly — those are explicit user actions
        // for which launching Music is the expected result.
        guard MusicAppProcess.isRunning else { return stoppedSnapshot }

        let started = Date()
        guard let raw = run(combined), !raw.isEmpty else { return nil }
        // `player position` is read somewhere *inside* that osascript call.
        // Approximate the sampling instant with the mid-point of the round
        // trip — anchoring to the end would still leave the lyrics behind by
        // the whole call duration.
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

    /// The one and only snapshot source.
    ///
    /// This used to merge AppleScript with the private MediaRemote framework,
    /// on the theory that MediaRemote needs no permission and could cover for
    /// a missing Automation grant. Two measurements killed that:
    /// - On current macOS `MRMediaRemoteGetNowPlayingInfo` returns nil even
    ///   while music is playing, so it contributed nothing.
    /// - Calling it once per second made macOS pop “Pear.app 想
    ///   访问 Apple Music…你的媒体资料库” over and over (that prompt is
    ///   MediaRemote's, not Apple Events').
    /// So: AppleScript only.
    static func mergedSnapshot() -> MusicSnapshot? { read() }

    @discardableResult
    static func run(_ source: String) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", source]
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        do {
            try proc.run()
        } catch {
            report("osascript 启动失败: \(error.localizedDescription)")
            return nil
        }
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()

        guard proc.terminationStatus == 0 else {
            let msg = String(data: errData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "(无 stderr)"
            report("osascript 退出 \(proc.terminationStatus): \(msg)")
            return nil
        }
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Collapse repeated identical diagnostics into a single log line.
    private static func report(_ message: String) {
        guard message != lastDiagnostic else { return }
        lastDiagnostic = message
        diagnosticHandler?(message)
    }
}

/// Watches the macOS Music app for the currently playing track and keeps a
/// smoothly interpolated playback position.
///
/// Design notes (this file was rewritten after two real bugs)
/// ----------------------------------------------------------
/// 1. An earlier version asked the Music app twice (`player state`,
///    `player position`) every 0.25 s, each time spawning a synchronous
///    `osascript` — 8 process launches per second, all blocking the main
///    thread. It starved the main actor badly enough that the lyrics-fetch
///    loop never got scheduled: every new song needed a manual refresh.
/// 2. Moving that work onto a queue exposed a Swift 6 isolation trap
///    (EXC_BREAKPOINT via `_swift_task_checkIsolatedSwift`), because the
///    script helpers were still @MainActor methods. All scripting now lives
///    in `MusicScript`, which carries no isolation at all.
///
/// So: one combined AppleScript per poll at ~1 Hz, on a dedicated serial
/// queue, and only *changed* values are published.
@MainActor
public final class AppleMusicMonitor: ObservableObject {
    @Published public private(set) var track: CurrentTrack?
    @Published public private(set) var isPlaying = false
    /// Raw `player state` text from AppleScript. Unlike `isPlaying` (which is
    /// true only for the literal "playing"), this lets the app distinguish an
    /// explicit pause from a fast-forward, a rewind or a network stall.
    @Published public private(set) var playerState = ""

    /// Identity key that changes whenever a *different* song starts.
    public var trackIdentity: String? {
        track.map { "\($0.persistentID)|\($0.title)|\($0.artist)" }
    }

    // Local interpolation anchors.
    private var anchorPosition: TimeInterval = 0
    private var anchorDate: Date = .distantPast

    /// Non-isolated poller: owns the queue + timer, never touches the actor.
    private var poller: MusicPoller?
    private var pollInterval: TimeInterval = 1.0

    public init() {}

    public func start() {
        // Typed @Sendable at the parameter, so this closure does *not*
        // inherit main-actor isolation; the hop back is explicit.
        poller = MusicPoller { [weak self] snapshot in
            Task { @MainActor in self?.apply(snapshot) }
        }

        let center = DistributedNotificationCenter.default()
        center.addObserver(self,
                           selector: #selector(playerInfoChanged(_:)),
                           name: Notification.Name("com.apple.Music.playerInfo"),
                           object: nil)
        center.addObserver(self,
                           selector: #selector(playerInfoChanged(_:)),
                           name: Notification.Name("com.apple.iTunes.playerInfo"),
                           object: nil)

        poller?.setInterval(pollInterval)
        poller?.start()
        poller?.pollOnce()
    }

    public func stop() {
        poller?.stop()
        poller = nil
        DistributedNotificationCenter.default().removeObserver(self)
    }

    // MARK: - Public position access

    /// Smoothly interpolated playback position in seconds.
    public var smoothPosition: TimeInterval {
        if isPlaying {
            return anchorPosition + Date().timeIntervalSince(anchorDate)
        }
        return anchorPosition
    }

    // MARK: - Polling

    private func apply(_ s: MusicSnapshot) {
        let playing = (s.state == "playing")

        if s.persistentID.isEmpty || s.title.isEmpty {
            setTrack(nil)
        } else {
            setTrack(CurrentTrack(title: s.title,
                                  artist: s.artist,
                                  album: s.album,
                                  duration: s.duration,
                                  persistentID: s.persistentID))
        }
        setPlaying(playing)
        setPlayerState(s.state)

        // Anchors are plain state (not @Published): updating them must not
        // trigger a redraw, otherwise every observing view re-renders 1×/s.
        // Anchor to when the position was *sampled*, not when this main-actor
        // hop happened — otherwise the whole lyric timeline runs late by the
        // osascript round-trip plus the hop.
        anchorPosition = s.position
        anchorDate = s.capturedAt

        // Pause now hides the pill and resume brings it back, so both states
        // need the same 1 Hz cadence. The old 3 s paused interval could add
        // three seconds before a pause was even noticed.
        let wanted: TimeInterval = 1.0
        if abs(wanted - pollInterval) > 0.01 {
            pollInterval = wanted
            poller?.setInterval(wanted)
        }
    }

    private func setPlayerState(_ newValue: String) {
        guard playerState != newValue else { return }
        playerState = newValue
    }

    /// `@Published` fires on *every* assignment, even when the value is
    /// unchanged. Only assign on real changes.
    private func setPlaying(_ newValue: Bool) {
        guard isPlaying != newValue else { return }
        isPlaying = newValue
    }

    private func setTrack(_ newValue: CurrentTrack?) {
        guard track != newValue else { return }
        track = newValue
    }

    // MARK: - Playback control

    public func togglePlayPause() {
        poller?.run("tell application \"Music\" to playpause")
        poller?.pollOnce()
    }

    public func nextTrack() {
        poller?.run("tell application \"Music\" to next track")
        poller?.pollOnce()
    }

    public func previousTrack() {
        poller?.run("tell application \"Music\" to previous track")
        poller?.pollOnce()
    }

    public func seek(to seconds: TimeInterval) {
        let clamped = max(0, seconds)
        poller?.run("tell application \"Music\" to set player position to \(clamped)")
        anchorPosition = clamped
        anchorDate = Date()
    }

    // MARK: - Notifications

    @objc private func playerInfoChanged(_ note: Notification) {
        refreshNowPlaying()
    }

    /// Re-read track metadata + playback state from the Music app.
    public func refreshNowPlaying() {
        poller?.pollOnce()
    }
}
