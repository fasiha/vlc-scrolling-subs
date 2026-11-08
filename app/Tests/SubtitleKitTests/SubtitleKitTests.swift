import XCTest
@testable import SubtitleKit

final class SubtitleKitTests: XCTestCase {
    func testYouTubeVTTDedupes() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "youtube-auto.en", withExtension: "vtt", subdirectory: "Fixtures"))
        let cues = try SubtitleParser.parse(url: url)
        XCTAssertEqual(cues[0].text, "[music]")
        let first = try XCTUnwrap(cues.first { $0.text.hasPrefix("The old") })
        XCTAssertEqual(first.text, "The old lighthouse keeper counted the ships nightly")
        XCTAssertEqual(first.start, 16.24, accuracy: 0.001)
        XCTAssertEqual(first.words.map(\.text), ["The", "old", "lighthouse", "keeper", "counted", "the", "ships", "nightly"])
        XCTAssertEqual(first.words[1].start, 16.88, accuracy: 0.001)
        XCTAssertEqual(first.words[0].end, 16.88, accuracy: 0.001)
        let next = cues[cues.firstIndex(of: first)! + 1]
        XCTAssertEqual(next.text, "and wrote each name. The sea was calm.")
        // Genuinely repeated speech is kept (re-timed), not deduped away.
        XCTAssertEqual(cues.filter { $0.text.hasSuffix("You are mine.") }.count, 2)
        for (a, b) in zip(cues, cues.dropFirst()) {
            XCTAssert(a.text != b.text || !b.words.isEmpty, b.text)
            XCTAssertLessThanOrEqual(a.start, b.start)
        }
        XCTAssertFalse(cues.contains { $0.text.contains("<") || $0.text.isEmpty })
        for c in cues where !c.words.isEmpty {
            XCTAssertEqual(c.words.map(\.text).joined(separator: " "), c.text)
        }
    }

    /// Optional: set OPERASUBS_TEST_VTT=/path/to/real.en.vtt to sanity-check a real YouTube auto-VTT.
    func testRealVTTFromEnv() throws {
        guard let path = ProcessInfo.processInfo.environment["OPERASUBS_TEST_VTT"] else {
            throw XCTSkip("OPERASUBS_TEST_VTT not set")
        }
        let cues = try SubtitleParser.parse(url: URL(fileURLWithPath: path))
        XCTAssertFalse(cues.isEmpty)
        for (a, b) in zip(cues, cues.dropFirst()) { XCTAssertLessThanOrEqual(a.start, b.start) }
        XCTAssertFalse(cues.contains { $0.text.contains("<") || $0.text.isEmpty })
        for c in cues where !c.words.isEmpty {
            XCTAssertEqual(c.words.map(\.text).joined(separator: " "), c.text)
        }
    }

    func testPlainVTT() throws {
        let s = """
        WEBVTT

        NOTE hello

        1
        00:01.000 --> 00:02.500 line:90%
        <v Bob>Hello &amp; welcome</v>

        00:00:03.000 --> 00:00:04.000
        Two
        lines
        """
        let cues = WebVTTParser.parse(s)
        XCTAssertEqual(cues.count, 2)
        XCTAssertEqual(cues[0].text, "Hello & welcome")
        XCTAssertEqual(cues[0].start, 1.0)
        XCTAssertEqual(cues[0].end, 2.5)
        XCTAssertEqual(cues[1].text, "Two\nlines")
    }

    func testSRT() throws {
        let s = "1\r\n00:00:01,000 --> 00:00:02,000\r\n<i>Hi</i>\r\n\r\n2\r\n01:00:00,500 --> 01:00:01,000\r\nBye\r\n"
        let cues = try SubtitleParser.parse(data: Data(s.utf8))
        XCTAssertEqual(cues.map(\.text), ["Hi", "Bye"])
        XCTAssertEqual(cues[1].start, 3600.5)
    }

    func testWordJSON() throws {
        let s = #"{"version":1,"lines":[{"start":1.23,"end":4.56,"text":"I love you","words":[{"start":1.23,"end":1.5,"text":"I"},{"start":1.5,"end":2,"text":"love"},{"start":2,"end":4.56,"text":"you"}]},{"start":5,"end":6,"text":"untimed"}]}"#
        let cues = try SubtitleParser.parse(data: Data(s.utf8))
        XCTAssertEqual(cues.count, 2)
        XCTAssertEqual(cues[0].words.count, 3)
        XCTAssertEqual(cues[1].words, [])
    }

    func testLookup() {
        let cues = [SubtitleCue(id: 0, start: 1, end: 2, text: "a"), SubtitleCue(id: 1, start: 3, end: 4, text: "b")]
        XCTAssertNil(cues.lastStarted(at: 0.5))
        XCTAssertEqual(cues.lastStarted(at: 1), 0)
        XCTAssertEqual(cues.lastStarted(at: 2.5), 0)
        XCTAssertEqual(cues.lastStarted(at: 10), 1)
    }
}
