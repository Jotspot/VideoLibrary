import SwiftUI

struct LibraryGridView: View {
    @Environment(LibraryStore.self) private var store
    let lastPlayedID: UUID?
    let play: (VideoItem) -> Void

    private let columns = [
        // Capped width: with only a minimum, a narrow window gave one or
        // two huge cards per row.
        GridItem(.adaptive(minimum: 210, maximum: 330), spacing: 18, alignment: .top)
    ]

    var body: some View {
        // Sort/filter once per redraw (it was recomputed four times).
        let visibleItems = store.sortedFilteredItems
        return ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                libraryHeader

                if !store.lowQualityItemIDs.isEmpty {
                    qualityBanner
                }

                libraryControls

                if visibleItems.isEmpty {
                    emptyState
                        .frame(maxWidth: .infinity)
                } else {
                    LazyVGrid(columns: columns, spacing: 24) {
                        ForEach(visibleItems) { item in
                            VideoCardView(
                                item: item,
                                isSelected: lastPlayedID == item.id,
                                resolution: store.resolutionLabels[item.id]
                            )
                            .contentShape(.rect)
                            .onTapGesture { play(item) }
                            .help("Play \u{201C}\(item.title)\u{201D}")
                            .contextMenu {
                                contextMenu(for: item)
                            }
                        }
                    }
                }
            }
            .padding(24)
        }
        .animation(.smooth, value: visibleItems.map(\.id))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var libraryHeader: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(store.selectedLibrary.name)
                .font(.largeTitle.bold())
                .lineLimit(1)
            Spacer()
            HStack(spacing: 16) {
                stat(value: "\(store.items.filter { $0.status == .downloaded }.count)", label: "videos")
                stat(value: ByteCountFormatter.string(fromByteCount: store.totalLibraryBytes, countStyle: .file), label: "used")
                if let free = store.freeSpaceBytes {
                    stat(value: ByteCountFormatter.string(fromByteCount: free, countStyle: .file), label: "free")
                }
            }
        }
    }

    private func stat(value: String, label: String) -> some View {
        VStack(alignment: .trailing, spacing: 0) {
            Text(value)
                .font(.title3.weight(.semibold).monospacedDigit())
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var qualityBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "sparkles.tv")
                .font(.title2)
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(store.lowQualityItemIDs.count) videos were saved in low quality")
                    .font(.headline)
                Text("YouTube only offered 360p while downloads used your sign-in. That's fixed. Re-download them in full quality; watch progress is kept.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(store.isUpgradingQuality ? "Re-downloading…" : "Re-download in HD") {
                store.upgradeLowQualityVideos()
            }
            .buttonStyle(.borderedProminent)
            .disabled(store.isUpgradingQuality)
        }
        .padding(14)
        .background(.orange.opacity(0.1), in: .rect(cornerRadius: 12))
    }

    private var libraryControls: some View {
        HStack(spacing: 10) {
            Menu {
                Picker("Sort By", selection: Bindable(store).videoSortOption) {
                    ForEach(VideoSortOption.allCases) { option in
                        Text(option.label).tag(option)
                    }
                }

                Divider()

                Picker("Direction", selection: Bindable(store).videoSortAscending) {
                    Text("Ascending").tag(true)
                    Text("Descending").tag(false)
                }
            } label: {
                Label(
                    "Sort: \(store.videoSortOption.label)",
                    systemImage: "arrow.up.arrow.down"
                )
            }

            if let selectedUploader = store.selectedUploader {
                Button {
                    store.selectUploader(nil)
                } label: {
                    Label(selectedUploader, systemImage: "person.crop.rectangle.badge.xmark")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
            }

            Spacer()

            if store.filteredItems.count != store.items.filter({ $0.status == .downloaded }).count {
                Text("\(store.filteredItems.count) shown")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if store.searchQuery.isEmpty {
            ContentUnavailableView(
                "No Videos",
                systemImage: "arrow.down.circle",
                description: Text("Add a video using the + button in the toolbar.")
            )
            .padding(.top, 80)
        } else {
            ContentUnavailableView.search(text: store.searchQuery)
                .padding(.top, 80)
        }
    }

    @ViewBuilder
    private func contextMenu(for item: VideoItem) -> some View {
        Button {
            play(item)
        } label: {
            Label("Play", systemImage: "play.fill")
        }

        if !item.ytdlpID.hasPrefix("local-") {
            Button {
                store.redownload(item)
            } label: {
                Label(store.lowQualityItemIDs.contains(item.id) ? "Re-download in HD" : "Re-download",
                      systemImage: "arrow.clockwise.circle")
            }
        }

        if item.watchProgressFraction > 0 {
            Button {
                var restarted = item
                restarted.watchProgress = 0
                store.updateWatchProgress(for: item.id, seconds: 0)
                play(restarted)
            } label: {
                Label("Play from Beginning", systemImage: "backward.end.fill")
            }
        }

        Divider()

        if let url = item.videoURL {
            Button {
                VideoSharingService.sendViaAirDrop(url)
            } label: {
                Label("Share via AirDrop", systemImage: "square.and.arrow.up")
            }
        }

        let destinationLibraries = store.sortedLibraries.filter {
            $0.id != store.selectedLibraryID && $0.isAvailable
        }
        if !destinationLibraries.isEmpty {
            Menu {
                ForEach(destinationLibraries) { library in
                    Button {
                        store.move(item, to: library.id)
                    } label: {
                        Label(library.name, systemImage: store.librarySystemImage(for: library))
                    }
                }
            } label: {
                Label("Move to Library", systemImage: "folder")
            }
        }

        Button(role: .destructive) {
            store.remove(item)
        } label: {
            Label("Delete", systemImage: "trash")
        }
    }
}
