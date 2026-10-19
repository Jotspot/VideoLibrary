import SwiftUI

struct VideoCardView: View {
    let item: VideoItem
    let isSelected: Bool
    var resolution: String? = nil

    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 16:9 slot; the image fills it. (No GeometryReader per card.)
            Color.clear
                .aspectRatio(16 / 9, contentMode: .fit)
                .overlay { thumbnailView }
                .clipped()
                .overlay {
                    // Glass is only drawn while hovered; an invisible glass
                    // view still costs a blur pass on every frame.
                    if isHovered {
                        Image(systemName: "play.fill")
                            .font(.title)
                            .foregroundStyle(.white)
                            .padding(18)
                            .glassEffect(.regular, in: .circle)
                            .transition(.opacity.combined(with: .scale(scale: 0.85)))
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    HStack(spacing: 4) {
                        if let resolution {
                            badge(resolution, emphasized: resolution == "4K" || resolution == "1440p")
                        }
                        badge(item.formattedDuration(), emphasized: false)
                    }
                    .padding(8)
                }

            infoBar
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .glassEffect(.regular, in: .rect(cornerRadius: 0))
        }
        .clipShape(.rect(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(isSelected ? Color.accentColor : Color.clear, lineWidth: 3)
        }
        // Shadow from a plain shape: far cheaper than shadowing the whole
        // card's contents (which renders it offscreen every frame).
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(nsColor: .controlBackgroundColor))
                .shadow(color: .black.opacity(isHovered ? 0.25 : 0.12),
                        radius: isHovered ? 10 : 6, y: isHovered ? 5 : 3)
        )
        .padding(3)
        .frame(maxWidth: .infinity)
        .animation(.spring(.snappy), value: isSelected)
        .animation(.easeOut(duration: 0.15), value: isHovered)
        .onHover { isHovered = $0 }
    }

    /// "Uploaded Oct 3, 2026 · 143.6 MB"
    private var detailLine: String {
        var parts: [String] = []
        if let uploaded = item.uploadDate {
            parts.append("Uploaded " + uploaded.formatted(date: .abbreviated, time: .omitted))
        }
        if let size = item.formattedVideoFileSize { parts.append(size) }
        return parts.joined(separator: " · ")
    }

    private func badge(_ text: String, emphasized: Bool) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold).monospacedDigit())
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(emphasized ? Color.accentColor.opacity(0.9) : Color.black.opacity(0.75), in: .rect(cornerRadius: 5))
    }

    @ViewBuilder
    private var thumbnailView: some View {
        // Downscaled and cached (ArtworkCache), instead of decoding the full
        // 1280×720 file again every time the card scrolls into view.
        ArtworkView(url: item.thumbnailURL, cornerRadius: 0, placeholderSymbol: "film", maxPixelSize: 640)
    }

    private var placeholderThumbnail: some View {
        Rectangle()
            .fill(.quaternary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay {
                Image(systemName: "film")
                    .font(.largeTitle)
                    .foregroundStyle(.tertiary)
            }
    }

    private var infoBar: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(item.title)
                .font(.subheadline.weight(.semibold))
                // Two lines always, so cards in a row are the same height.
                .lineLimit(2, reservesSpace: true)
                .foregroundStyle(.primary)

            Text(item.uploader)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Text(detailLine)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)

            // Space kept even when unwatched, for the same reason.
            ProgressView(value: item.watchProgressFraction)
                .progressViewStyle(.linear)
                .tint(Color.accentColor)
                .opacity(item.watchProgressFraction > 0 && item.watchProgressFraction < 1 ? 1 : 0)
        }
        .padding(10)
    }
}
