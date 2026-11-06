import Foundation
import LyricEngine

/// Reads Apple Music's **own** synced lyrics straight out of the cache the
/// Music app maintains on disk.
///
/// Why this exists
/// ---------------
/// Apple does not expose lyric *content* through any public MusicKit API —
/// that is precisely why every third-party lyrics app (Lyric Fever included)
/// has to re-match your track against Spotify / LRCLIB / NetEase.
///
/// The Music app itself, however, already downloads the official TTML lyrics
/// for whatever it plays and stores them under
/// `~/Library/Caches/com.apple.Music/fsCachedData/`.
/// Reading that cache gives us Apple Music's own timed lyrics for the
/// currently playing track: no developer token, no third-party service,
/// no re-matching against a foreign catalogue.
public enum AppleMusicCacheLyricsSource {

    public enum CacheError: Error, LocalizedError {
        case cacheUnavailable
        case noLyrics
        case noTimeSyncedLyrics

        public var errorDescription: String? {
            switch self {
            case .cacheUnavailable:
                return "读不到「音乐」的本地歌词缓存。请播放曲库里的歌，并在「音乐」中打开一次「歌词」面板。"
            case .noLyrics:
                return "这首歌还没有歌词。请在「音乐」App 里点开一次「歌词」按钮，让它把同步歌词下载到本机；若已打开仍没有，说明 Apple 未提供这首歌的同步歌词。"
            case .noTimeSyncedLyrics:
                return "Apple Music 本身就没有这首曲目的同步歌词(不回退到外部歌词源)。"
            }
        }
    }

    /// Why a lookup failed — lets the UI say something useful instead of a
    /// generic “no lyrics”, which is what made this look like a bug.
    public struct Diagnostic: Sendable {
        public let cacheEntryCount: Int
        public let bestScore: Double
        public let bestTitle: String?
        /// Apple's own flag on the *song* record: does a synced lyric exist
        /// in the catalogue at all?
        public let catalogueHasSyncedLyrics: Bool?
        public let foundSongRecord: Bool
        /// Highest-scoring candidate that was *rejected* by the identity gate
        /// — i.e. the song we nearly showed the wrong lyrics for.
        public let rejectedTitle: String?
        public let rejectedScore: Double
    }

    /// One song's lyrics found in the cache.
    public struct Entry: Sendable {
        public let songID: String?
        public let title: String
        public let artist: String
        public let album: String
        public let duration: TimeInterval
        public let ttml: String
        /// `{w}x{h}{c}.{f}` style artwork template straight from Apple.
        public let artworkURLTemplate: String?
        /// Apple's own artwork-derived colours: `bgColor` / `textColor1`.
        public let bgColorHex: String?
        public let textColorHex: String?
    }

    /// Artwork + the colour pair Apple computed for that artwork.
    public struct ArtworkInfo: Sendable {
        public let urlTemplate: String
        public let bgColorHex: String?
        public let textColorHex: String?

        /// Apple serves artwork from a size-templated URL.
        public func url(size: Int) -> URL? {
            let filled = urlTemplate
                .replacingOccurrences(of: "{w}", with: "\(size)")
                .replacingOccurrences(of: "{h}", with: "\(size)")
                .replacingOccurrences(of: "{c}", with: "bb")
                .replacingOccurrences(of: "{f}", with: "jpg")
            return URL(string: filled)
        }
    }

    // MARK: - Location

    /// Exposed so the app can watch this directory for new lyrics landing.
    public static var cacheDirectory: URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home
            .appendingPathComponent("Library/Caches/com.apple.Music/fsCachedData", isDirectory: true)
    }

    // MARK: - Public API

    /// A song record in the cache — present even when Apple has no synced
    /// lyrics for it, which is what lets us tell “not downloaded yet” apart
    /// from “does not exist”.
    public struct SongRecord: Sendable {
        public let id: String
        public let title: String
        public let artist: String
        public let album: String
        public let duration: TimeInterval
        /// Apple's own catalogue flag.
        public let hasTimeSyncedLyrics: Bool?
    }

    private struct Scan {
        let entries: [Entry]
        let records: [SongRecord]
    }

    /// Scan the cache and return every song that has TTML lyrics.
    public static func loadEntries() -> [Entry] { currentScan().entries }

    /// Every song record in the cache, lyrics or not.
    public static func songRecords() -> [SongRecord] { currentScan().records }

    /// A single lookup used to call `scan()` three or four times (lyrics +
    /// artwork + diagnostics), each one re-reading and re-parsing every file
    /// in the cache directory. Memoise briefly so one track change costs one
    /// scan, not four. Short TTL: new lyrics land asynchronously, so we must
    //  not hold a stale view for long.
    private static let scanTTL: TimeInterval = 2.0
    private nonisolated(unsafe) static var memo: (at: Date, scan: Scan)?
    private static let memoLock = NSLock()

    private static func currentScan() -> Scan {
        memoLock.lock()
        if let m = memo, Date().timeIntervalSince(m.at) < scanTTL {
            memoLock.unlock()
            return m.scan
        }
        memoLock.unlock()

        let fresh = scan()

        memoLock.lock()
        memo = (Date(), fresh)
        memoLock.unlock()
        return fresh
    }

    private static func scan() -> Scan {
        guard let dir = cacheDirectory,
              let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path),
              !names.isEmpty else { return Scan(entries: [], records: []) }

        var songMeta: [String: (title: String, artist: String, album: String, duration: TimeInterval)] = [:]
        var hasSynced: [String: Bool] = [:]
        var artworkByID: [String: (template: String?, bg: String?, fg: String?)] = [:]
        var lyricByID: [String: String] = [:]
        var standalone: [(id: String?, ttml: String)] = []

        for name in names {
            let url = dir.appendingPathComponent(name)
            guard let data = try? Data(reading: url),
                  let object = try? jsonObject(from: data) else { continue }

            guard let items = object["data"] as? [[String: Any]] else { continue }

            for item in items {
                let type = (item["type"] as? String) ?? ""
                let id = (item["id"] as? String) ?? ""
                let attrs = item["attributes"] as? [String: Any]

                if type == "songs", let a = attrs {
                    let title = (a["name"] as? String) ?? ""
                    let artist = (a["artistName"] as? String) ?? ""
                    let album = (a["albumName"] as? String) ?? ""
                    let ms = (a["durationInMillis"] as? NSNumber)?.doubleValue
                        ?? Double((a["durationInMillis"] as? Int) ?? 0)
                    songMeta[id] = (title, artist, album, ms / 1000.0)
                    if let flag = a["hasTimeSyncedLyrics"] as? Bool { hasSynced[id] = flag }

                    if let art = a["artwork"] as? [String: Any] {
                        let template = art["url"] as? String
                        let bg = art["bgColor"] as? String
                        let fg = art["textColor1"] as? String
                        artworkByID[id] = (template, bg, fg)
                    }
                }

                // The TTML may hang off the song's `syllable-lyrics`
                // relationship, or be the payload of a standalone response.
                if let ttml = findTTML(in: item), !ttml.isEmpty {
                    if !id.isEmpty {
                        lyricByID[id] = ttml
                    } else {
                        standalone.append((id, ttml))
                    }
                }
            }
        }

        var entries: [Entry] = []
        for (id, ttml) in lyricByID {
            let meta = songMeta[id] ?? (title: "", artist: "", album: "", duration: 0)
            let art = artworkByID[id]
            entries.append(Entry(songID: id,
                                 title: meta.title,
                                 artist: meta.artist,
                                 album: meta.album,
                                 duration: meta.duration,
                                 ttml: ttml,
                                 artworkURLTemplate: art?.template,
                                 bgColorHex: art?.bg,
                                 textColorHex: art?.fg))
        }
        for s in standalone {
            let meta = s.id.flatMap { songMeta[$0] }
            let art = s.id.flatMap { artworkByID[$0] }
            entries.append(Entry(songID: s.id,
                                 title: meta?.title ?? "",
                                 artist: meta?.artist ?? "",
                                 album: meta?.album ?? "",
                                 duration: meta?.duration ?? 0,
                                 ttml: s.ttml,
                                 artworkURLTemplate: art?.template,
                                 bgColorHex: art?.bg,
                                 textColorHex: art?.fg))
        }

        let records = songMeta.map { id, meta in
            SongRecord(id: id,
                       title: meta.title,
                       artist: meta.artist,
                       album: meta.album,
                       duration: meta.duration,
                       hasTimeSyncedLyrics: hasSynced[id])
        }
        return Scan(entries: entries, records: records)
    }

    /// Artwork + Apple's own colour pair for the currently playing track.
    public static func artworkInfo(for track: CurrentTrack) -> ArtworkInfo? {
        guard let entry = bestEntry(for: track),
              let template = entry.artworkURLTemplate, !template.isEmpty else { return nil }
        return ArtworkInfo(urlTemplate: template,
                           bgColorHex: entry.bgColorHex,
                           textColorHex: entry.textColorHex)
    }

    /// Best-matching cached entry for the track currently playing.
    public static func bestEntry(for track: CurrentTrack) -> Entry? {
        bestMatch(for: track)?.entry
    }

    /// Same, but also reports the score so the UI can explain a near miss.
    public static func bestMatch(for track: CurrentTrack) -> (entry: Entry, score: Double)? {
        guard let top = rankedEntries(for: track).first(where: { $0.accepted }) else { return nil }
        return (top.entry, top.score)
    }

    /// A cache entry scored against the playing track.
    private struct Ranked {
        let entry: Entry
        let score: Double
        /// False when it only *looks* similar (e.g. same artist) and must
        /// never be used as the answer.
        let accepted: Bool
    }

    /// Every entry, best first, each flagged as usable or not.
    ///
    /// Why the acceptance gate is separate from the score
    /// -------------------------------------------------
    /// An earlier version summed weighted signals and accepted anything over
    /// a threshold. "Same artist" alone scored 4 and the threshold *was* 4,
    /// so when 《珠玉》 started playing while the cache still held only the
    /// previous track 《我管不住我自己》 (same artist, same album), the app
    /// happily displayed that track's 69 lines — it looked like the lyrics
    /// were wrong until you hit refresh.
    /// A score can only rank; it cannot decide. Identity needs a gate:
    /// the title must agree; artist + duration is only a fallback when a
    /// title is missing entirely (same artist + similar length is NOT enough —
    /// it matched 《22》 and 《Fortnight》 to the wrong Taylor Swift song).
    private static func rankedEntries(for track: CurrentTrack) -> [Ranked] {
        let wantedTitle = LyricMatch.normalize(track.title)
        let wantedArtist = LyricMatch.normalize(track.artist)

        var ranked: [Ranked] = []
        for e in loadEntries() {
            let v = LyricMatch.evaluate(candidateTitle: LyricMatch.normalize(e.title),
                                        candidateArtist: LyricMatch.normalize(e.artist),
                                        candidateDuration: e.duration,
                                        targetTitle: wantedTitle,
                                        targetArtist: wantedArtist,
                                        targetDuration: track.duration)
            ranked.append(Ranked(entry: e, score: v.score, accepted: v.accepted))
        }
        return ranked.sorted { $0.score > $1.score }
    }

    /// Explain *why* there are no lyrics, so the UI never has to guess.
    public static func diagnose(for track: CurrentTrack) -> Diagnostic {
        let scanResult = currentScan()
        let ranked = rankedEntries(for: track)
        let match = ranked.first { $0.accepted }
        let rejected = ranked.first { !$0.accepted }

        // Is there a *song record* for this track (Apple knows the song) that
        // says it simply has no time-synced lyrics?
        let wantedTitle = LyricMatch.normalize(track.title)
        var catalogueFlag: Bool?
        var foundRecord = false
        for r in scanResult.records {
            let title = LyricMatch.normalize(r.title)
            let artist = LyricMatch.normalize(r.artist)
            let titleOK = title == wantedTitle
                || (!wantedTitle.isEmpty && (title.contains(wantedTitle) || wantedTitle.contains(title)))
            let artistOK = artist == LyricMatch.normalize(track.artist)
                || (!artist.isEmpty && (artist.contains(LyricMatch.normalize(track.artist)) || LyricMatch.normalize(track.artist).contains(artist)))
            let durationOK = r.duration > 0 && track.duration > 0 && abs(r.duration - track.duration) < 2.5
            if (titleOK && artistOK) || (titleOK && durationOK) {
                foundRecord = true
                catalogueFlag = r.hasTimeSyncedLyrics
                if r.hasTimeSyncedLyrics == true { break }
            }
        }

        return Diagnostic(cacheEntryCount: scanResult.entries.count,
                          bestScore: match?.score ?? 0,
                          bestTitle: match?.entry.title,
                          catalogueHasSyncedLyrics: catalogueFlag,
                          foundSongRecord: foundRecord,
                          rejectedTitle: rejected?.entry.title,
                          rejectedScore: rejected?.score ?? 0)
    }

    /// Parse the cached lyrics for the given track.
    public static func lyrics(for track: CurrentTrack) throws -> TimedLyrics {
        guard let entry = bestEntry(for: track) else {
            if currentScan().entries.isEmpty { throw CacheError.cacheUnavailable }
            // The Music app downloads the TTML asynchronously: "not here yet"
            // and "does not exist" are different situations, and only the
            // second one should stop the retry loop.
            let d = diagnose(for: track)
            if d.foundSongRecord, d.catalogueHasSyncedLyrics == false {
                throw CacheError.noTimeSyncedLyrics
            }
            throw CacheError.noLyrics
        }
        let parsed = try TTMLParser.parse(entry.ttml,
                                          source: "Apple Music(本地缓存)",
                                          songID: entry.songID,
                                          songDuration: entry.duration > 0 ? entry.duration : nil)
        guard !parsed.lines.isEmpty else { throw CacheError.noLyrics }
        return parsed
    }

    // MARK: - Helpers

    /// Recursively locate a `ttmlLocalizations` string in an arbitrary
    /// JSON object (it is nested at different depths across API versions).
    private static func findTTML(in object: [String: Any]) -> String? {
        for (key, value) in object {
            if key == "ttmlLocalizations" || key == "ttml", let s = value as? String, !s.isEmpty {
                return s
            }
            if let nested = value as? [String: Any], let found = findTTML(in: nested) {
                return found
            }
            if let array = value as? [[String: Any]] {
                for element in array {
                    if let found = findTTML(in: element) { return found }
                }
            }
            if let array = value as? [Any] {
                for element in array {
                    if let dict = element as? [String: Any], let found = findTTML(in: dict) {
                        return found
                    }
                }
            }
        }
        return nil
    }

    /// `NSURLCache` bodies sometimes carry a small binary prologue/epilogue.
    private static func jsonObject(from data: Data) throws -> [String: Any] {
        if let direct = try? JSONSerialization.jsonObject(with: data), let obj = direct as? [String: Any] {
            return obj
        }
        let bytes = [UInt8](data)
        guard let start = bytes.firstIndex(of: UInt8(ascii: "{")),
              let end = bytes.lastIndex(of: UInt8(ascii: "}")),
              start < end else {
            throw CacheError.cacheUnavailable
        }
        let slice = Data(bytes[start...end])
        guard let obj = try JSONSerialization.jsonObject(with: slice) as? [String: Any] else {
            throw CacheError.cacheUnavailable
        }
        return obj
    }

}

private extension Data {
    /// Read a file, tolerating files that shrink while being read.
    init(reading url: URL) throws {
        self = try Data(contentsOf: url, options: [.mappedIfSafe])
    }
}
