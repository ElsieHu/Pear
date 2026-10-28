import Foundation

/// Parses standard `.lrc` files (and the enhanced `<mm:ss.xx>` inline word tags).
///
/// Basic LRC:
/// ```
/// [00:12.34]Some lyrics here
/// [00:15.00][00:40.00]A line that repeats
/// ```
/// Enhanced LRC with word timing:
/// ```
/// [00:12.00]<00:12.00>Hello <00:12.50>world
/// ```
public struct LRCParser {

    public static func parse(_ lrc: String, source: String = "Local LRC", songID: String? = nil) -> TimedLyrics {
        var lines: [LyricLine] = []
        var lastEnd: TimeInterval = 0

        for rawLine in lrc.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            // Every meaningful LRC line begins with a [timestamp].
            guard !line.isEmpty, line.hasPrefix("["), line.contains("]") else { continue }

            // Collect all leading [time] stamps.
            var timestamps: [TimeInterval] = []
            var rest = line[line.startIndex...]
            while rest.hasPrefix("["),
                  let close = rest.firstIndex(of: "]") {
                let stamp = String(rest[rest.index(after: rest.startIndex)..<close])
                if let t = parseStamp(stamp) {
                    timestamps.append(t)
                }
                rest = rest[rest.index(after: close)...]
            }
            let rawBody = String(rest).trimmingCharacters(in: .whitespaces)
            // Metadata tags such as [ti:Demo] yield no valid timestamp -> skip.
            guard !timestamps.isEmpty else { continue }

            // Display text has the inline <mm:ss.xx> word tags removed.
            let textBody = stripInlineTags(rawBody)

            for t in timestamps {
                let (segs, _) = parseInlineWords(rawBody, lineStart: t)
                let startTime = t
                let endTime = segs.last?.endTime ?? (t + max(2.0, lastEnd - t))
                let lyricLine = LyricLine(
                    text: textBody,
                    segments: segs,
                    startTime: startTime,
                    endTime: endTime
                )
                lines.append(lyricLine)
                lastEnd = max(lastEnd, endTime)
            }
        }

        lines.sort { $0.startTime < $1.startTime }
        return TimedLyrics(lines: lines, source: source, songID: songID, ttml: nil)
    }

    // MARK: - Private

    /// Remove inline `<mm:ss.xx>` word tags so they never appear in display text.
    private static func stripInlineTags(_ s: String) -> String {
        let pattern = #"<(\d+):(\d+(?:\.\d+)?)>"#
        return s.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    /// Parse `[mm:ss.xx]` or `[mm:ss]` or `[mm:ss.xxx]`.
    private static func parseStamp(_ s: String) -> TimeInterval? {
        let parts = s.split(separator: ":")
        guard parts.count == 2,
              let m = Double(parts[0]),
              let sec = Double(parts[1]) else { return nil }
        return m * 60 + sec
    }

    /// Parse enhanced `<mm:ss.xx>` inline word tags. Falls back to a single
    /// untimed block when none are present.
    private static func parseInlineWords(_ body: String, lineStart: TimeInterval) -> ([LyricSegment], TimeInterval) {
        let pattern = #"<(\d+):(\d+(?:\.\d+)?)>"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return ([], lineStart + 4)
        }
        let ns = body as NSString
        let matches = regex.matches(in: body, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else {
            return ([], lineStart + 4)
        }

        var segs: [LyricSegment] = []
        for (i, m) in matches.enumerated() {
            let minRange = m.range(at: 1)
            let secRange = m.range(at: 2)
            guard let minStr = minRange.location != NSNotFound ? ns.substring(with: minRange) : nil,
                  let secStr = secRange.location != NSNotFound ? ns.substring(with: secRange) : nil,
                  let mins = Double(minStr), let secs = Double(secStr) else { continue }
            let wordStart = mins * 60 + secs

            // Text belonging to this tag = between this tag and the next.
            let textStart = m.range.location + m.range.length
            let textEnd = (i + 1 < matches.count) ? matches[i + 1].range.location : ns.length
            let wordText = ns.substring(with: NSRange(location: textStart, length: max(0, textEnd - textStart)))
                .trimmingCharacters(in: .whitespaces)

            let wordEnd = (i + 1 < matches.count) ? wordStartTime(matches[i + 1], ns) : wordStart + 1.5
            guard !wordText.isEmpty else { continue }
            segs.append(LyricSegment(text: wordText, startTime: wordStart, endTime: wordEnd))
        }
        let end = segs.last?.endTime ?? lineStart + 4
        return (segs, end)
    }

    private static func wordStartTime(_ m: NSTextCheckingResult, _ ns: NSString) -> TimeInterval {
        let minRange = m.range(at: 1)
        let secRange = m.range(at: 2)
        guard let minStr = minRange.location != NSNotFound ? ns.substring(with: minRange) : nil,
              let secStr = secRange.location != NSNotFound ? ns.substring(with: secRange) : nil,
              let mins = Double(minStr), let secs = Double(secStr) else { return 0 }
        return mins * 60 + secs
    }
}
