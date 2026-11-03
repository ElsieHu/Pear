import Foundation

/// Errors produced while parsing Apple Music TTML lyrics.
public enum LyricsParseError: Error, LocalizedError {
    case emptyDocument
    case malformedTime(String)

    public var errorDescription: String? {
        switch self {
        case .emptyDocument:
            return "歌词文档为空或无法解析。"
        case let .malformedTime(v):
            return "无法解析时间值: \(v)"
        }
    }
}

/// Parses Apple Music lyrics, which are delivered as TTML
/// (Timed Text Markup Language).
///
/// Apple Music ships two flavours of the same document:
///
/// 1. **Word / syllable timing** — `itunes:timing="Word"`, where each line
///    (`<p>`) contains nested `<span>` elements carrying their own timings.
/// 2. **Line timing** — `itunes:timing="Line"`, where `<p>` has timings but
///    its text is plain (no `<span>` children at all).
///
/// Both must be supported: a large share of the catalogue (especially
/// Chinese releases) is line-timed only.
///
/// ```xml
/// <p begin="15.089" end="20.796" itunes:key="L191">一九八四年 庄稼还没 收割完</p>
/// ```
public struct TTMLParser {

    /// Parse a raw TTML string into `TimedLyrics`.
    /// - Parameters:
    ///   - ttml: Raw TTML document returned by the Apple Music lyrics endpoint.
    ///   - source: Origin label (defaults to "Apple Music").
    ///   - songID: Apple Music catalog song id these lyrics belong to.
    ///   - songDuration: Full track length in seconds, when known. Used to
    ///     recognise a final line whose `end` was set to the end of the track
    ///     (instrumental outro included) rather than the end of the singing.
    public static func parse(_ ttml: String, source: String = "Apple Music",
                             songID: String? = nil,
                             songDuration: TimeInterval? = nil) throws -> TimedLyrics {
        guard !ttml.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LyricsParseError.emptyDocument
        }

        let delegate = TTMLParserDelegate()
        let parser = XMLParser(data: Data(ttml.utf8))
        parser.delegate = delegate
        parser.shouldProcessNamespaces = false
        guard parser.parse(), let lines = delegate.result, !lines.isEmpty else {
            throw LyricsParseError.emptyDocument
        }

        // Defensive: ensure every line has a usable time window even if a
        // `<p>` had no timing attributes.
        var lastEnd: TimeInterval = 0
        let sanitized = lines.map { line -> LyricLine in
            var start = line.startTime
            var end = line.endTime
            if start <= 0 && end <= 0 {
                start = lastEnd
                end = lastEnd + 4
            } else if end <= start {
                end = start + 4
            }
            lastEnd = max(lastEnd, end)
            return LyricLine(
                text: line.text,
                segments: line.segments,
                startTime: start,
                endTime: end,
                background: line.background,
                translations: line.translations
            )
        }

        return TimedLyrics(lines: sanitized, source: source, songID: songID, ttml: ttml)
            .trimmingOutro(songDuration: songDuration)
    }
}

private final class TTMLParserDelegate: NSObject, XMLParserDelegate {
    var result: [LyricLine]?

    private var currentLineBegin: TimeInterval?
    private var currentLineEnd: TimeInterval?
    private var currentSpans: [(text: String, begin: TimeInterval?, end: TimeInterval?)] = []

    /// Every character inside the current `<p>`, including span text.
    /// Used for line-timed documents that carry no `<span>` at all.
    private var lineTextBuffer = ""
    private var inParagraph = false

    private var spanDepth = 0
    private var spanText = ""
    private var spanBegin: TimeInterval?
    private var spanEnd: TimeInterval?

    private var lineBackground = false
    private var divBackgroundStack: [Bool] = []

    // MARK: - XMLParserDelegate

    func parser(_ parser: XMLParser,
                didStartElement elementName: String,
                namespaceURI: String?,
                qualifiedName: String?,
                attributes: [String: String]) {
        let name = elementName.lowercased()

        if name == "div" {
            divBackgroundStack.append(Self.isBackground(attributes))
            return
        }

        if name == "p" {
            inParagraph = true
            lineTextBuffer = ""
            currentLineBegin = parseTime(attributes["begin"])
            currentLineEnd = parseTime(attributes["end"])
            currentSpans = []
            lineBackground = divBackgroundStack.last == true || Self.isBackground(attributes)
            return
        }

        if name == "span" {
            // Apple nests spans for syllable data; only the outermost one
            // defines a segment boundary.
            if spanDepth == 0 {
                spanText = ""
                spanBegin = parseTime(attributes["begin"])
                spanEnd = parseTime(attributes["end"])
            }
            spanDepth += 1
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard inParagraph else { return }
        lineTextBuffer += string
        if spanDepth > 0 {
            spanText += string
        }
    }

    func parser(_ parser: XMLParser,
                didEndElement elementName: String,
                namespaceURI: String?,
                qualifiedName: String?) {
        let name = elementName.lowercased()

        if name == "div" {
            if !divBackgroundStack.isEmpty { divBackgroundStack.removeLast() }
            return
        }

        if name == "span" {
            guard spanDepth > 0 else { return }
            spanDepth -= 1
            if spanDepth == 0 {
                let text = spanText
                currentSpans.append((text, spanBegin, spanEnd))
                spanText = ""
            }
            return
        }

        if name == "p" {
            inParagraph = false
            let segs: [LyricSegment] = currentSpans.compactMap { s in
                guard let b = s.begin, let e = s.end, e >= b else { return nil }
                return LyricSegment(text: s.text, startTime: b, endTime: e)
            }
            // Line-timed documents have no spans, so the text lives directly
            // inside `<p>`; word-timed ones rebuild it from the spans.
            let rawText = lineTextBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
            let lineText = rawText.isEmpty ? currentSpans.map { $0.text }.joined() : rawText
            guard !lineText.isEmpty else {
                currentSpans = []
                return
            }
            let start = currentLineBegin ?? segs.first?.startTime ?? 0
            let end = currentLineEnd ?? segs.last?.endTime ?? (start + 4)
            let line = LyricLine(
                text: lineText,
                segments: segs,
                startTime: start,
                endTime: end,
                background: lineBackground
            )
            result = (result ?? []) + [line]
            currentSpans = []
            lineTextBuffer = ""
        }
    }

    /// Background vocals are marked either on the `<div>` song part or on the
    /// `<p>` itself (`itunes:agent="background"` / `itunes:songPart="Background"`).
    private static func isBackground(_ attributes: [String: String]) -> Bool {
        attributes.contains { $0.value.lowercased().contains("background") }
    }

    // MARK: - Time parsing

    /// Accepts both `1.2s` and clock forms `00:00:01.234` / `01:02.5`.
    private func parseTime(_ value: String?) -> TimeInterval? {
        guard let raw = value?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        let v = raw.hasSuffix("s") ? String(raw.dropLast()) : raw
        if let secs = Double(v) {
            return secs.isFinite && secs >= 0 ? secs : nil
        }
        // clock form: mm:ss.xxx or hh:mm:ss.xxx
        let parts = v.split(separator: ":")
        guard !parts.isEmpty else { return nil }
        var seconds: TimeInterval = 0
        for (i, p) in parts.reversed().enumerated() {
            guard let n = Double(p) else { return nil }
            seconds += n * pow(60.0, Double(i))
        }
        return seconds
    }
}
