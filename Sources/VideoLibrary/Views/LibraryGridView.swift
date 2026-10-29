import SwiftUI
import AppKit

struct LibraryGridView: View {
    @Environment(LibraryStore.self) private var store
    let lastPlayedID: UUID?
    let play: (VideoItem) -> Void
    /// Select mode: clicks pick cards instead of playing them. ⌘-click or
    /// ⇧-click a card also starts it.
    @State private var isSelecting = false
    @State private var selection: Set<UUID> = []
    /// The last card clicked, where a ⇧-click range starts.
    @State private var selectionAnchor: UUID?

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
                                resolution: store.resolutionLabels[item.id],
                                isChecked: isSelecting ? selection.contains(item.id) : nil
                            )
                            .contentShape(.rect)
                            .onTapGesture { tap(item, in: visibleItems) }
                            // Drag a card to the desktop or any Finder folder for a copy.
                            .modifier(VideoDragModifier(item: item))
                            .help(isSelecting ? "" : "Play \u{201C}\(item.title)\u{201D}")
                            .contextMenu {
                                contextMenu(for: item, visibleItems: visibleItems)
                            }
                        }
                    }
                }
            }
            .padding(24)
        }
        .animation(.smooth, value: visibleItems.map(\.id))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: store.items) { _, items in
            // Deleted or moved videos drop out of the selection.
            let ids = Set(items.map(\.id))
            selection.formIntersection(ids)
        }
        .onChange(of: store.selectedLibraryID) { _, _ in endSelecting() }
    }

    /// Plays the video, or selects it in select mode (⌘ toggles, ⇧ picks a range).
    private func tap(_ item: VideoItem, in visibleItems: [VideoItem]) {
        let flags = NSEvent.modifierFlags
        if flags.contains(.shift),
           let anchor = selectionAnchor,
           let start = visibleItems.firstIndex(where: { $0.id == anchor }),
           let end = visibleItems.firstIndex(where: { $0.id == item.id }) {
            isSelecting = true
            selection.formUnion(visibleItems[min(start, end)...max(start, end)].map(\.id))
        } else if isSelecting || flags.contains(.command) || flags.contains(.shift) {
            isSelecting = true
            if selection.contains(item.id) {
                selection.remove(item.id)
            } else {
                selection.insert(item.id)
            }
            selectionAnchor = item.id
        } else {
            play(item)
        }
    }

    private func endSelecting() {
        isSelecting = false
        selection = []
        selectionAnchor = nil
    }

    private var selectedItems: [VideoItem] {
        store.items.filter { selection.contains($0.id) }
    }

    private func deleteSelection() {
        if store.confirmRemove(selectedItems) { endSelecting() }
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

    @ViewBuilder
    private var libraryControls: some View {
        if isSelecting {
            selectionControls
        } else {
            browsingControls
        }
    }

    private var selectionControls: some View {
        HStack(spacing: 10) {
            Text(selection.isEmpty ? "Select videos" : "\(selection.count) selected")
                .font(.headline.monospacedDigit())

            Text("⌘-click to pick, ⇧-click for a range")
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()

            let visibleIDs = Set(store.filteredItems.map(\.id))
            if visibleIDs.isSubset(of: selection) {
                Button("Deselect All") { selection.subtract(visibleIDs) }
            } else {
                Button("Select All") { selection.formUnion(visibleIDs) }
            }

            Button(role: .destructive, action: deleteSelection) {
                Label(selection.isEmpty ? "Delete" : "Delete \(selection.count)", systemImage: "trash")
            }
            .keyboardShortcut(.delete, modifiers: .command)
            .disabled(selection.isEmpty)

            Button("Done", action: endSelecting)
                .keyboardShortcut(.cancelAction)
                .buttonStyle(.borderedProminent)
        }
    }

    private var browsingControls: some View {
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

                Button(role: .destructive) {
                    store.confirmRemove(store.items(byUploader: selectedUploader), uploader: selectedUploader)
                } label: {
                    Label("Delete Channel…", systemImage: "trash")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .help("Delete every video by \(selectedUploader) and its folder")
            }

            Spacer()

            if store.filteredItems.count != store.items.filter({ $0.status == .downloaded }).count {
                Text("\(store.filteredItems.count) shown")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button {
                isSelecting = true
            } label: {
                Label("Select", systemImage: "checkmark.circle")
            }
            .help("Select several videos to delete (or ⌘-click a video)")
            .disabled(store.filteredItems.isEmpty)
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
    private func contextMenu(for item: VideoItem, visibleItems: [VideoItem]) -> some View {
        if isSelecting, selection.contains(item.id), selection.count > 1 {
            Button(role: .destructive, action: deleteSelection) {
                Label("Delete \(selection.count) Selected Videos…", systemImage: "trash")
            }
            Button("Done Selecting", action: endSelecting)
        } else {
            itemMenu(for: item)
        }
    }

    @ViewBuilder
    private func itemMenu(for item: VideoItem) -> some View {
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
            ShareLink(item: url) {
                Label("Share", systemImage: "square.and.arrow.up")
            }
            Button {
                VideoSharingService.saveToDownloads(item)
            } label: {
                Label("Save to Downloads", systemImage: "arrow.down.circle")
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

        Button {
            isSelecting = true
            selection.insert(item.id)
            selectionAnchor = item.id
        } label: {
            Label("Select", systemImage: "checkmark.circle")
        }

        Divider()

        Button(role: .destructive) {
            store.remove(item)
        } label: {
            Label("Delete", systemImage: "trash")
        }

        Button(role: .destructive) {
            store.confirmRemove(store.items(byUploader: item.uploader), uploader: item.uploader)
        } label: {
            Label("Delete All by \(item.uploader)…", systemImage: "person.crop.circle.badge.minus")
        }
    }
}

/// Makes a downloaded video's card draggable; the drag image is its thumbnail.
private struct VideoDragModifier: ViewModifier {
    let item: VideoItem

    func body(content: Content) -> some View {
        if let url = item.videoURL, item.status == .downloaded {
            content.draggable(VideoFileDrag(url: url)) {
                ArtworkView(url: item.thumbnailURL, cornerRadius: 8, placeholderSymbol: "film", maxPixelSize: 320)
                    .frame(width: 160, height: 90)
            }
        } else {
            content
        }
    }
}
