import AppKit
import Foundation
import Observation

/// Music for the selected library: the folders added with +, their songs
/// (tags + cached cover art) and the user's playlists. Persisted per
/// library in `{library}/.VideoLibrary/music.json`; cover art is cached in
/// `{library}/.VideoLibrary/music-artwork/`.
@Observable
@MainActor
final class MusicLibraryStore {
    /// Which collection is loaded: a library ID, or "app" for app-wide.
    private(set) var collectionKey: String?
    private(set) var sources: [MusicSource] = []
    private(set) var tracks: [Song] = []
    private(set) var playlists: [MusicPlaylist] = []
    private(set) var isScanning = false
    private(set) var scanStatus = ""

    @ObservationIgnored private var dataDirectory: URL?

    private var fileURL: URL? { dataDirectory?.appendingPathComponent("music.json") }
    var artworkDirectory: URL? { dataDirectory?.appendingPathComponent("music-artwork", isDirectory: true) }

    func artworkURL(for file: String?) -> URL? {
        guard let file, let directory = artworkDirectory else { return nil }
        return directory.appendingPathComponent(file)
    }

    // MARK: - Loading

    @ObservationIgnored private var replacedObserver: NSObjectProtocol?

    init() {
        replacedObserver = NotificationCenter.default.addObserver(
            forName: MusicSettings.collectionReplaced, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let (directory, key) = (self.dataDirectory, self.collectionKey)
                self.collectionKey = nil   // force a reload
                self.load(directory: directory, key: key)
            }
        }
    }

    /// Switches collection: a library's `.VideoLibrary` folder, the
    /// app-wide music folder, or nil when music is off.
    func load(directory: URL?, key: String?) {
        guard key != collectionKey || directory != dataDirectory else { return }
        collectionKey = key
        dataDirectory = directory
        sources = []; tracks = []; playlists = []
        guard let fileURL, let data = try? Data(contentsOf: fileURL),
              let file = try? JSONDecoder().decode(MusicLibraryFile.self, from: data) else { return }
        sources = file.sources
        tracks = file.tracks
        playlists = file.playlists
        Task { await rescan() }
    }

    private func save() {
        guard let fileURL else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let file = MusicLibraryFile(sources: sources, tracks: tracks, playlists: playlists)
        guard let data = try? JSONEncoder().encode(file) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    // MARK: - Folders

    /// Asks for one or more music folders, then imports them.
    func chooseFolders() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add Music"
        panel.message = "Choose folders with music. Each folder also becomes a playlist."
        guard panel.runModal() == .OK else { return }
        Task { await addFolders(panel.urls) }
    }

    func addFolders(_ urls: [URL]) async {
        for url in urls {
            let path = url.standardizedFileURL.path
            guard !sources.contains(where: { $0.path == path }) else { continue }
            sources.append(MusicSource(id: UUID(), name: url.lastPathComponent, path: path))
        }
        save()
        await rescan()
    }

    func removeSource(_ source: MusicSource) {
        sources.removeAll { $0.id == source.id }
        let removed = Set(tracks.filter { $0.sourceID == source.id }.map(\.id))
        tracks.removeAll { removed.contains($0.id) }
        for index in playlists.indices {
            playlists[index].trackIDs.removeAll { removed.contains($0) }
        }
        save()
    }

    /// Picks up added, changed and deleted files in every folder. Existing
    /// songs keep their identity, play counts and playlist membership.
    func rescan() async {
        guard !isScanning, let artworkDirectory else { return }
        isScanning = true
        defer { isScanning = false; scanStatus = "" }

        let existingByPath = Dictionary(tracks.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        var updated: [Song] = []
        for source in sources {
            let folder = URL(fileURLWithPath: source.path, isDirectory: true)
            // Keep songs from a disconnected drive rather than dropping them.
            guard FileManager.default.fileExists(atPath: folder.path) else {
                updated += tracks.filter { $0.sourceID == source.id }
                continue
            }
            scanStatus = "Scanning \(source.name)…"
            let files = await Task.detached { MusicScanner.audioFiles(in: folder) }.value
            var toScan: [URL] = []
            for file in files {
                let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                if var known = existingByPath[file.path], known.fileModified == modified {
                    known.sourceID = source.id
                    updated.append(known)
                } else {
                    toScan.append(file)
                }
            }
            for scanned in await MusicScanner.scan(toScan, artworkDirectory: artworkDirectory) {
                let previous = existingByPath[scanned.path]
                updated.append(Song(
                    id: previous?.id ?? UUID(),
                    path: scanned.path,
                    sourceID: source.id,
                    title: scanned.title,
                    artist: scanned.artist,
                    album: scanned.album,
                    albumArtist: scanned.albumArtist,
                    trackNumber: scanned.trackNumber,
                    discNumber: scanned.discNumber,
                    genre: scanned.genre,
                    year: scanned.year,
                    duration: scanned.duration,
                    artworkFile: scanned.artworkFile,
                    dateAdded: previous?.dateAdded ?? Date(),
                    fileModified: scanned.fileModified,
                    playCount: previous?.playCount ?? 0,
                    lastPlayed: previous?.lastPlayed,
                    isLiked: previous?.isLiked
                ))
            }
        }
        // The same file can sit in two added folders; keep one copy.
        var seen = Set<String>()
        tracks = updated.filter { seen.insert($0.path).inserted }
        let valid = Set(tracks.map(\.id))
        for index in playlists.indices {
            playlists[index].trackIDs.removeAll { !valid.contains($0) }
        }
        save()
    }

    // MARK: - Browsing

    func tracks(in source: MusicSource) -> [Song] {
        tracks.filter { $0.sourceID == source.id }
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    func tracks(in playlist: MusicPlaylist) -> [Song] {
        let byID = Dictionary(tracks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return playlist.trackIDs.compactMap { byID[$0] }
    }

    var albums: [MusicAlbum] {
        Dictionary(grouping: tracks, by: \.albumKey)
            .map { key, tracks in
                let sorted = tracks.sorted {
                    ($0.discNumber ?? 1, $0.trackNumber ?? Int.max, $0.title)
                        < ($1.discNumber ?? 1, $1.trackNumber ?? Int.max, $1.title)
                }
                let first = sorted[0]
                return MusicAlbum(
                    id: key,
                    title: first.album.isEmpty ? "Unknown Album" : first.album,
                    artist: first.displayAlbumArtist.isEmpty ? "Unknown Artist" : first.displayAlbumArtist,
                    year: sorted.compactMap(\.year).min(),
                    artworkFile: sorted.compactMap(\.artworkFile).first,
                    tracks: sorted
                )
            }
            .sorted { ($0.artist.lowercased(), $0.title.lowercased()) < ($1.artist.lowercased(), $1.title.lowercased()) }
    }

    /// Artist name → their tracks, A–Z.
    var artists: [(name: String, tracks: [Song])] {
        Dictionary(grouping: tracks) { $0.artist.isEmpty ? "Unknown Artist" : $0.artist }
            .map { (name: $0.key, tracks: $0.value.sorted { $0.title < $1.title }) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    // MARK: - Playlists

    @discardableResult
    func createPlaylist(named name: String, with trackIDs: [UUID] = []) -> MusicPlaylist {
        let playlist = MusicPlaylist(id: UUID(), name: name, trackIDs: trackIDs, dateCreated: Date())
        playlists.append(playlist)
        save()
        return playlist
    }

    func rename(_ playlist: MusicPlaylist, to name: String) {
        guard let index = playlists.firstIndex(where: { $0.id == playlist.id }) else { return }
        playlists[index].name = name
        save()
    }

    func delete(_ playlist: MusicPlaylist) {
        playlists.removeAll { $0.id == playlist.id }
        save()
    }

    func add(_ trackIDs: [UUID], to playlist: MusicPlaylist) {
        guard let index = playlists.firstIndex(where: { $0.id == playlist.id }) else { return }
        playlists[index].trackIDs += trackIDs.filter { !playlists[index].trackIDs.contains($0) }
        save()
    }

    func remove(_ trackIDs: Set<UUID>, from playlist: MusicPlaylist) {
        guard let index = playlists.firstIndex(where: { $0.id == playlist.id }) else { return }
        playlists[index].trackIDs.removeAll { trackIDs.contains($0) }
        save()
    }

    func move(in playlist: MusicPlaylist, from offsets: IndexSet, to destination: Int) {
        guard let index = playlists.firstIndex(where: { $0.id == playlist.id }) else { return }
        playlists[index].trackIDs.move(fromOffsets: offsets, toOffset: destination)
        save()
    }

    // MARK: - Liked, recent, most played

    var likedTracks: [Song] { tracks.filter(\.liked) }

    var recentlyPlayed: [Song] {
        Array(tracks.filter { $0.lastPlayed != nil }
            .sorted { $0.lastPlayed! > $1.lastPlayed! }
            .prefix(100))
    }

    var mostPlayed: [Song] {
        Array(tracks.filter { $0.playCount > 0 }
            .sorted { ($0.playCount, $0.lastPlayed ?? .distantPast) > ($1.playCount, $1.lastPlayed ?? .distantPast) }
            .prefix(100))
    }

    /// Likes the songs, or unlikes them if they're all liked already.
    func toggleLike(_ trackIDs: Set<UUID>) {
        let allLiked = tracks.filter { trackIDs.contains($0.id) }.allSatisfy(\.liked)
        for index in tracks.indices where trackIDs.contains(tracks[index].id) {
            tracks[index].isLiked = !allLiked
        }
        save()
    }

    func isLiked(_ trackID: UUID) -> Bool {
        tracks.first { $0.id == trackID }?.liked ?? false
    }

    func recordPlay(of trackID: UUID) {
        guard let index = tracks.firstIndex(where: { $0.id == trackID }) else { return }
        tracks[index].playCount += 1
        tracks[index].lastPlayed = Date()
        save()
    }
}
