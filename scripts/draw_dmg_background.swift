// Draws the DMG window background (assets/dmg/background.png and @2x).
// Run: swift scripts/draw_dmg_background.swift
// Layout matches scripts/dmg-settings.py: 660×400 window, 128 pt icons
// centred at (170, 190) and (490, 190).
import AppKit

let size = CGSize(width: 660, height: 400)
let appCenter = CGPoint(x: 170, y: 190)
let applicationsCenter = CGPoint(x: 490, y: 190)

func draw(scale: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = size
    NSGraphicsContext.saveGraphicsState()
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = context
    let cg = context.cgContext
    // Flip so y runs top-down like Finder's icon positions.
    cg.translateBy(x: 0, y: size.height)
    cg.scaleBy(x: 1, y: -1)

    // Background: soft light gradient (Finder draws icon labels in dark
    // text on light window backgrounds).
    let gradient = NSGradient(colors: [NSColor(white: 0.985, alpha: 1), NSColor(white: 0.935, alpha: 1)])!
    gradient.draw(in: CGRect(origin: .zero, size: size), angle: 90)

    /// Draws centered text from `y` down, or centered both ways in `box`.
    func text(_ string: String, size fontSize: CGFloat, weight: NSFont.Weight, color: NSColor,
              y: CGFloat = 0, in box: CGRect? = nil) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineSpacing = box == nil ? 0 : 3
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize, weight: weight),
            .foregroundColor: color,
            .paragraphStyle: paragraph
        ]
        let attributed = NSAttributedString(string: string, attributes: attributes)
        let frame = box.map { $0.insetBy(dx: 20, dy: 0) } ?? CGRect(x: 40, y: y, width: size.width - 80, height: 0)
        let bounds = attributed.boundingRect(with: CGSize(width: frame.width, height: 200), options: [.usesLineFragmentOrigin])
        let height = ceil(bounds.height)
        NSGraphicsContext.saveGraphicsState()
        // Text draws unflipped; undo the flip around the text box.
        let rect = CGRect(x: frame.minX, y: box.map { $0.midY - height / 2 } ?? y, width: frame.width, height: height)
        cg.saveGState()
        cg.translateBy(x: 0, y: rect.midY)
        cg.scaleBy(x: 1, y: -1)
        cg.translateBy(x: 0, y: -rect.midY)
        attributed.draw(with: rect, options: [.usesLineFragmentOrigin])
        cg.restoreGState()
        NSGraphicsContext.restoreGraphicsState()
    }

    text("Drag VideoLibrary into Applications", size: 20, weight: .semibold,
         color: NSColor(white: 0.1, alpha: 1), y: 44)
    text("Then open it from Applications or Launchpad.", size: 13, weight: .regular,
         color: NSColor(white: 0.42, alpha: 1), y: 74)

    // Arrow between the two icons, in the app's accent blue.
    let accent = NSColor(srgbRed: 0.29, green: 0.42, blue: 0.97, alpha: 1)
    let startX = appCenter.x + 82, endX = applicationsCenter.x - 82, y = appCenter.y
    cg.setStrokeColor(accent.cgColor)
    cg.setLineWidth(4)
    cg.setLineCap(.round)
    cg.setLineDash(phase: 0, lengths: [1, 11])
    cg.move(to: CGPoint(x: startX, y: y))
    cg.addLine(to: CGPoint(x: endX - 16, y: y))
    cg.strokePath()
    cg.setLineDash(phase: 0, lengths: [])
    cg.setFillColor(accent.cgColor)
    cg.move(to: CGPoint(x: endX, y: y))
    cg.addLine(to: CGPoint(x: endX - 18, y: y - 11))
    cg.addLine(to: CGPoint(x: endX - 18, y: y + 11))
    cg.closePath()
    cg.fillPath()

    // First-launch hint along the bottom.
    // Kept clear of the bottom 40 pt, which Finder covers when someone has
    // the path or status bar turned on.
    let hint = CGRect(x: 32, y: 292, width: size.width - 64, height: 62)
    cg.setFillColor(NSColor(white: 0, alpha: 0.045).cgColor)
    cg.addPath(CGPath(roundedRect: hint, cornerWidth: 10, cornerHeight: 10, transform: nil))
    cg.fillPath()
    text("First time? If macOS says it can't verify the app, open System Settings ›\nPrivacy & Security and click Open Anyway. Full guide: video.mistr.uk/thanks",
         size: 11.5, weight: .regular, color: NSColor(white: 0.38, alpha: 1), in: hint)

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let directory = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "assets/dmg")
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
for (scale, name) in [(1.0, "background.png"), (2.0, "background@2x.png")] {
    let data = draw(scale: scale).representation(using: .png, properties: [:])!
    try data.write(to: directory.appendingPathComponent(name))
    print(directory.appendingPathComponent(name).path)
}
