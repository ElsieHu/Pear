import Testing
@testable import LyricEngine

@Suite("LRC 解析")
struct LRCParserTests {

    @Test("基本 LRC：多行、多时间戳")
    func basicLRC() {
        let lrc = """
        [ti:Demo]
        [ar:Tester]
        [00:12.00]First line
        [00:15.00]Second line
        [00:18.00][00:40.00]Repeated line
        """
        let lyrics = LRCParser.parse(lrc)
        #expect(lyrics.lines.count == 4)
        #expect(lyrics.lines[0].text == "First line")
        #expect(lyrics.lines[0].startTime == 12.0)
        #expect(lyrics.lines[1].startTime == 15.0)

        let repeated = lyrics.lines.filter { $0.text == "Repeated line" }
        #expect(repeated.count == 2)
        #expect(repeated.map { $0.startTime }.sorted() == [18.0, 40.0])
    }

    @Test("增强型 LRC：逐字时间")
    func enhancedWordTiming() {
        let lrc = """
        [00:18.00]<00:18.00>Hello <00:18.50>world <00:19.00>again
        """
        let lyrics = LRCParser.parse(lrc)
        #expect(lyrics.lines.count == 1)
        let line = lyrics.lines[0]
        #expect(line.text == "Hello world again")
        #expect(line.segments.count == 3)
        #expect(line.segments[0].text == "Hello")
        #expect(line.segments[0].startTime == 18.0)
        #expect(line.segments[1].text == "world")
        #expect(line.segments[1].startTime == 18.5)
        #expect(line.segments[2].text == "again")
        #expect(line.segments[2].startTime == 19.0)
    }

    @Test("元数据标签被忽略")
    func metadataTagsIgnored() {
        let lrc = """
        [ti:Song][ar:Someone]
        [00:01.00]Only line
        """
        let lyrics = LRCParser.parse(lrc)
        #expect(lyrics.lines.count == 1)
        #expect(lyrics.lines[0].text == "Only line")
    }
}
