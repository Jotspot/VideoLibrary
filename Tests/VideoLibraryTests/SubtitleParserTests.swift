import Testing
@testable import VideoLibrary

@Suite("SubtitleParser")
struct SubtitleParserTests {

    @Test("parses SRT with two cues")
    func parseSRT() {
        let srt = """
        1
        00:00:01,000 --> 00:00:03,500
        Hello world

        2
        00:00:05,000 --> 00:00:07,000
        Second line
        """

        let cues = SubtitleParser.parseSRT(srt)
        #expect(cues.count == 2)
        #expect(cues[0].start == 1.0)
        #expect(cues[0].end == 3.5)
        #expect(cues[0].text == "Hello world")
        #expect(cues[1].start == 5.0)
        #expect(cues[1].text == "Second line")
    }

    @Test("parses VTT with HTML stripping")
    func parseVTT() {
        let vtt = """
        WEBVTT

        00:00:01.000 --> 00:00:03.500
        <i>Italic text</i> and &amp; entity

        00:00:05.000 --> 00:00:07.000
        Plain text
        """

        let cues = SubtitleParser.parseVTT(vtt)
        #expect(cues.count == 2)
        #expect(cues[0].text == "Italic text and & entity")
        #expect(cues[1].text == "Plain text")
    }

    @Test("handles SRT with no index line")
    func parseSRTNoIndex() {
        let srt = """
        00:00:01,000 --> 00:00:02,000
        Hello

        00:00:03,000 --> 00:00:04,000
        World
        """
        let cues = SubtitleParser.parseSRT(srt)
        #expect(cues.count == 2)
    }

    @Test("shows YouTube rolling auto-captions two lines at a time")
    func parseRollingAutoCaptions() {
        let vtt = """
        WEBVTT

        00:00:00.640 --> 00:00:03.030 align:start position:0%

        this<00:00:00.760><c> is</c><00:00:00.880><c> first</c>

        00:00:03.030 --> 00:00:03.040 align:start position:0%
        this is first


        00:00:03.040 --> 00:00:04.470 align:start position:0%
        this is first
        then<00:00:03.159><c> second</c>

        00:00:04.470 --> 00:00:04.480 align:start position:0%
        then second


        00:00:04.480 --> 00:00:07.509 align:start position:0%
        then second
        and<00:00:04.920><c> third</c>
        """
        #expect(SubtitleParser.parseVTT(vtt, behavior: .pairs).map(\.text) == [
            "this is first\nthen second",
            "and third"
        ])
        #expect(SubtitleParser.parseVTT(vtt, behavior: .lines).map(\.text) == [
            "this is first",
            "then second",
            "and third"
        ])
        let rolling = SubtitleParser.parseVTT(vtt, behavior: .rolling)
        #expect(rolling.count == 3)
        // "then second" is new in cue 2 and carried up in cue 3 with the
        // same timings, so it can animate rather than redraw.
        #expect(rolling[1].lines.last == rolling[2].lines.first)
    }

    @Test("keeps per-word timings from auto-captions")
    func parseWordTimings() {
        let words = SubtitleParser.words(
            in: "this<00:00:00.760><c> is</c><00:00:00.880><c> a</c>",
            startingAt: 0.64
        )
        #expect(words.map(\.text) == ["this", " is", " a"])
        #expect(words.map(\.time) == [0.64, 0.76, 0.88])
        #expect(SubtitleParser.words(in: "already said line", startingAt: 2).count == 1)
    }

    @Test("returns empty for empty input")
    func parseEmpty() {
        #expect(SubtitleParser.parseSRT("").isEmpty)
        #expect(SubtitleParser.parseVTT("WEBVTT\n").isEmpty)
    }
}
