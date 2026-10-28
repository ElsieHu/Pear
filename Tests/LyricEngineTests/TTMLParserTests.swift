import Testing
@testable import LyricEngine

@Suite("TTML 解析")
struct TTMLParserTests {

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

    @Test("行与逐字时间")
    func parsesLinesAndWordTiming() throws {
        let lyrics = try TTMLParser.parse(sampleTTML, source: "Apple Music", songID: "123")
        #expect(lyrics.lines.count == 2)
        #expect(lyrics.source == "Apple Music")
        #expect(lyrics.songID == "123")

        let first = lyrics.lines[0]
        #expect(first.text == "Hello world")
        #expect(first.segments.count == 2)
        #expect(first.startTime == 0.0)
        #expect(first.endTime == 4.2)

        let seg0 = first.segments[0]
        #expect(seg0.text == "Hello ")
        #expect(seg0.startTime == 0.0)
        #expect(seg0.endTime == 1.2)

        let second = lyrics.lines[1]
        #expect(second.text == "This is a test")
        #expect(second.segments.count == 3)
        #expect(second.startTime == 4.2)
        #expect(second.endTime == 8.0)
    }

    @Test("当前行索引与进度")
    func activeLineIndexAndProgress() throws {
        let lyrics = try TTMLParser.parse(sampleTTML)
        #expect(lyrics.activeLineIndex(at: 1.0) == 0)
        #expect(lyrics.activeLineIndex(at: 5.0) == 1)
        #expect(lyrics.activeLineIndex(at: 100) == 1)

        let p = lyrics.lineProgress(lyrics.lines[0], at: 2.1)
        // (2.1 - 0) / (4.2 - 0) = 0.5
        #expect(abs(p - 0.5) < 0.001)

        let sp = lyrics.segmentProgress(lyrics.lines[0].segments[1], at: 1.85)
        // (1.85 - 1.2) / (2.5 - 1.2) = 0.5
        #expect(abs(sp - 0.5) < 0.001)
    }

    @Test("时钟格式时间戳")
    func clockFormTimestamps() throws {
        let clockTTML = """
        <tt><body><div>
          <p begin="00:00:01.000" end="00:00:03.500">
            <span begin="00:00:01.000" end="00:00:02.250">tick</span>
            <span begin="00:00:02.250" end="00:00:03.500">tock</span>
          </p>
        </div></body></tt>
        """
        let lyrics = try TTMLParser.parse(clockTTML)
        #expect(lyrics.lines.count == 1)
        #expect(lyrics.lines[0].startTime == 1.0)
        #expect(lyrics.lines[0].segments[0].endTime == 2.25)
        #expect(lyrics.lines[0].segments[1].startTime == 2.25)
    }

    @Test("空文档抛错")
    func emptyDocumentThrows() {
        #expect(throws: (any Error).self) { try TTMLParser.parse("") }
        #expect(throws: (any Error).self) { try TTMLParser.parse("<tt></tt>") }
    }
}
