import Foundation

/// One word of an auto-generated caption and the moment it's spoken.
struct CaptionWord: Sendable, Equatable {
    let time: TimeInterval
    /// Includes its leading space, so words can be joined back verbatim.
    let text: String
}

struct SubtitleCue: Identifiable, Sendable {
    let id: UUID
    let start: TimeInterval
    let end: TimeInterval
    let text: String
    /// Per-line word timings for YouTube auto-captions; empty for captions
    /// without timings (shown whole).
    let lines: [[CaptionWord]]

    init(start: TimeInterval, end: TimeInterval, text: String, lines: [[CaptionWord]] = []) {
        self.id = UUID()
        self.start = start
        self.end = end
        self.text = text
        self.lines = lines
    }

    var hasWordTimings: Bool { !lines.isEmpty }
}
