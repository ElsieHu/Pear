import Foundation
import Dispatch

/// Reads “now playing” through the MediaRemote private framework.
///
/// Why this exists
/// ---------------
/// Reading what the Music app is playing normally requires Apple Events,
/// which means the user has to grant the app “自动化” (Automation) access in
/// System Settings. Until they do, the app sees *nothing* and every song
/// looks like it has no lyrics.
///
/// MediaRemote is the same channel the system's own now-playing widgets use
/// and needs no permission at all. It is a private framework, so we load it
/// lazily with `dlopen` and fall back to AppleScript if it is ever missing
/// or changes shape — the app must still work without it.
public enum MediaRemoteBridge {

    private static let frameworkPath =
        "/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote"

    // Lazily resolved once on first use and never mutated afterwards; the
    // function pointer and dlopen handle are plain C values.
    private nonisolated(unsafe) static var handle: UnsafeMutableRawPointer?
    private nonisolated(unsafe) static var didLoad = false

    private typealias GetInfoFn = @convention(c) (DispatchQueue, @escaping ([String: Any]?) -> Void) -> Void
    private nonisolated(unsafe) static var getInfo: GetInfoFn?

    private static func load() -> Bool {
        if didLoad { return getInfo != nil }
        didLoad = true
        guard let h = dlopen(frameworkPath, RTLD_NOW) else { return false }
        guard let sym = dlsym(h, "MRMediaRemoteGetNowPlayingInfo") else { return false }
        handle = h
        getInfo = unsafeBitCast(sym, to: GetInfoFn.self)
        return true
    }

    /// Whether the private framework is usable on this system.
    public static var isAvailable: Bool { load() }

    /// Current now-playing state, or nil when nothing is playing / the
    /// framework is unavailable. Blocks the *calling* thread briefly (the
    /// callback itself is delivered on the main queue, which the app's run
    /// loop keeps draining).
    static func snapshot() -> MusicSnapshot? {
        guard load(), let getInfo else { return nil }

        var result: MusicSnapshot?
        let done = DispatchSemaphore(value: 0)

        getInfo(DispatchQueue.main) { info in
            defer { done.signal() }
            guard let info, !info.isEmpty else { return }
            result = Self.parse(info)
        }
        _ = done.wait(timeout: .now() + 1.5)
        return result
    }

    // MARK: - Parsing

    private static func parse(_ info: [String: Any]) -> MusicSnapshot? {
        let title = string(info, "kMRMediaRemoteNowPlayingInfoTitle")
        guard !title.isEmpty else { return nil }

        let artist = string(info, "kMRMediaRemoteNowPlayingInfoArtist")
        let album = string(info, "kMRMediaRemoteNowPlayingInfoAlbum")
        let duration = number(info, "kMRMediaRemoteNowPlayingInfoDuration")
        let elapsed = number(info, "kMRMediaRemoteNowPlayingInfoElapsedTime")
        let rate = number(info, "kMRMediaRemoteNowPlayingInfoPlaybackRate")
        let isPlaying = rate > 0.01

        // MediaRemote has no library persistent ID; derive a stable-enough
        // one from the metadata so track-change detection still works.
        let pid = "mr|\(title)|\(artist)|\(album)"

        return MusicSnapshot(state: isPlaying ? "playing" : "paused",
                             position: elapsed,
                             title: title,
                             artist: artist,
                             album: album,
                             duration: duration,
                             persistentID: pid)
    }

    private static func string(_ info: [String: Any], _ key: String) -> String {
        (info[key] as? String) ?? ""
    }

    private static func number(_ info: [String: Any], _ key: String) -> TimeInterval {
        if let n = info[key] as? NSNumber { return n.doubleValue }
        if let d = info[key] as? Double { return d }
        if let i = info[key] as? Int { return TimeInterval(i) }
        return 0
    }
}
