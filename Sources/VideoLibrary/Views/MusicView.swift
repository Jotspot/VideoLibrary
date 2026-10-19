import AppKit
import ImageIO
import SwiftUI

/// The Music tab: songs, albums, artists and playlists for this library.
struct MusicView: View {
    let store: MusicLibraryStore
    let player: MusicPlayerService
    let searchQuery: String

    enum Section: String, CaseIterable, Identifiable {
        case songs, albums, artists, playlists
        var id: String { rawValue }
        var label: String { rawValue.capitalized }
    }

    @AppStorage("musicSection") private var section = Section.songs
    @State private var path = NavigationPath()

    private var filteredTracks: [Song] {
        let query = searchQuery.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return store.tracks }
        return store.tracks.filter {
            $0.title.lowercased().contains(query) || $0.artist.lowercased().contains(query)
                || $0.album.lowercased().contains(query) || $0.genre.lowercased().contains(query)
        }
    }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if store.sources.isEmpty {
                    emptyState
                } else {
                    VStack(spacing: 0) {
                        header
                        Divider()
                        content
                    }
                }
            }
            .navigationDestination(for: MusicAlbum.self) { album in
                MusicCollectionView(
                    title: album.title,
                    subtitle: [album.artist, album.year.map(String.init)].compactMap { $0 }.joined(separator: " · "),
                    artworkURL: store.artworkURL(for: album.artworkFile),
                    tracks: album.tracks,
                    store: store, player: player
                )
            }
            .navigationDestination(for: MusicSource.self) { source in
                MusicCollectionView(
                    title: source.name, subtitle: "Folder",
                    artworkURL: store.artworkURL(for: store.tracks(in: source).compactMap(\.artworkFile).first),
                    tracks: store.tracks(in: source),
                    store: store, player: player
                )
            }
            .navigationDestination(for: MusicPlaylist.self) { playlist in
                // Re-read so edits show immediately.
                let current = store.playlists.first { $0.id == playlist.id } ?? playlist
                MusicCollectionView(
                    title: current.name, subtitle: "Playlist",
                    artworkURL: store.artworkURL(for: store.tracks(in: current).compactMap(\.artworkFile).first),
                    tracks: store.tracks(in: current),
                    store: store, player: player, playlist: current
                )
            }
            .navigationDestination(for: SmartPlaylist.self) { smart in
                let tracks = smart.tracks(in: store)
                MusicCollectionView(
                    title: smart.title, subtitle: "Playlist",
                    artworkURL: store.artworkURL(for: tracks.compactMap(\.artworkFile).first),
                    tracks: tracks, store: store, player: player
                )
            }
            .navigationDestination(for: ArtistRoute.self) { route in
                let tracks = store.artists.first { $0.name == route.name }?.tracks ?? []
                MusicCollectionView(
                    title: route.name, subtitle: "Artist",
                    artworkURL: store.artworkURL(for: tracks.compactMap(\.artworkFile).first),
                    tracks: tracks, store: store, player: player
                )
            }
        }
        .onChange(of: section) { _, _ in path = NavigationPath() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            Text("Music").font(.largeTitle.bold())
            Picker("View", selection: $section) {
                ForEach(Section.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            Spacer()

            if store.isScanning {
                ProgressView().controlSize(.small)
                Text(store.scanStatus).font(.caption).foregroundStyle(.secondary)
            } else {
                Text("\(store.tracks.count) songs").font(.caption).foregroundStyle(.secondary)
            }

            Button("Play", systemImage: "play.fill") { player.play(filteredTracks, shuffled: false) }
                .disabled(filteredTracks.isEmpty)
            Button("Shuffle", systemImage: "shuffle") { player.play(filteredTracks, shuffled: true) }
                .disabled(filteredTracks.isEmpty)
            Menu {
                Button("Add Music Folder…", systemImage: "folder.badge.plus") { store.chooseFolders() }
                Button("Rescan Folders", systemImage: "arrow.clockwise") { Task { await store.rescan() } }
                if !store.sources.isEmpty {
                    Divider()
                    Menu("Remove Folder") {
                        ForEach(store.sources) { source in
                            Button(source.name) { store.removeSource(source) }
                        }
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
    }

    @ViewBuilder
    private var content: some View {
        switch section {
        case .songs:
            SongTable(tracks: filteredTracks, store: store, player: player)
        case .albums:
            albumsGrid
        case .artists:
            artistsList
        case .playlists:
            playlistsList
        }
    }

    // MARK: - Albums

    private var albumsGrid: some View {
        let query = searchQuery.lowercased()
        let albums = store.albums.filter {
            query.isEmpty || $0.title.lowercased().contains(query) || $0.artist.lowercased().contains(query)
        }
        return ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 160, maximum: 200), spacing: 20)], spacing: 22) {
                ForEach(albums) { album in
                    NavigationLink(value: album) {
                        VStack(alignment: .leading, spacing: 6) {
                            ArtworkView(url: store.artworkURL(for: album.artworkFile), cornerRadius: 8)
                                .aspectRatio(1, contentMode: .fit)
                                .shadow(color: .black.opacity(0.2), radius: 6, y: 3)
                            Text(album.title).font(.callout.weight(.semibold)).lineLimit(1)
                            Text(album.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("Play", systemImage: "play.fill") { player.play(album.tracks, shuffled: false) }
                        Button("Shuffle", systemImage: "shuffle") { player.play(album.tracks, shuffled: true) }
                        Button("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") { player.playNext(album.tracks) }
                        Button("Add to Queue", systemImage: "text.badge.plus") { player.addToQueue(album.tracks) }
                    }
                }
            }
            .padding(24)
        }
    }

    // MARK: - Artists

    private var artistsList: some View {
        let query = searchQuery.lowercased()
        let artists = store.artists.filter { query.isEmpty || $0.name.lowercased().contains(query) }
        return List(artists, id: \.name) { artist in
            NavigationLink(value: ArtistRoute(name: artist.name)) {
                HStack(spacing: 12) {
                    ArtworkView(url: store.artworkURL(for: artist.tracks.compactMap(\.artworkFile).first), cornerRadius: 20)
                        .frame(width: 40, height: 40)
                    VStack(alignment: .leading) {
                        Text(artist.name).font(.headline)
                        Text("\(artist.tracks.count) song\(artist.tracks.count == 1 ? "" : "s")")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 2)
            }
            .contextMenu {
                Button("Play", systemImage: "play.fill") { player.play(artist.tracks, shuffled: false) }
                Button("Shuffle", systemImage: "shuffle") { player.play(artist.tracks, shuffled: true) }
            }
        }
        .listStyle(.inset)
    }

    // MARK: - Playlists

    @State private var newPlaylistName = ""
    @State private var showingNewPlaylist = false
    @AppStorage("musicMadeForYouExpanded") private var madeForYouExpanded = true

    private var playlistsList: some View {
        List {
            SwiftUI.Section {
                if madeForYouExpanded {
                ForEach(SmartPlaylist.allCases) { smart in
                    let tracks = smart.tracks(in: store)
                    NavigationLink(value: smart) {
                        playlistRow(name: smart.title, tracks: tracks, symbol: smart.symbol)
                    }
                    .contextMenu {
                        Button("Play", systemImage: "play.fill") { player.play(tracks, shuffled: false) }
                        Button("Shuffle", systemImage: "shuffle") { player.play(tracks, shuffled: true) }
                    }
                }
                }
            } header: {
                Button {
                    withAnimation(.snappy) { madeForYouExpanded.toggle() }
                } label: {
                    HStack(spacing: 4) {
                        Text("Made for You")
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.bold))
                            .rotationEffect(.degrees(madeForYouExpanded ? 90 : 0))
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help(madeForYouExpanded ? "Collapse" : "Expand")
            }
            SwiftUI.Section("Folders") {
                ForEach(store.sources) { source in
                    NavigationLink(value: source) {
                        playlistRow(name: source.name, tracks: store.tracks(in: source), symbol: "folder.fill")
                    }
                    .contextMenu {
                        Button("Play", systemImage: "play.fill") { player.play(store.tracks(in: source), shuffled: false) }
                        Button("Shuffle", systemImage: "shuffle") { player.play(store.tracks(in: source), shuffled: true) }
                        Button("Show in Finder", systemImage: "folder") {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: source.path)])
                        }
                    }
                }
            }
            SwiftUI.Section {
                ForEach(store.playlists) { playlist in
                    NavigationLink(value: playlist) {
                        playlistRow(name: playlist.name, tracks: store.tracks(in: playlist), symbol: "music.note.list")
                    }
                    .contextMenu {
                        Button("Play", systemImage: "play.fill") { player.play(store.tracks(in: playlist), shuffled: false) }
                        Button("Shuffle", systemImage: "shuffle") { player.play(store.tracks(in: playlist), shuffled: true) }
                        Divider()
                        Button("Delete Playlist", systemImage: "trash", role: .destructive) { store.delete(playlist) }
                    }
                }
                Button("New Playlist…", systemImage: "plus") { showingNewPlaylist = true }
                    .buttonStyle(.borderless)
            } header: {
                Text("Playlists")
            }
        }
        .listStyle(.inset)
        .alert("New Playlist", isPresented: $showingNewPlaylist) {
            TextField("Name", text: $newPlaylistName)
            Button("Create") {
                let name = newPlaylistName.trimmingCharacters(in: .whitespaces)
                if !name.isEmpty { store.createPlaylist(named: name) }
                newPlaylistName = ""
            }
            Button("Cancel", role: .cancel) { newPlaylistName = "" }
        }
    }

    private func playlistRow(name: String, tracks: [Song], symbol: String) -> some View {
        HStack(spacing: 12) {
            ArtworkView(url: store.artworkURL(for: tracks.compactMap(\.artworkFile).first), cornerRadius: 6,
                        placeholderSymbol: symbol)
                .frame(width: 44, height: 44)
            VStack(alignment: .leading) {
                Text(name).font(.headline)
                Text("\(tracks.count) song\(tracks.count == 1 ? "" : "s") · \(totalTime(tracks))")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - Empty

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Music Yet", systemImage: "music.note")
        } description: {
            Text("Add a folder of songs (MP3, M4A, FLAC, WAV…). Their tags and cover art are read automatically, and each folder also becomes a playlist.")
        } actions: {
            Button("Add Music Folder…", systemImage: "folder.badge.plus") { store.chooseFolders() }
                .buttonStyle(.borderedProminent)
        }
    }
}

struct ArtistRoute: Hashable { let name: String }

/// Playlists the app keeps up to date by itself.
enum SmartPlaylist: String, CaseIterable, Identifiable, Hashable {
    case liked, recent, mostPlayed
    var id: String { rawValue }

    var title: String {
        switch self {
        case .liked: "Liked Songs"
        case .recent: "Recently Played"
        case .mostPlayed: "Most Played"
        }
    }

    var symbol: String {
        switch self {
        case .liked: "heart.fill"
        case .recent: "clock.fill"
        case .mostPlayed: "chart.bar.fill"
        }
    }

    @MainActor
    func tracks(in store: MusicLibraryStore) -> [Song] {
        switch self {
        case .liked: store.likedTracks
        case .recent: store.recentlyPlayed
        case .mostPlayed: store.mostPlayed
        }
    }
}

func totalTime(_ tracks: [Song]) -> String {
    let seconds = Int(tracks.reduce(0) { $0 + ($1.duration.isFinite ? $1.duration : 0) })
    return seconds >= 3600 ? "\(seconds / 3600) hr \((seconds % 3600) / 60) min" : "\(seconds / 60) min"
}

// MARK: - Album / playlist / artist page

struct MusicCollectionView: View {
    let title: String
    let subtitle: String
    let artworkURL: URL?
    let tracks: [Song]
    let store: MusicLibraryStore
    let player: MusicPlayerService
    var playlist: MusicPlaylist? = nil

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .bottom, spacing: 20) {
                ArtworkView(url: artworkURL, cornerRadius: 10)
                    .frame(width: 150, height: 150)
                    .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
                VStack(alignment: .leading, spacing: 6) {
                    Text(subtitle.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Text(title).font(.largeTitle.bold()).lineLimit(2)
                    Text("\(tracks.count) song\(tracks.count == 1 ? "" : "s") · \(totalTime(tracks))")
                        .foregroundStyle(.secondary)
                    HStack {
                        Button("Play", systemImage: "play.fill") { player.play(tracks, shuffled: false) }
                            .buttonStyle(.borderedProminent)
                        Button("Shuffle", systemImage: "shuffle") { player.play(tracks, shuffled: true) }
                    }
                    .disabled(tracks.isEmpty)
                    .padding(.top, 4)
                }
                Spacer()
            }
            .padding(24)
            Divider()
            SongTable(tracks: tracks, store: store, player: player, playlist: playlist)
        }
        // Pushed pages replace the split view's whole detail column
        // (including RootView's bar), so they carry their own.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            NowPlayingBar(player: player, store: store)
        }
        .navigationTitle(title)
    }
}

// MARK: - Song table

struct SongTable: View {
    let tracks: [Song]
    let store: MusicLibraryStore
    let player: MusicPlayerService
    var playlist: MusicPlaylist? = nil

    @State private var selection = Set<Song.ID>()
    /// Cells under the pointer per row. A count (not one ID) because moving
    /// between cells of the same row can report the enter before the leave.
    @State private var hoverCounts: [Song.ID: Int] = [:]
    @State private var sortOrder: [KeyPathComparator<Song>] = []
    @State private var newPlaylistFor: [UUID]?
    @State private var newPlaylistName = ""

    private var rows: [Song] {
        sortOrder.isEmpty ? tracks : tracks.sorted(using: sortOrder)
    }

    var body: some View {
        Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("") { track in
                Button {
                    store.toggleLike([track.id])
                    player.refresh(store.tracks)
                } label: {
                    Image(systemName: track.liked ? "heart.fill" : "heart")
                        .foregroundStyle(track.liked ? Color.accentColor : Color.secondary.opacity(0.6))
                }
                .buttonStyle(.plain)
                .help(track.liked ? "Remove from Liked Songs" : "Add to Liked Songs")
                .rowHover(track.id, in: $hoverCounts)
            }
            .width(22)
            TableColumn("Title", value: \.title) { track in
                HStack(spacing: 8) {
                    SongArtworkButton(track: track, store: store, player: player,
                                      rowHovered: (hoverCounts[track.id] ?? 0) > 0) {
                        player.play(rows, startingAt: track)
                    }
                    Text(track.title)
                        .fontWeight(player.current?.id == track.id ? .semibold : .regular)
                        // Accent text on the accent selection highlight was
                        // unreadable, so a selected row keeps the system color.
                        .foregroundStyle(player.current?.id == track.id && !selection.contains(track.id)
                                         ? Color.accentColor : .primary)
                        .lineLimit(1)
                }
                .rowHover(track.id, in: $hoverCounts)
            }
            .width(min: 180, ideal: 280)
            TableColumn("Artist", value: \.artist) { Text($0.artist).lineLimit(1).rowHover($0.id, in: $hoverCounts) }
                .width(min: 100, ideal: 160)
            TableColumn("Album", value: \.album) { Text($0.album).lineLimit(1).rowHover($0.id, in: $hoverCounts) }
                .width(min: 100, ideal: 180)
            TableColumn("Genre", value: \.genre) {
                Text($0.genre).lineLimit(1).foregroundStyle(.secondary).rowHover($0.id, in: $hoverCounts)
            }
                .width(min: 60, ideal: 90)
            TableColumn("Plays", value: \.playCount) { track in
                Text(track.playCount > 0 ? "\(track.playCount)" : "").foregroundStyle(.secondary).monospacedDigit()
                    .rowHover(track.id, in: $hoverCounts)
            }
            .width(min: 40, ideal: 50, max: 60)
            TableColumn("Time", value: \.duration) {
                Text($0.formattedDuration).monospacedDigit().foregroundStyle(.secondary).rowHover($0.id, in: $hoverCounts)
            }
                .width(min: 50, ideal: 56, max: 70)
        }
        // Space plays/pauses while the list has focus.
        .onKeyPress(.space) {
            player.togglePlayPause()
            return .handled
        }
        .contextMenu(forSelectionType: Song.ID.self) { ids in
            menu(for: ids)
        } primaryAction: { ids in
            // Double-click / Return plays from that song, with the rest queued.
            if let id = ids.first, let track = rows.first(where: { $0.id == id }) {
                player.play(rows, startingAt: track)
            }
        }
        .alert("New Playlist", isPresented: Binding(get: { newPlaylistFor != nil }, set: { if !$0 { newPlaylistFor = nil } })) {
            TextField("Name", text: $newPlaylistName)
            Button("Create") {
                let name = newPlaylistName.trimmingCharacters(in: .whitespaces)
                if !name.isEmpty, let ids = newPlaylistFor { store.createPlaylist(named: name, with: ids) }
                newPlaylistName = ""
                newPlaylistFor = nil
            }
            Button("Cancel", role: .cancel) { newPlaylistName = ""; newPlaylistFor = nil }
        }
    }

    @ViewBuilder
    private func menu(for ids: Set<Song.ID>) -> some View {
        let chosen = rows.filter { ids.contains($0.id) }
        if !chosen.isEmpty {
            Button("Play", systemImage: "play.fill") {
                chosen.count == 1 ? player.play(rows, startingAt: chosen[0]) : player.play(chosen, shuffled: false)
            }
            Button("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") { player.playNext(chosen) }
            Button("Add to Queue", systemImage: "text.badge.plus") { player.addToQueue(chosen) }
            Divider()
            let allLiked = chosen.allSatisfy(\.liked)
            Button(allLiked ? "Remove from Liked Songs" : "Add to Liked Songs",
                   systemImage: allLiked ? "heart.slash" : "heart") {
                store.toggleLike(Set(chosen.map(\.id)))
                player.refresh(store.tracks)
            }
            Menu("Add to Playlist") {
                ForEach(store.playlists.filter { $0.id != playlist?.id }) { list in
                    Button(list.name) { store.add(chosen.map(\.id), to: list) }
                }
                if !store.playlists.isEmpty { Divider() }
                Button("New Playlist…") { newPlaylistFor = chosen.map(\.id) }
            }
            if let playlist {
                Button("Remove from Playlist", systemImage: "minus.circle") {
                    store.remove(Set(chosen.map(\.id)), from: playlist)
                }
            }
            Divider()
            Button("Show in Finder", systemImage: "folder") {
                NSWorkspace.shared.activateFileViewerSelecting(chosen.map(\.url))
            }
        }
    }
}

extension View {
    /// Fills the table cell and counts the pointer in or out of `id`'s row.
    func rowHover(_ id: UUID, in counts: Binding<[UUID: Int]>) -> some View {
        frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
            .onHover { inside in
                let next = (counts.wrappedValue[id] ?? 0) + (inside ? 1 : -1)
                counts.wrappedValue[id] = next > 0 ? next : nil
            }
    }
}

/// A song's cover in the list. Hovering the row shows a play button (pause for the
/// song that's playing); the playing song shows a speaker otherwise.
private struct SongArtworkButton: View {
    let track: Song
    let store: MusicLibraryStore
    let player: MusicPlayerService
    /// The pointer is anywhere on this song's row.
    let rowHovered: Bool
    let play: () -> Void

    private var isCurrent: Bool { player.current?.id == track.id }

    var body: some View {
        ZStack {
            ArtworkView(url: store.artworkURL(for: track.artworkFile), cornerRadius: 3)
            if rowHovered || isCurrent {
                Color.black.opacity(0.5)
                Image(systemName: rowHovered
                      ? (isCurrent && player.isPlaying ? "pause.fill" : "play.fill")
                      : (player.isPlaying ? "speaker.wave.2.fill" : "speaker.fill"))
                    .font(.caption2).foregroundStyle(.white)
            }
        }
        .frame(width: 26, height: 26)
        .clipShape(.rect(cornerRadius: 3))
        .contentShape(.rect)
        .onTapGesture {
            if isCurrent { player.togglePlayPause() } else { play() }
        }
        .help(isCurrent && player.isPlaying ? "Pause" : "Play")
    }
}

// MARK: - Artwork

/// Cover art, downscaled off the main thread and cached.
struct ArtworkView: View {
    let url: URL?
    var cornerRadius: CGFloat = 6
    var placeholderSymbol = "music.note"
    var maxPixelSize: Int = 400

    @State private var image: NSImage?

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                Rectangle().fill(.quaternary)
                    .overlay(Image(systemName: placeholderSymbol).foregroundStyle(.tertiary))
            }
        }
        .clipShape(.rect(cornerRadius: cornerRadius))
        .task(id: url) {
            guard let url else { image = nil; return }
            image = await ArtworkCache.shared.image(for: url, maxPixelSize: maxPixelSize)
        }
    }
}

final class ArtworkCache: @unchecked Sendable {
    static let shared = ArtworkCache()
    private let cache = NSCache<NSString, NSImage>()

    init() {
        cache.totalCostLimit = 80 * 1024 * 1024   // ~80 MB of decoded images
    }

    func image(for url: URL, maxPixelSize: Int = 400) async -> NSImage? {
        let key = "\(url.path)#\(maxPixelSize)" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        let image = await Task.detached(priority: .userInitiated) { () -> NSImage? in
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
                kCGImageSourceCreateThumbnailWithTransform: true
            ]
            guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
            return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        }.value
        if let image {
            let cost = Int(image.size.width * image.size.height * 4)
            cache.setObject(image, forKey: key, cost: cost)
        }
        return image
    }
}
