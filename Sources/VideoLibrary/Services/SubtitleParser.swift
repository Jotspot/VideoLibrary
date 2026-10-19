import Foundation

/// How YouTube's auto-generated ("rolling") captions are shown. Hand-made
/// captions are always shown exactly as authored.
enum CaptionBehavior: String, CaseIterable, Identifiable, Sendable {
    /// Two lines appear together, then flip to the next two.
    case pairs
    /// One line at a time.
    case lines
    /// YouTube's style: the previous line moves up as a new one appears.
    case rolling

    var id: String { rawValue }

    var label: String {
        switch self {
        case .pairs: "Two lines at a time"
        case .lines: "One line at a time"
        case .rolling: "Rolling (like YouTube)"
        }
    }
}

struct SubtitleParser {
    static func parse(fileURL: URL, behavior: CaptionBehavior = .pairs) throws -> [SubtitleCue] {
        let content = try String(contentsOf: fileURL, encoding: .utf8)
        switch fileURL.pathExtension.lowercased() {
        case "vtt": return parseVTT(content, behavior: behavior)
        default: return parseSRT(content)
        }
    }

    static func parseVTT(_ content: String, behavior: CaptionBehavior = .pairs) -> [SubtitleCue] {
        // YouTube auto-captions carry per-word timestamps like <00:00:01.040>.
        if content.range(of: #"<\d{2}:\d{2}:\d{2}\.\d{3}>"#, options: .regularExpression) != nil {
            return parseRollingVTT(content, behavior: behavior)
        }
        return parsePlainVTT(content)
    }

    /// YouTube's auto-generated captions "roll": every cue repeats the
    /// previous line on top and types the new line underneath (with a
    /// timestamp per word), with 10 ms snapshot cues in between. This extracts
    /// each cue's new line and its word timings, then presents the lines
    /// according to `behavior`.
    static func parseRollingVTT(_ content: String, behavior: CaptionBehavior = .pairs) -> [SubtitleCue] {
        let blocks = parseRawVTT(content).filter { $0.end - $0.start > 0.05 }

        if behavior == .rolling {
            // A line carried up from the previous cue reuses that cue's word
            // timings, so it keeps the same identity and can animate upward.
            var spoken: [String: [CaptionWord]] = [:]
            return blocks.compactMap { block in
                let rawLines = block.lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                guard !rawLines.isEmpty else { return nil }
                let lines = rawLines.enumerated().map { index, raw -> [CaptionWord] in
                    let fresh = words(in: raw, startingAt: block.start)
                    if index < rawLines.count - 1, let earlier = spoken[joined(fresh)] { return earlier }
                    return fresh
                }
                if let newest = lines.last { spoken[joined(newest)] = newest }
                let text = lines.map(joined).joined(separator: "\n")
                return SubtitleCue(start: block.start, end: block.end, text: text, lines: lines)
            }
        }

        struct Line { var start: TimeInterval; var end: TimeInterval; var words: [CaptionWord]; var text: String }
        var lines: [Line] = []
        for block in blocks {
            guard let raw = block.lines.last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else { continue }
            let words = words(in: raw, startingAt: block.start)
            let text = joined(words)
            if let previous = lines.last, previous.text == text {
                // Same line continued into the next cue; extend it.
                lines[lines.count - 1].end = block.end
            } else {
                lines.append(Line(start: block.start, end: block.end, words: words, text: text))
            }
        }

        if behavior == .lines {
            return lines.map { SubtitleCue(start: $0.start, end: $0.end, text: $0.text, lines: [$0.words]) }
        }

        // Pairs: both lines share one caption for the pair's whole span, then
        // flip to the next pair. Don't pair across a pause.
        var cues: [SubtitleCue] = []
        var index = 0
        while index < lines.count {
            let first = lines[index]
            if index + 1 < lines.count, lines[index + 1].start - first.end < 1.5 {
                let second = lines[index + 1]
                cues.append(SubtitleCue(
                    start: first.start, end: second.end,
                    text: first.text + "\n" + second.text,
                    lines: [first.words, second.words]
                ))
                index += 2
            } else {
                cues.append(SubtitleCue(start: first.start, end: first.end, text: first.text, lines: [first.words]))
                index += 1
            }
        }
        return cues
    }

    /// Splits "this<00:00:00.760><c> is</c><00:00:00.880><c> a</c>" into
    /// timed words. Text before the first timestamp is spoken at the cue's
    /// start; a line with no timestamps is one already-spoken chunk.
    static func words(in rawLine: String, startingAt start: TimeInterval) -> [CaptionWord] {
        let pattern = #"<(\d{2}:\d{2}:\d{2}\.\d{3})>"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return [CaptionWord(time: start, text: stripHTML(rawLine).trimmingCharacters(in: .whitespaces))]
        }
        let ns = rawLine as NSString
        var words: [CaptionWord] = []
        var cursor = 0
        var time = start
        for match in regex.matches(in: rawLine, range: NSRange(location: 0, length: ns.length)) {
            let segment = stripHTML(ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor)))
            if !segment.trimmingCharacters(in: .whitespaces).isEmpty {
                words.append(CaptionWord(time: time, text: segment))
            }
            time = parseTimestamp(ns.substring(with: match.range(at: 1))) ?? time
            cursor = match.range.location + match.range.length
        }
        let tail = stripHTML(ns.substring(from: cursor))
        if !tail.trimmingCharacters(in: .whitespaces).isEmpty {
            words.append(CaptionWord(time: time, text: tail))
        }
        // Normalise: no leading space on the first word, single spaces between.
        return words.enumerated().map { index, word in
            let trimmed = word.text.trimmingCharacters(in: .whitespaces)
            return CaptionWord(time: word.time, text: index == 0 ? trimmed : " " + trimmed)
        }
    }

    private static func joined(_ words: [CaptionWord]) -> String {
        words.map(\.text).joined()
    }

    private static func parsePlainVTT(_ content: String) -> [SubtitleCue] {
        parseRawVTT(content).compactMap { block in
            let text = stripHTML(
                block.lines
                    .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                    .joined(separator: "\n")
            )
            return text.isEmpty ? nil : SubtitleCue(start: block.start, end: block.end, text: text)
        }
    }

    private struct RawBlock {
        let start: TimeInterval
        let end: TimeInterval
        let lines: [String]
    }

    /// Cue blocks with their text lines untouched (tags and all).
    private static func parseRawVTT(_ content: String) -> [RawBlock] {
        var cues: [RawBlock] = []
        let lines = content.components(separatedBy: "\n")
        var i = 0

        // Skip WEBVTT header line
        while i < lines.count && !lines[i].contains("-->") {
            if lines[i].hasPrefix("WEBVTT") || lines[i].hasPrefix("NOTE") ||
               lines[i].hasPrefix("STYLE") || lines[i].hasPrefix("REGION") {
                while i < lines.count && !lines[i].isEmpty { i += 1 }
            }
            i += 1
        }

        while i < lines.count {
            let line = lines[i]
            guard line.contains("-->") else { i += 1; continue }

            let timeParts = line.components(separatedBy: " --> ")
            guard timeParts.count >= 2,
                  let start = parseTimestamp(timeParts[0].trimmingCharacters(in: .whitespaces)),
                  let end = parseTimestamp(timeParts[1].components(separatedBy: " ").first ?? "") else {
                i += 1; continue
            }

            i += 1
            // Text runs until the next timing line rather than the first blank
            // line: YouTube auto-captions start cues with a whitespace-only
            // line, which tools that strip trailing spaces turn into a blank.
            var textLines: [String] = []
            while i < lines.count && !lines[i].contains("-->") {
                textLines.append(lines[i].trimmingCharacters(in: .init(charactersIn: "\r")))
                i += 1
            }
            // A line right before the next timing line, after a blank, is
            // that cue's identifier, not text.
            if i < lines.count, textLines.count >= 2,
               textLines[textLines.count - 2].trimmingCharacters(in: .whitespaces).isEmpty {
                textLines.removeLast()
            }

            cues.append(RawBlock(start: start, end: end, lines: textLines))
        }

        return cues
    }

    static func parseSRT(_ content: String) -> [SubtitleCue] {
        var cues: [SubtitleCue] = []
        let blocks = content.components(separatedBy: "\n\n")

        for block in blocks {
            let lines = block.components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .init(charactersIn: "\r")) }
                .filter { !$0.isEmpty }

            guard lines.count >= 2 else { continue }

            // Find the timestamp line (may skip index line)
            var tsLineIdx = 0
            if !lines[0].contains("-->") { tsLineIdx = 1 }
            guard tsLineIdx < lines.count, lines[tsLineIdx].contains("-->") else { continue }

            let timeParts = lines[tsLineIdx].components(separatedBy: " --> ")
            guard timeParts.count >= 2,
                  let start = parseTimestamp(timeParts[0].trimmingCharacters(in: .whitespaces)),
                  let end = parseTimestamp(timeParts[1].trimmingCharacters(in: .whitespaces)) else { continue }

            let textLines = Array(lines[(tsLineIdx + 1)...])
            let text = stripHTML(textLines.joined(separator: "\n"))
            if !text.trimmingCharacters(in: .whitespaces).isEmpty {
                cues.append(SubtitleCue(start: start, end: end, text: text))
            }
        }

        return cues.sorted { $0.start < $1.start }
    }

    private static func parseTimestamp(_ s: String) -> TimeInterval? {
        // Normalize: SRT uses comma, VTT uses dot for decimal
        let normalized = s.replacingOccurrences(of: ",", with: ".")
        let parts = normalized.split(separator: ":").map(String.init)
        switch parts.count {
        case 3:
            guard let h = Double(parts[0]),
                  let m = Double(parts[1]),
                  let sec = Double(parts[2]) else { return nil }
            return h * 3600 + m * 60 + sec
        case 2:
            guard let m = Double(parts[0]),
                  let sec = Double(parts[1]) else { return nil }
            return m * 60 + sec
        default:
            return nil
        }
    }

    private static func stripHTML(_ s: String) -> String {
        s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
         .replacingOccurrences(of: "&amp;", with: "&")
         .replacingOccurrences(of: "&lt;", with: "<")
         .replacingOccurrences(of: "&gt;", with: ">")
         .replacingOccurrences(of: "&nbsp;", with: " ")
         .replacingOccurrences(of: "&#39;", with: "'")
         .replacingOccurrences(of: "&quot;", with: "\"")
    }
}
