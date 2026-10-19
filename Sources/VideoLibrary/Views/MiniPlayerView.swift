import SwiftUI

/// Small player in the corner of the library, like YouTube's miniplayer.
/// Shares the same `NativePlayerService` as the full player, so playback
/// continues seamlessly when switching between the two.
struct MiniPlayerView: View {
    @Environment(LibraryStore.self) private var store
    let item: VideoItem
    let player: NativePlayerService
    let expand: () -> Void
    let close: () -> Void

    @State private var isHovered = false
    @State private var lastSavedProgress: TimeInterval = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                AVKitPlayerView(service: player)
                    .allowsHitTesting(false)

                // Click anywhere on the video to go back to the full player.
                Color.clear
                    .contentShape(.rect)
                    .onTapGesture(perform: expand)

                if isHovered {
                    Color.black.opacity(0.35).allowsHitTesting(false)
                    Button {
                        player.togglePlayPause()
                    } label: {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.title)
                            .foregroundStyle(.white)
                            .frame(width: 52, height: 52)
                    }
                    .buttonStyle(.plain)
                    .help(player.isPlaying ? "Pause" : "Play")

                    VStack {
                        HStack {
                            overlayButton("arrow.up.left.and.arrow.down.right", help: "Expand", action: expand)
                            Spacer()
                            overlayButton("xmark", help: "Close", action: closeAndSave)
                        }
                        Spacer()
                    }
                    .padding(8)
                }
            }
            .frame(width: 320, height: 180)
            .overlay(alignment: .bottom) {
                GeometryReader { proxy in
                    Rectangle()
                        .fill(Color.red)
                        .frame(width: proxy.size.width * progress, height: 3)
                }
                .frame(height: 3)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                Text(item.uploader)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(width: 320, alignment: .leading)
            .contentShape(.rect)
            .onTapGesture(perform: expand)
        }
        .background(.background)
        .clipShape(.rect(cornerRadius: 14))
        .shadow(color: .black.opacity(0.35), radius: 18, y: 8)
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.15), value: isHovered)
        .onAppear { lastSavedProgress = player.currentPlaybackTime }
        .onChange(of: player.currentPlaybackTime) { _, time in
            guard time.isFinite, abs(time - lastSavedProgress) >= 5 else { return }
            lastSavedProgress = time
            store.updateWatchProgress(for: item.id, seconds: time)
        }
    }

    private var progress: CGFloat {
        guard player.duration > 0 else { return 0 }
        return CGFloat(min(1, max(0, player.currentPlaybackTime / player.duration)))
    }

    private func closeAndSave() {
        let time = player.currentPlaybackTime
        if time.isFinite { store.updateWatchProgress(for: item.id, seconds: time) }
        close()
    }

    private func overlayButton(_ systemImage: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.callout.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(.black.opacity(0.5), in: .circle)
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
