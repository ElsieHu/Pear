import XCTest
@testable import LyricEngine

final class TTMLParserTests: XCTestCase {

    private let sampleTTML = """
    <?xml version="1.0" encoding="UTF-8"?>
    <tt xmlns="http://www.w3.org/ns/ttml">
      <body>
        <div>
          <p begin="0.0s" end="4.2s">
            <span begin="0.0s" end="1.2s">Hello </span>
            <span begin="1.2s" end="2.5s">world</span>
          </p>
          <p begin="4.2s" end="8.0s">
            <span begin="4.2s" end="5.0s">This </span>
            <span begin="5.0s" end="6.0s">is </span>
            <span begin="6.0s" end="8.0s">a test</span>
          </p>
        </div>
      </body>
    </tt>
    """

    func testParsesLinesAndWordTiming() throws {
        let lyrics = try TTMLParser.parse(sampleTTML, source: "Apple Music", songID: "123")
        XCTAssertEqual(lyrics.lines.count, 2)
        XCTAssertEqual(lyrics.source, "Apple Music")
        XCTAssertEqual(lyrics.songID, "123")

        let first = lyrics.lines[0]
        XCTAssertEqual(first.text, "Hello world")
        XCTAssertEqual(first.segments.count, 2)
        XCTAssertEqual(first.startTime, 0.0)
        XCTAssertEqual(first.endTime, 4.2)

        let seg0 = first.segments[0]
        XCTAssertEqual(seg0.text, "Hello ")
        XCTAssertEqual(seg0.startTime, 0.0)
        XCTAssertEqual(seg0.endTime, 1.2)

        let second = lyrics.lines[1]
        XCTAssertEqual(second.text, "This is a test")
        XCTAssertEqual(second.segments.count, 3)
        XCTAssertEqual(second.startTime, 4.2)
        XCTAssertEqual(second.endTime, 8.0)
    }

    func testActiveLineIndexAndProgress() throws {
        let lyrics = try TTMLParser.parse(sampleTTML)
        XCTAssertEqual(lyrics.activeLineIndex(at: 1.0), 0)
        XCTAssertEqual(lyrics.activeLineIndex(at: 5.0), 1)
        XCTAssertEqual(lyrics.activeLineIndex(at: 100), 1)

        let p = lyrics.lineProgress(lyrics.lines[0], at: 2.1)
        // (2.1 - 0) / (4.2 - 0) = 0.5
        XCTAssertEqual(p, 0.5, accuracy: 0.001)

        let sp = lyrics.segmentProgress(lyrics.lines[0].segments[1], at: 1.85)
        // (1.85 - 1.2) / (2.5 - 1.2) = 0.5
        XCTAssertEqual(sp, 0.5, accuracy: 0.001)
    }

    func testClockFormTimestamps() throws {
        let clockTTML = """
        <tt><body><div>
          <p begin="00:00:01.000" end="00:00:03.500">
            <span begin="00:00:01.000" end="00:00:02.250">tick</span>
            <span begin="00:00:02.250" end="00:00:03.500">tock</span>
          </p>
        </div></body></tt>
        """
        let lyrics = try TTMLParser.parse(clockTTML)
        XCTAssertEqual(lyrics.lines.count, 1)
        XCTAssertEqual(lyrics.lines[0].startTime, 1.0)
        XCTAssertEqual(lyrics.lines[0].segments[0].endTime, 2.25)
        XCTAssertEqual(lyrics.lines[0].segments[1].startTime, 2.25)
    }

    func testEmptyDocumentThrows() {
        XCTAssertThrowsError(try TTMLParser.parse(""))
        XCTAssertThrowsError(try TTMLParser.parse("<tt></tt>"))
    }
}
