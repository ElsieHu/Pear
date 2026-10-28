import XCTest
@testable import LyricEngine

final class LRCParserTests: XCTestCase {

    func testBasicLRC() {
        let lrc = """
        [ti:Demo]
        [ar:Tester]
        [00:12.00]First line
        [00:15.00]Second line
        [00:18.00][00:40.00]Repeated line
        """
        let lyrics = LRCParser.parse(lrc)
        XCTAssertEqual(lyrics.lines.count, 4)
        XCTAssertEqual(lyrics.lines[0].text, "First line")
        XCTAssertEqual(lyrics.lines[0].startTime, 12.0)
        XCTAssertEqual(lyrics.lines[1].startTime, 15.0)

        let repeated = lyrics.lines.filter { $0.text == "Repeated line" }
        XCTAssertEqual(repeated.count, 2)
        XCTAssertEqual(repeated.map { $0.startTime }.sorted(), [18.0, 40.0])
    }

    func testEnhancedWordTiming() {
        let lrc = """
        [00:18.00]<00:18.00>Hello <00:18.50>world <00:19.00>again
        """
        let lyrics = LRCParser.parse(lrc)
        XCTAssertEqual(lyrics.lines.count, 1)
        let line = lyrics.lines[0]
        XCTAssertEqual(line.text, "Hello world again")
        XCTAssertEqual(line.segments.count, 3)
        XCTAssertEqual(line.segments[0].text, "Hello")
        XCTAssertEqual(line.segments[0].startTime, 18.0)
        XCTAssertEqual(line.segments[1].text, "world")
        XCTAssertEqual(line.segments[1].startTime, 18.5)
        XCTAssertEqual(line.segments[2].text, "again")
        XCTAssertEqual(line.segments[2].startTime, 19.0)
    }

    func testMetadataTagsIgnored() {
        let lrc = """
        [ti:Song][ar:Someone]
        [00:01.00]Only line
        """
        let lyrics = LRCParser.parse(lrc)
        XCTAssertEqual(lyrics.lines.count, 1)
        XCTAssertEqual(lyrics.lines[0].text, "Only line")
    }
}
