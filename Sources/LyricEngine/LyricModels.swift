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

// MARK: - Outro trimming

extension TimedLyrics {
    /// Return a copy whose **last line ends where the singing actually ends**,
    /// not at the end of the track.
    ///
    /// Apple's TTML frequently gives the final `<p>` an `end` equal to the
    /// whole track length — i.e. "last line + instrumental outro". Using that
    /// as the line's end stretches the karaoke sweep across the tail: the
    /// highlight is still crawling along long after the words are finished,
    /// so the displayed progress no longer matches the playback position.
    ///
    /// The trim only fires with **positive evidence** of an outro: word
    /// timings that stop well before the line's `end`, or a known track
    /// duration whose end the line sits right up against. A merely long
    /// window with no duration and no word timing is *not* enough — guessing
    /// there could cut a legitimately long final note. Ordinary lines are
    /// left untouched.
    public func trimmingOutro(songDuration: TimeInterval? = nil) -> TimedLyrics {
        guard let last = lines.last else { return self }
        let earlier = Array(lines.dropLast())

        // Typical duration of a *sung* line, used as a sanity ceiling.
        let durations = earlier.map { $0.endTime - $0.startTime }
            .filter { $0 > 0.5 && $0 < 30 }
            .sorted()
        let typical = durations.isEmpty ? 4.0 : durations[durations.count / 2]
        let ceiling = max(typical * 2.0, 6.0)

        let segEnd = last.segments.last?.endTime
        var target: TimeInterval?

        if let segEnd, segEnd > last.startTime, last.endTime > segEnd + 0.5 {
            // Word timings describe the singing, not the instrumental tail.
            // This is the strongest evidence and works even without a duration.
            target = segEnd
        } else if let d = songDuration, d > 0,
                  last.endTime >= d - max(0.75, d * 0.01),
                  last.endTime - last.startTime > ceiling {
            // Line-timed: `end` is set to (or within 1% of) the track end and
            // the window is far longer than a normal sung line, so the outro
            // was folded into it. Estimate the singing window from earlier lines.
            target = segEnd.map { max($0, last.startTime + 0.5) }
                ?? (last.startTime + typical)
        }

        guard let t = target, last.endTime > t + 0.5 else { return self }
        let end = max(t, last.startTime + 0.5)
        let fixed = LyricLine(text: last.text,
                              segments: last.segments,
                              startTime: last.startTime,
                              endTime: end,
                              background: last.background,
                              translations: last.translations)
        return TimedLyrics(lines: earlier + [fixed],
                           source: source, songID: songID, ttml: ttml)
    }
}
