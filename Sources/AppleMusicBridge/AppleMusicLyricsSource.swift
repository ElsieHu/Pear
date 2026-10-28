import Foundation
import MusicKit
import LyricEngine

public enum AppleMusicLyricsError: Error, LocalizedError {
    case notAuthorized
    case noMatch
    case noLyrics
    case requestFailed(Error)
    case unknown(String)

    public var errorDescription: String? {
        switch self {
        case .notAuthorized:
            return "未获得 Apple Music 授权,请在系统设置中允许本应用访问 Apple Music。"
        case .noMatch:
            return "未能在 Apple Music 目录中找到当前曲目。"
        case .noLyrics:
            return "Apple Music 未提供该曲目的同步歌词(本应用不回退到外部歌词源)。"
        case let .requestFailed(e):
            return "Apple Music 请求失败: \(e.localizedDescription)"
        case let .unknown(msg):
            return msg
        }
    }
}

/// Fetches lyrics **directly from Apple Music's own catalog** for the track
/// that is currently playing in the Music app.
///
/// Flow:
/// 1. Resolve the now-playing track to an Apple Music catalog `Song`
///    (catalog search scoped to Apple Music — this is *not* an external
///    lyric database; it only locates Apple Music's own record).
/// 2. Request that song's lyrics from the Apple Music API, which returns the
///    official TTML document.
/// 3. Parse the TTML into timed word/line segments.
///
/// Per the product requirement, this source deliberately does **not** fall
/// back to Spotify / LRCLIB / NetEase / QQ when Apple Music has no lyrics;
/// it reports the gap instead.
/// `@unchecked Sendable`: instances are created once and driven exclusively
/// from the main actor (`AppState`), so `cachedStorefront` is never
/// concurrently mutated.
public final class AppleMusicLyricsSource: @unchecked Sendable {

    public init() {}

    /// Cached storefront for the signed-in Apple Music account.
    private var cachedStorefront: String?

    /// Request MusicKit authorization. Call once at launch.
    @discardableResult
    public static func ensureAuthorized() async -> Bool {
        let status = await MusicAuthorization.request()
        return status == .authorized
    }

    /// Fetch lyrics for a track resolved from the Music app's now-playing info.
    public func fetchLyrics(for track: CurrentTrack) async throws -> TimedLyrics {
        let song = try await resolveSong(track)
        return try await fetchLyrics(for: song)
    }

    /// Fetch lyrics when the exact Apple Music catalog song id is already known
    /// (e.g. via the private "current store ID" path described in the README).
    public func fetchLyrics(songID: String, storefront: String? = nil) async throws -> TimedLyrics {
        let sf: String
        if let provided = storefront {
            sf = provided
        } else {
            sf = try await currentStorefront()
        }
        let ttml = try await fetchLyricsTTML(songID: songID, storefront: sf)
        return try TTMLParser.parse(ttml, source: "Apple Music", songID: songID)
    }

    // MARK: - Resolution

    private func resolveSong(_ track: CurrentTrack) async throws -> Song {
        let term = "\(track.title) \(track.artist)".trimmingCharacters(in: .whitespaces)
        var request = MusicCatalogSearchRequest(term: term, types: [Song.self])
        request.limit = 25
        let response = try await request.response()
        guard !response.songs.isEmpty else { throw AppleMusicLyricsError.noMatch }
        return Self.bestMatch(in: response.songs, for: track)
    }

    private static func bestMatch(in songs: MusicItemCollection<Song>, for track: CurrentTrack) -> Song {
        let title = track.title.lowercased()
        let artist = track.artist.lowercased()
        var best = songs.first!
        var bestScore = -1.0
        for song in songs {
            let sTitle = song.title.lowercased()
            let sArtist = song.artistName.lowercased()
            var score = 0.0
            if sTitle.contains(title) || title.contains(sTitle) { score += 2 }
            if !sArtist.isEmpty, (sArtist.contains(artist) || artist.contains(sArtist)) { score += 2 }
            if let dur = song.duration, abs(dur - track.duration) < 3 { score += 1 }
            if score > bestScore { bestScore = score; best = song }
        }
        return best
    }

    private func fetchLyrics(for song: Song) async throws -> TimedLyrics {
        let sf = try await currentStorefront()
        let ttml = try await fetchLyricsTTML(songID: song.id.rawValue, storefront: sf)
        return try TTMLParser.parse(ttml, source: "Apple Music", songID: song.id.rawValue)
    }

    /// Resolve the signed-in user's Apple Music storefront (e.g. "cn", "us")
    /// through the Apple Music API. Cached after the first successful call.
    private func currentStorefront() async throws -> String {
        if let cached = cachedStorefront { return cached }
        guard let url = URL(string: "https://api.music.apple.com/v1/me/storefront") else {
            throw AppleMusicLyricsError.unknown("storefront URL 无效")
        }
        let req = MusicDataRequest(urlRequest: URLRequest(url: url))
        let resp = try await req.response()
        guard let json = try? JSONSerialization.jsonObject(with: resp.data) as? [String: Any],
              let arr = json["data"] as? [[String: Any]],
              let first = arr.first,
              let id = first["id"] as? String,
              !id.isEmpty else {
            throw AppleMusicLyricsError.unknown("无法读取 Apple Music 商店区域(storefront)")
        }
        cachedStorefront = id
        return id
    }

    // MARK: - Raw TTML fetch

    private func fetchLyricsTTML(songID: String, storefront: String) async throws -> String {
        let urlString = "https://api.music.apple.com/v1/catalog/\(storefront)/songs/\(songID)/lyrics"
        guard let url = URL(string: urlString) else { throw AppleMusicLyricsError.noLyrics }
        let urlRequest = URLRequest(url: url)
        let dataRequest = MusicDataRequest(urlRequest: urlRequest)
        let response = try await dataRequest.response()
        let data = response.data
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let arr = json["data"] as? [[String: Any]],
              let first = arr.first,
              let attrs = first["attributes"] as? [String: Any],
              let ttml = attrs["ttml"] as? String,
              !ttml.isEmpty else {
            throw AppleMusicLyricsError.noLyrics
        }
        return ttml
    }
}
