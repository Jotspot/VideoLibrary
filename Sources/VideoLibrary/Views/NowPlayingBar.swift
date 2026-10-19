import SwiftUI

/// Floating Liquid Glass music controls at the bottom of the library window
/// while a song is loaded, on every tab (music keeps playing while you
/// browse videos). Spotify-style layout: song · transport + scrubber · volume.
struct NowPlayingBar: View {
    let player: MusicPlayerService
    let store: MusicLibraryStore
    /// Shown as "Hide Music Bar" in the right-click menu (outside Music).
    var onHide: (() -> Void)? = nil

    /// Song info and the volume side share one width so the transport and
    /// scrubber sit in the exact center of the bar.
    private static let sideWidth: CGFloat = 220

    @State private var scrubTime: Double?
    @State private var showingQueue = false

    var body: some View {
        if let track = player.current {
            HStack(spacing: 20) {
                HStack(spacing: 12) {
                    ArtworkView(url: store.artworkURL(for: track.artworkFile), cornerRadius: 8)
                        .frame(width: 42, height: 42)
                        .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(track.title).font(.callout.weight(.semibold)).lineLimit(1)
                        Text(track.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    let liked = store.isLiked(track.id)
                    iconButton(liked ? "heart.fill" : "heart", help: liked ? "Remove from Liked Songs" : "Add to Liked Songs",
                               active: liked) {
                        store.toggleLike([track.id])
                        player.refresh(store.tracks)
                    }
                }
                .frame(width: Self.sideWidth, alignment: .leading)

                VStack(spacing: 4) {
                    HStack(spacing: 18) {
                        iconButton("shuffle", help: "Shuffle", active: player.isShuffled) { player.isShuffled.toggle() }
                        iconButton("backward.fill", help: "Previous") { player.previous() }
                        Button { player.togglePlayPause() } label: {
                            Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                                .font(.system(size: 30))
                        }
                        .buttonStyle(.plain)
                        .help(player.isPlaying ? "Pause" : "Play")
                        iconButton("forward.fill", help: "Next") { player.next() }
                        iconButton(player.repeatMode.symbol, help: "Repeat: \(player.repeatMode.rawValue)",
                                   active: player.repeatMode != .off) { player.repeatMode = player.repeatMode.next }
                    }
                    HStack(spacing: 8) {
                        Text(format(scrubTime ?? player.currentTime))
                            .frame(width: 40, alignment: .trailing)
                        Slider(
                            value: Binding(get: { scrubTime ?? player.currentTime },
                                           set: { scrubTime = $0 }),
                            in: 0...max(player.duration, 1),
                            onEditingChanged: { editing in
                                if !editing, let scrubTime { player.seek(to: scrubTime) }
                                if !editing { scrubTime = nil }
                            }
                        )
                        .controlSize(.mini)
                        Text("-" + format(max(0, player.duration - (scrubTime ?? player.currentTime))))
                            .frame(width: 44, alignment: .leading)
                    }
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                }
                .frame(maxWidth: 520)
                .frame(maxWidth: .infinity)

                HStack(spacing: 10) {
                    Image(systemName: player.volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .foregroundStyle(.secondary)
                    Slider(value: Binding(get: { Double(player.volume) }, set: { player.volume = Float($0) }), in: 0...1)
                        .controlSize(.mini)
                        .frame(width: 80)
                    iconButton("list.bullet", help: "Up Next") { showingQueue.toggle() }
                        .padding(.trailing, 8)
                        .popover(isPresented: $showingQueue, arrowEdge: .top) { queueList }
                }
                .frame(width: Self.sideWidth, alignment: .trailing)
            }
            .padding(.leading, 16)
            .padding(.trailing, 14)
            .padding(.vertical, 11)
            .frame(maxWidth: 1000)
            .glassEffect(.regular, in: .capsule)
            .contentShape(.capsule)
            .contextMenu {
                Button(player.isPlaying ? "Pause" : "Play") { player.togglePlayPause() }
                Button("Next Song") { player.next() }
                if let onHide {
                    Divider()
                    Button("Hide Music Bar", systemImage: "eye.slash") { onHide() }
                    Text("It comes back when you open Music.")
                }
            }
            .shadow(color: .black.opacity(0.18), radius: 16, y: 6)
            .padding(.horizontal, 20)
            .padding(.top, 6)
            .padding(.bottom, 14)
            .frame(maxWidth: .infinity)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private var queueList: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Up Next").font(.headline)
                Spacer()
                if !player.upNext.isEmpty {
                    Button("Clear") { player.clearQueue() }
                        .buttonStyle(.borderless)
                }
            }
            .padding(12)
            Divider()
            if player.upNext.isEmpty {
                Text(player.repeatMode == .all ? "The queue repeats from the start." : "Nothing queued. Right-click songs to Play Next or Add to Queue.")
                    .foregroundStyle(.secondary)
                    .padding(12)
            } else {
                List {
                    ForEach(player.upNext) { track in
                        HStack(spacing: 8) {
                            ArtworkView(url: store.artworkURL(for: track.artworkFile), cornerRadius: 3)
                                .frame(width: 28, height: 28)
                            VStack(alignment: .leading) {
                                Text(track.title).lineLimit(1)
                                Text(track.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            Text(track.formattedDuration).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        .contentShape(.rect)
                        .onTapGesture(count: 2) { player.jump(to: track) }
                        .contextMenu {
                            Button("Play Now") { player.jump(to: track) }
                            if let index = player.upNext.firstIndex(of: track) {
                                Button("Move to Top") { player.moveInQueue(from: [index], to: 0) }
                                Button("Remove from Queue") { player.removeFromQueue(at: [index]) }
                            }
                        }
                    }
                    .onDelete { player.removeFromQueue(at: $0) }
                    .onMove { player.moveInQueue(from: $0, to: $1) }
                }
                .listStyle(.plain)
            }
        }
        .frame(width: 320, height: 380)
    }

    private func iconButton(_ symbol: String, help: String, active: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.callout.weight(.semibold))
                .foregroundStyle(active ? Color.accentColor : .primary)
                .frame(width: 24, height: 24)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func format(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "0:00" }
        let s = Int(seconds)
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
