import SwiftUI

/// User-chosen caption appearance, stored in UserDefaults (Settings › Captions).
enum CaptionPreference {
    static let behavior = "captionBehavior"
    static let size = "captionSize"
    static let font = "captionFont"
    static let weight = "captionWeight"
    static let color = "captionColor"
    static let background = "captionBackground"
    static let backgroundOpacity = "captionBackgroundOpacity"
    static let position = "captionPosition"
    static let revealWords = "captionRevealWords"
    static let animated = "captionAnimated"
    static let holdThroughPauses = "captionHoldThroughPauses"
}

enum CaptionSize: String, CaseIterable, Identifiable {
    case small, medium, large, extraLarge
    var id: String { rawValue }
    var label: String {
        switch self {
        case .small: "Small"
        case .medium: "Medium"
        case .large: "Large"
        case .extraLarge: "Extra Large"
        }
    }
    /// Point size in a window; fullscreen scales it up.
    var points: CGFloat {
        switch self {
        case .small: 16
        case .medium: 21
        case .large: 26
        case .extraLarge: 32
        }
    }
}

enum CaptionFont: String, CaseIterable, Identifiable {
    case system, rounded, serif, monospaced
    var id: String { rawValue }
    var label: String { rawValue == "system" ? "System" : rawValue.capitalized }
    var design: Font.Design {
        switch self {
        case .system: .default
        case .rounded: .rounded
        case .serif: .serif
        case .monospaced: .monospaced
        }
    }
}

enum CaptionWeight: String, CaseIterable, Identifiable {
    case regular, semibold, bold
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
    var weight: Font.Weight {
        switch self {
        case .regular: .regular
        case .semibold: .semibold
        case .bold: .bold
        }
    }
}

enum CaptionColor: String, CaseIterable, Identifiable {
    case white, yellow, cyan, green
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
    var color: Color {
        switch self {
        case .white: .white
        case .yellow: Color(red: 1, green: 0.9, blue: 0.2)
        case .cyan: Color(red: 0.4, green: 0.9, blue: 1)
        case .green: Color(red: 0.5, green: 1, blue: 0.5)
        }
    }
}

enum CaptionBackground: String, CaseIterable, Identifiable {
    case box, lineBoxes, outline, none
    var id: String { rawValue }
    var label: String {
        switch self {
        case .box: "One box"
        case .lineBoxes: "Box per line"
        case .outline: "Outline"
        case .none: "None"
        }
    }
    var hasBox: Bool { self == .box || self == .lineBoxes }
}

enum CaptionPosition: String, CaseIterable, Identifiable {
    case bottom, top
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

/// Current caption settings, read from UserDefaults.
struct CaptionStyle {
    var behavior: CaptionBehavior = .pairs
    var size: CaptionSize = .medium
    var font: CaptionFont = .system
    var weight: CaptionWeight = .semibold
    var color: CaptionColor = .white
    var background: CaptionBackground = .box
    var backgroundOpacity: Double = 0.72
    var position: CaptionPosition = .bottom
    /// Scrolling, smooth resizing and fading. Off = captions change instantly.
    var animated: Bool = false
}

/// One caption, styled. Used by the player and the Settings preview.
struct CaptionText: View {
    /// One line of a caption. The id is stable while a line stays on screen
    /// (it's the line's first word time + text), so SwiftUI can animate a
    /// rolling line moving from the bottom slot to the top one.
    struct Line: Identifiable {
        let id: String
        let text: AttributedString
    }

    let lines: [Line]
    let style: CaptionStyle
    var scale: CGFloat = 1
    /// Rolling layout is only for auto-captions; hand-made captions can have
    /// any number of lines and always show stacked.
    private var isAutoCaption = false

    init(text: String, style: CaptionStyle, scale: CGFloat = 1) {
        self.lines = text.components(separatedBy: "\n").enumerated().map {
            Line(id: "\($0.offset)|\($0.element)", text: AttributedString($0.element))
        }
        self.style = style
        self.scale = scale
    }

    /// Auto-captions with word timings: words not yet spoken are laid out
    /// but invisible, so they "pop in" as they're said without the caption
    /// box resizing or the text shifting.
    init(cue: SubtitleCue, time: TimeInterval, revealWords: Bool, style: CaptionStyle, scale: CGFloat = 1) {
        self.style = style
        self.scale = scale
        guard cue.hasWordTimings else {
            self.lines = cue.text.components(separatedBy: "\n").enumerated().map {
                Line(id: "\(cue.start)|\($0.offset)|\($0.element)", text: AttributedString($0.element))
            }
            return
        }
        self.isAutoCaption = true
        self.lines = cue.lines.map { words in
            var text = AttributedString()
            for word in words {
                var piece = AttributedString(word.text)
                if revealWords, word.time > time { piece.foregroundColor = .clear }
                text += piece
            }
            let key = words.first.map { String(format: "%.3f", $0.time) } ?? ""
            return Line(id: key + "|" + words.map(\.text).joined(), text: text)
        }
    }

    private var fontSize: CGFloat { style.size.points * scale }
    private var lineHeight: CGFloat { (fontSize * 1.25).rounded(.up) }
    private var animation: Animation? { style.animated ? .easeInOut(duration: 0.3) : nil }

    var body: some View {
        Group {
            if style.behavior == .rolling, isAutoCaption {
                rolling
            } else {
                stacked
            }
        }
        .font(.system(size: fontSize, weight: style.weight.weight, design: style.font.design))
        .foregroundStyle(style.color.color)
        .modifier(OuterStyle(style: style))
        // Smoothly resize/crossfade when the caption changes, instead of
        // the box snapping to a new size.
        .animation(animation, value: lines.map(\.id))
    }

    /// Lines shown together (two at a time, one at a time, hand-made).
    @ViewBuilder
    private var stacked: some View {
        if style.background == .lineBoxes {
            VStack(spacing: 4) {
                ForEach(lines) { line in
                    lineView(line).modifier(LineBox(style: style))
                }
            }
        } else {
            VStack(spacing: 2) {
                ForEach(lines) { line in lineView(line) }
            }
        }
    }

    /// Two-line window: when a new line arrives, the bottom line glides up
    /// and the old top line scrolls out past the top edge.
    private var rolling: some View {
        let perLine = style.background == .lineBoxes
        let rowHeight = perLine ? lineHeight + 8 : lineHeight
        let spacing: CGFloat = perLine ? 4 : 2
        // Clip at the caption box's outer edge so the outgoing line is cut
        // off by the box itself.
        let edge: CGFloat = style.background == .box ? 6 : 0
        return VStack(spacing: spacing) {
            ForEach(lines) { line in
                Group {
                    if perLine {
                        lineView(line).modifier(LineBox(style: style))
                    } else {
                        lineView(line)
                    }
                }
                .frame(height: rowHeight)
                .transition(style.animated
                            ? .asymmetric(insertion: .opacity, removal: .move(edge: .top))
                            : .identity)
            }
        }
        .frame(height: rowHeight * 2 + spacing, alignment: .bottom)
        .padding(.vertical, edge)
        .clipped()
        .padding(.vertical, -edge)
    }

    private func lineView(_ line: Line) -> some View {
        Text(line.text)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .multilineTextAlignment(.center)
    }
}

/// Background for a single caption row ("Box per line").
private struct LineBox: ViewModifier {
    let style: CaptionStyle
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(.black.opacity(style.backgroundOpacity), in: .rect(cornerRadius: 6))
    }
}

/// Box, outline or shadow around the whole caption.
private struct OuterStyle: ViewModifier {
    let style: CaptionStyle
    func body(content: Content) -> some View {
        switch style.background {
        case .box:
            content
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(.black.opacity(style.backgroundOpacity), in: .rect(cornerRadius: 10))
        case .lineBoxes:
            content
        case .outline:
            content
                .padding(.horizontal, 4)
                .shadow(color: .black, radius: 0, x: 1.5, y: 1.5)
                .shadow(color: .black, radius: 0, x: -1.5, y: -1.5)
                .shadow(color: .black, radius: 0, x: 1.5, y: -1.5)
                .shadow(color: .black, radius: 0, x: -1.5, y: 1.5)
                .shadow(color: .black.opacity(0.6), radius: 4)
        case .none:
            content
                .padding(.horizontal, 4)
                .shadow(color: .black.opacity(0.5), radius: 2)
        }
    }
}

/// Settings preview that plays a short looping sample through the real
/// caption pipeline (parser + CaptionText), so behavior, word timing,
/// animation and styling changes show up live.
struct CaptionLivePreview: View {
    let style: CaptionStyle
    let revealWords: Bool
    let holdThroughPauses: Bool

    @State private var start = Date()

    /// Sample auto-caption lines with per-word timings, written in YouTube's
    /// rolling format so every behavior (pairs, lines, rolling) can be shown.
    private static let sample: (vtt: String, length: TimeInterval) = {
        let lines = [
            "this is how your captions will look",
            "while you watch a video in the app",
            "each word can pop in as it is spoken",
            "and new lines arrive as people talk"
        ]
        func stamp(_ t: TimeInterval) -> String {
            let ms = Int((t * 1000).rounded())
            return String(format: "%02d:%02d:%02d.%03d", ms / 3_600_000, (ms / 60_000) % 60, (ms / 1000) % 60, ms % 1000)
        }
        var vtt = "WEBVTT\n\n"
        var t: TimeInterval = 0.4
        var previous: String?
        for (index, line) in lines.enumerated() {
            let words = line.split(separator: " ").map(String.init)
            let lineStart = t
            var timed = words[0]
            for word in words.dropFirst() {
                t += 0.32
                timed += "<\(stamp(t))><c> \(word)</c>"
            }
            t += 0.45
            // A short pause after the second line shows "hold through pauses".
            let lineEnd = t
            if index == 1 { t += 1.0 }
            vtt += "\(stamp(lineStart)) --> \(stamp(lineEnd))\n" + (previous.map { "\($0)\n" } ?? " \n") + timed + "\n\n"
            previous = line
        }
        return (vtt, t + 1.2)
    }()

    private var cues: [SubtitleCue] {
        SubtitleParser.parseVTT(Self.sample.vtt, behavior: style.behavior)
    }

    var body: some View {
        let cues = self.cues
        TimelineView(.animation(minimumInterval: 1.0 / 20)) { context in
            let time = context.date.timeIntervalSince(start).truncatingRemainder(dividingBy: Self.sample.length)
            ZStack(alignment: style.position == .bottom ? .bottom : .top) {
                LinearGradient(
                    colors: [Color(red: 0.25, green: 0.35, blue: 0.5), Color(red: 0.55, green: 0.45, blue: 0.35)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
                Image(systemName: "mountain.2.fill")
                    .font(.system(size: 70))
                    .foregroundStyle(.white.opacity(0.25))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if let cue = cue(at: time, in: cues) {
                    CaptionText(cue: cue, time: time, revealWords: revealWords, style: style, scale: 0.8)
                        .padding(14)
                        .transition(style.animated ? .opacity : .identity)
                }
            }
            .animation(style.animated ? .easeOut(duration: 0.2) : nil, value: cue(at: time, in: cues)?.id)
        }
        .frame(height: 170)
        .clipShape(.rect(cornerRadius: 8))
        .onChange(of: style.behavior) { _, _ in start = Date() }
    }

    private func cue(at time: TimeInterval, in cues: [SubtitleCue]) -> SubtitleCue? {
        if let cue = cues.first(where: { $0.start <= time && $0.end > time }) { return cue }
        if holdThroughPauses, let last = cues.last(where: { $0.start <= time }), time - last.end < 1.5 {
            return last
        }
        return nil
    }
}
