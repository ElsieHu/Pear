import Foundation

/// A single timed segment (typically a word / syllable) inside a lyric line.
public struct LyricSegment: Sendable, Identifiable, Hashable {
    public let id = UUID()
    public let text: String
    public let startTime: TimeInterval
    public let endTime: TimeInterval

    public init(text: String, startTime: TimeInterval, endTime: TimeInterval) {
        self.text = text
        self.startTime = startTime
        self.endTime = endTime
    }
}

/// A line of lyrics with optional word-level timing.
public struct LyricLine: Sendable, Identifiable, Hashable {
    public let id = UUID()
    public let text: String
    public let segments: [LyricSegment]
    public let startTime: TimeInterval
    public let endTime: TimeInterval
    /// Apple Music marks background vocals on their own line.
    public let background: Bool
    /// Optional per-language translation (languageCode -> text).
    public var translations: [String: String]

    public init(
        text: String,
        segments: [LyricSegment],
        startTime: TimeInterval,
        endTime: TimeInterval,
        background: Bool = false,
        translations: [String: String] = [:]
    ) {
        self.text = text
        self.segments = segments
        self.startTime = startTime
        self.endTime = endTime
        self.background = background
        self.translations = translations
    }
}

/// Fully parsed, time-synchronised lyrics.
public struct TimedLyrics: Sendable {
    public let lines: [LyricLine]
    /// Human readable origin, e.g. "Apple Music".
    public let source: String
    /// The Apple Music catalog song id these lyrics came from (if known).
    public let songID: String?
    /// Raw TTML document (kept for debugging / re-parsing).
    public let ttml: String?

    public init(lines: [LyricLine], source: String, songID: String? = nil, ttml: String? = nil) {
        self.lines = lines
        self.source = source
        self.songID = songID
        self.ttml = ttml
    }

    /// True when at least some lines carry word-level timing.
    public var hasWordTiming: Bool {
        lines.contains { !$0.segments.isEmpty }
    }
}
