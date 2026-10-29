import Foundation
import Observation
import AppKit
import UniformTypeIdentifiers

struct LibraryLocation: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var name: String
    var path: String
    var bookmarkData: Data?

    /// The stored path (kept current by `refreshBookmarkResolution`).
    /// Resolving the bookmark on every access was slow, especially for
    /// libraries on disconnected drives.
    var url: URL {
        URL(fileURLWithPath: path, isDirectory: true)
    }

    var isExternal: Bool {
        url.standardizedFileURL.path.hasPrefix("/Volumes/")
    }

    var isDefaultMoviesLibrary: Bool {
        let defaultURL = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VideoLibrary", isDirectory: true)
            .standardizedFileURL
        return url.standardizedFileURL.path == defaultURL.path
    }

    var isAvailable: Bool {
        let fileManager = FileManager.default
        let resolvedPath = url.standardizedFileURL.path
        var isDirectory = ObjCBool(false)
        if fileManager.fileExists(atPath: resolvedPath, isDirectory: &isDirectory) {
            return isDirectory.boolValue
        }

        // Missing local libraries can be created on first save. Missing external
        // paths usually mean the volume is disconnected, so do not create them.
        return !resolvedPath.hasPrefix("/Volumes/")
    }

    init(
        id: UUID = UUID(),
        name: String,
        url: URL,
        bookmarkData: Data? = nil
    ) {
        self.id = id
        self.name = name
        let standardizedURL = url.standardizedFileURL
        self.path = standardizedURL.path
        self.bookmarkData = bookmarkData ?? Self.makeBookmarkData(for: standardizedURL)
    }

    mutating func refreshBookmarkResolution() {
        guard let bookmarkData else {
            let currentURL = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
            var isDirectory = ObjCBool(false)
            if FileManager.default.fileExists(atPath: currentURL.path, isDirectory: &isDirectory),
               isDirectory.boolValue {
                self.bookmarkData = Self.makeBookmarkData(for: currentURL)
            }
            return
        }
        var isStale = false
        guard let resolvedURL = try? URL(
            resolvingBookmarkData: bookmarkData,
            options: [.withSecurityScope, .withoutUI, .withoutMounting],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else {
            return
        }

        let standardizedURL = resolvedURL.standardizedFileURL
        path = standardizedURL.path
        if isStale {
            self.bookmarkData = Self.makeBookmarkData(for: standardizedURL)
        }
    }

    private static func makeBookmarkData(for url: URL) -> Data? {
        try? url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }
}

enum SidebarFilter: String, CaseIterable, Identifiable, Sendable {
    case all, suggestions, music

    var id: String { rawValue }

    var label: String {
        switch self {
        case .all: "Videos"
        case .suggestions: "Suggestions"
        case .music: "Music"
        }
    }

    var systemImage: String {
        switch self {
        case .all: "film.stack"
        case .suggestions: "sparkles.tv"
        case .music: "music.note"
        }
    }
}

/// Music is off unless turned on in Settings › Music, and then only for the
/// libraries chosen there (stored as comma-separated library IDs).
enum MusicSettings {
    static let enabledKey = "musicEnabled"
    static let librariesKey = "musicLibraryIDs"
    /// "library" (default): each chosen library has its own music.
    /// "app": one music collection shared by every library.
    static let scopeKey = "musicScope"
    /// Hide the floating music bar whenever you leave the Music tab.
    static let autoHideBarKey = "musicBarAutoHide"

    static func isEnabled(for libraryID: UUID, enabled: Bool, libraryIDs: String, scope: String) -> Bool {
        guard enabled else { return false }
        return scope == "app" || libraryIDs.split(separator: ",").contains { $0 == libraryID.uuidString }
    }

    /// Where app-wide music lives (not tied to any drive).
    static var appWideDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VideoLibrary/Music", isDirectory: true)
    }

    static func libraryDirectory(_ library: LibraryLocation) -> URL {
        library.url.appendingPathComponent(".VideoLibrary", isDirectory: true)
    }

    static func hasMusic(in directory: URL) -> Bool {
        FileManager.default.fileExists(atPath: directory.appendingPathComponent("music.json").path)
    }

    /// Starts the app-wide collection from a library's music (index, playlists, cover art).
    static func copyIntoAppWide(from library: LibraryLocation) throws {
        let fm = FileManager.default
        let source = libraryDirectory(library)
        let destination = appWideDirectory
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        for name in ["music.json", "music-artwork"] {
            let from = source.appendingPathComponent(name)
            let to = destination.appendingPathComponent(name)
            guard fm.fileExists(atPath: from.path) else { continue }
            if fm.fileExists(atPath: to.path) { try fm.removeItem(at: to) }
            try fm.copyItem(at: from, to: to)
        }
        NotificationCenter.default.post(name: collectionReplaced, object: nil)
    }

    /// Posted when a collection's files are replaced on disk (reload it).
    static let collectionReplaced = Notification.Name("MusicCollectionReplaced")
}

enum VideoSortOption: String, CaseIterable, Identifiable, Sendable {
    case title
    case uploader
    case dateAdded
    case uploadDate
    case duration
    case fileSize

    var id: String { rawValue }

    var label: String {
        switch self {
        case .title: "Title"
        case .uploader: "Uploader"
        case .dateAdded: "Date Added"
        case .uploadDate: "Upload Date"
        case .duration: "Duration"
        case .fileSize: "File Size"
        }
    }
}

@Observable
@MainActor
final class LibraryStore {
    var items: [VideoItem] = []
    var activeTasks: [DownloadTask] = []
    var searchQuery: String = ""
    var selectedFilter: SidebarFilter = .all
    var selectedUploader: String?
    /// Remembered between launches.
    var videoSortOption: VideoSortOption = VideoSortOption(
        rawValue: UserDefaults.standard.string(forKey: "librarySortOption") ?? ""
    ) ?? .title {
        didSet { UserDefaults.standard.set(videoSortOption.rawValue, forKey: "librarySortOption") }
    }
    var videoSortAscending = UserDefaults.standard.object(forKey: "librarySortAscending") as? Bool ?? true {
        didSet { UserDefaults.standard.set(videoSortAscending, forKey: "librarySortAscending") }
    }
    var libraries: [LibraryLocation] = []
    var selectedLibraryID: UUID

    var filteredItems: [VideoItem] {
        items.filter { item in
            let matchesFilter: Bool = switch selectedFilter {
            case .all: item.status == .downloaded
            case .suggestions, .music: false
            }
            guard matchesFilter else { return false }
            if let selectedUploader, item.uploader != selectedUploader {
                return false
            }
            if searchQuery.isEmpty { return true }
            let q = searchQuery.lowercased()
            return item.title.lowercased().contains(q)
                || item.uploader.lowercased().contains(q)
                || item.tags.contains { $0.lowercased().contains(q) }
        }
    }

    var sortedFilteredItems: [VideoItem] {
        filteredItems.sorted { lhs, rhs in
            let result: ComparisonResult = switch videoSortOption {
            case .title:
                lhs.title.localizedStandardCompare(rhs.title)
            case .uploader:
                lhs.uploader.localizedStandardCompare(rhs.uploader)
            case .dateAdded:
                compare(lhs.dateAdded, rhs.dateAdded)
            case .uploadDate:
                compare(lhs.uploadDate, rhs.uploadDate)
            case .duration:
                compare(lhs.duration, rhs.duration)
            case .fileSize:
                compare(fileSize(for: lhs), fileSize(for: rhs))
            }

            if result == .orderedSame {
                return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
            }
            return videoSortAscending ? result == .orderedAscending : result == .orderedDescending
        }
    }

    var uploaders: [String] {
        Array(Set(items.map(\.uploader))).sorted()
    }

    var sortedLibraries: [LibraryLocation] {
        libraries
            .sorted { lhs, rhs in
                if lhs.isDefaultMoviesLibrary != rhs.isDefaultMoviesLibrary {
                    return lhs.isDefaultMoviesLibrary
                }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
    }

    func selectUploader(_ uploader: String?) {
        selectedUploader = uploader
        selectedFilter = .all
    }

    private func compare<T: Comparable>(_ lhs: T?, _ rhs: T?) -> ComparisonResult {
        switch (lhs, rhs) {
        case (.none, .none):
            return .orderedSame
        case (.none, .some):
            return .orderedDescending
        case (.some, .none):
            return .orderedAscending
        case let (.some(left), .some(right)):
            if left < right { return .orderedAscending }
            if left > right { return .orderedDescending }
            return .orderedSame
        }
    }

    private func compare<T: Comparable>(_ lhs: T, _ rhs: T) -> ComparisonResult {
        if lhs < rhs { return .orderedAscending }
        if lhs > rhs { return .orderedDescending }
        return .orderedSame
    }

    private func fileSize(for item: VideoItem) -> Int64 {
        if let videoFileSize = item.videoFileSize {
            return videoFileSize
        }
        guard let path = item.videoFilePath,
              let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attrs[.size] as? NSNumber else {
            return 0
        }
        return size.int64Value
    }

    private let legacyPersistenceURL: URL
    private let settingsURL: URL
    private var saveTask: Task<Void, Never>?

    private struct Settings: Codable {
        var libraries: [LibraryLocation]
        var selectedLibraryID: UUID
    }

    private struct DiskVideoInfo: Decodable {
        let id: String
        let title: String
        let uploader: String?
        let uploader_id: String?
        let upload_date: String?
        let duration: Double?
        let description: String?
        let tags: [String]?
        let view_count: Int?
        let like_count: Int?
    }

    init() {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        let dir = appSupport.appendingPathComponent("VideoLibrary")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        legacyPersistenceURL = dir.appendingPathComponent("library.json")
        settingsURL = dir.appendingPathComponent("settings.json")
        let defaultURL = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VideoLibrary", isDirectory: true)
        let defaultLibrary = LibraryLocation(name: "Movies", url: defaultURL)
        libraries = [defaultLibrary]
        selectedLibraryID = defaultLibrary.id
        loadSettings()
        migrateLegacyIndexIfNeeded()
        load()
    }

    var selectedLibrary: LibraryLocation {
        libraries.first(where: { $0.id == selectedLibraryID }) ?? libraries[0]
    }

    var selectedLibraryURL: URL {
        selectedLibrary.url
    }

    var selectedLibraryIsAvailable: Bool {
        selectedLibrary.isAvailable
    }

    var selectedLibraryUnavailableMessage: String {
        if selectedLibrary.isExternal {
            return "Connect the external drive for \(selectedLibrary.name), then the library will reload automatically."
        }
        return "The selected library folder is not available."
    }

    func load() {
        items = []
        refreshLibraryBookmarkResolution()
        guard selectedLibrary.isAvailable else { return }
        let persistenceURL = selectedLibraryPersistenceURL
        if FileManager.default.fileExists(atPath: persistenceURL.path) {
            do {
                let data = try Data(contentsOf: persistenceURL)
                items = try JSONDecoder().decode([VideoItem].self, from: data)
            } catch {
                // Start fresh if the file is corrupt
                items = []
            }
        }
        scanVideoQuality()
        reconcileFilesInBackground()
    }

    /// Finds moved files and downloads missing from library.json without
    /// blocking the window: the library shows at once, fixes land after.
    private func reconcileFilesInBackground() {
        let libraryID = selectedLibraryID
        let root = selectedLibrary.url
        let snapshot = items
        Task.detached(priority: .utility) {
            let repaired = Self.repairMissingFileReferences(in: snapshot, root: root)
            let indexed = Self.indexDownloadedFiles(existing: repaired ?? snapshot, root: root)
            guard repaired != nil || !indexed.isEmpty else { return }
            await MainActor.run {
                guard self.selectedLibraryID == libraryID else { return }
                if let repaired {
                    let fixes = Dictionary(repaired.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                    for index in self.items.indices {
                        if let fixed = fixes[self.items[index].id],
                           fixed.videoFilePath != self.items[index].videoFilePath {
                            self.items[index].videoFilePath = fixed.videoFilePath
                            self.items[index].thumbnailPath = fixed.thumbnailPath
                            self.items[index].subtitlePaths = fixed.subtitlePaths
                            self.items[index].infoJSONPath = fixed.infoJSONPath
                            self.items[index].videoFileSize = fixed.videoFileSize
                        }
                    }
                }
                let known = Set(self.items.map(\.ytdlpID))
                self.items += indexed.filter { !known.contains($0.ytdlpID) }
                self.save()
                self.scanVideoQuality()
            }
        }
    }

    // MARK: - Library size & quality

    /// Total size of the downloaded videos in the current library.
    var totalLibraryBytes: Int64 {
        items.filter { $0.status == .downloaded }.reduce(0) { $0 + fileSize(for: $1) }
    }

    /// Free space on the drive holding the current library.
    var freeSpaceBytes: Int64? {
        // "Important usage" includes purgeable space on the startup disk but
        // reports 0 for external drives, so take whichever is larger.
        let values = try? selectedLibraryURL.resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey
        ])
        let important = values?.volumeAvailableCapacityForImportantUsage ?? 0
        let plain = Int64(values?.volumeAvailableCapacity ?? 0)
        let best = max(important, plain)
        return best > 0 ? best : nil
    }

    /// Videos saved well below the chosen resolution (e.g. YouTube's 360p
    /// fallback), worth re-downloading.
    private(set) var lowQualityItemIDs: Set<UUID> = []
    /// "1080p", "4K"… per video, read from its .info.json.
    private(set) var resolutionLabels: [UUID: String] = [:]

    nonisolated static func resolutionLabel(shortSide: Int) -> String? {
        switch shortSide {
        case ..<1: nil
        case 2000...: "4K"
        case 1400...: "1440p"
        case 1000...: "1080p"
        case 700...: "720p"
        case 460...: "480p"
        case 340...: "360p"
        default: "\(shortSide)p"
        }
    }
    private(set) var isUpgradingQuality = false

    func scanVideoQuality() {
        let snapshot = items.filter { $0.status == .downloaded }
        let wanted = UserDefaults.standard.string(forKey: AppPreference.resolution)
            .flatMap(DownloadResolution.init(rawValue:))?.maxHeight ?? 1080
        Task.detached(priority: .utility) {
            var low = Set<UUID>()
            var labels: [UUID: String] = [:]
            for item in snapshot {
                guard let path = item.infoJSONPath,
                      let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                let width = json["width"] as? Int ?? 0
                let height = json["height"] as? Int ?? 0
                // Use the short side so vertical videos aren't flagged.
                let shortSide = min(width > 0 ? width : height, height)
                if let label = LibraryStore.resolutionLabel(shortSide: shortSide) {
                    labels[item.id] = label
                }
                if !item.ytdlpID.hasPrefix("local-"), json["format_id"] as? String == "18" || (shortSide > 0 && shortSide < min(wanted, 720) * 2 / 3) {
                    low.insert(item.id)
                }
            }
            let found = low
            let foundLabels = labels
            await MainActor.run {
                self.lowQualityItemIDs = found
                self.resolutionLabels = foundLabels
            }
        }
    }

    /// Re-downloads a video in the current quality setting, replacing the file
    /// but keeping its place, date added and watch position.
    @discardableResult
    func redownload(_ item: VideoItem) -> DownloadTask? {
        let defaults = UserDefaults.standard
        return startDownload(
            url: "https://www.youtube.com/watch?v=\(item.ytdlpID)",
            libraryID: selectedLibraryID,
            cookiesFromBrowser: .none,
            rememberCookies: false,
            allowsPlaylist: false,
            resolution: defaults.string(forKey: AppPreference.resolution).flatMap(DownloadResolution.init(rawValue:)) ?? .p1080,
            quality: defaults.string(forKey: AppPreference.quality).flatMap(DownloadQuality.init(rawValue:)) ?? .balanced,
            knownTitle: item.title,
            replacingExisting: true
        )
    }

    /// Re-downloads every low-quality video, two at a time.
    func upgradeLowQualityVideos() {
        let targets = items.filter { lowQualityItemIDs.contains($0.id) }
        guard !targets.isEmpty, !isUpgradingQuality else { return }
        isUpgradingQuality = true
        Task {
            var running: [DownloadTask] = []
            for item in targets {
                while running.count >= 2 {
                    try? await Task.sleep(for: .seconds(1))
                    running.removeAll { task in
                        switch task.phase {
                        case .complete, .failed: true
                        default: !self.activeTasks.contains { $0.id == task.id }
                        }
                    }
                }
                if let task = redownload(item) { running.append(task) }
            }
            while running.contains(where: { task in self.activeTasks.contains { $0.id == task.id } && task.canCancel }) {
                try? await Task.sleep(for: .seconds(1))
            }
            isUpgradingQuality = false
            scanVideoQuality()
        }
    }

    func sharingSnapshots() -> [SharedLibrarySnapshot] {
        refreshLibraryBookmarkResolution()
        if selectedLibrary.isAvailable {
            write(items, to: selectedLibraryPersistenceURL)
        }
        return sortedLibraries.compactMap { library in
            guard library.isAvailable,
                  let persistenceURL = libraryPersistenceURL(for: library.id) else { return nil }
            let libraryItems = library.id == selectedLibraryID
                ? items
                : loadItems(from: persistenceURL)
            return SharedLibrarySnapshot(library: library, items: libraryItems)
        }
    }

    func save() {
        saveTask?.cancel()
        guard selectedLibrary.isAvailable else { return }
        let persistenceURL = selectedLibraryPersistenceURL
        let items = items
        saveTask = Task {
            try? await Task.sleep(nanoseconds: 100_000_000)
            guard !Task.isCancelled else { return }
            do {
                let data = try JSONEncoder().encode(items)
                try FileManager.default.createDirectory(
                    at: persistenceURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try data.write(to: persistenceURL, options: .atomic)
            } catch {}
        }
    }

    func upsert(_ item: VideoItem) {
        upsert(item, in: selectedLibraryID)
    }

    func upsert(_ item: VideoItem, in libraryID: UUID) {
        guard libraryID != selectedLibraryID else {
            upsertInSelectedLibrary(item)
            return
        }
        guard let library = libraries.first(where: { $0.id == libraryID }),
              library.isAvailable,
              let persistenceURL = libraryPersistenceURL(for: libraryID) else { return }
        var libraryItems = loadItems(from: persistenceURL)
        if let idx = libraryItems.firstIndex(where: { $0.ytdlpID == item.ytdlpID }) {
            libraryItems[idx] = merged(item, into: libraryItems[idx])
        } else {
            libraryItems.append(item)
        }
        write(libraryItems, to: persistenceURL)
    }

    /// A re-download replaces the file but keeps the card's identity,
    /// date added and watch position.
    private func merged(_ item: VideoItem, into existing: VideoItem) -> VideoItem {
        var item = item
        item.id = existing.id
        item.dateAdded = existing.dateAdded
        item.watchProgress = existing.watchProgress
        return item
    }

    private func upsertInSelectedLibrary(_ item: VideoItem) {
        if let idx = items.firstIndex(where: { $0.ytdlpID == item.ytdlpID }) {
            if let old = items[idx].videoFilePath, old != item.videoFilePath,
               item.videoFilePath.map(FileManager.default.fileExists(atPath:)) == true,
               old.hasPrefix(selectedLibraryURL.path + "/") {
                try? FileManager.default.removeItem(atPath: old)
            }
            items[idx] = merged(item, into: items[idx])
            lowQualityItemIDs.remove(items[idx].id)
        } else {
            items.append(item)
        }
        save()
        scanVideoQuality()
    }

    func updateWatchProgress(for itemID: UUID, seconds: TimeInterval) {
        guard let index = items.firstIndex(where: { $0.id == itemID }) else { return }
        let progress = max(0, seconds)
        guard abs(items[index].watchProgress - progress) >= 1 else { return }
        items[index].watchProgress = progress
        save()
    }

    func selectLibrary(_ id: UUID) {
        guard id != selectedLibraryID,
              libraries.contains(where: { $0.id == id }) else { return }
        saveTask?.cancel()
        if selectedLibrary.isAvailable {
            write(items, to: selectedLibraryPersistenceURL)
        }
        selectedLibraryID = id
        selectedFilter = .all
        selectedUploader = nil
        saveSettings()
        load()
    }

    // MARK: - Importing local videos

    var importStatus: String?

    /// Lets the user pick video files and adds them to a library. Copying
    /// puts them in `{library}/Imported/`; otherwise they stay where they are.
    func chooseVideosToImport(into libraryID: UUID, copy: Bool) {
        guard let library = libraries.first(where: { $0.id == libraryID }), library.isAvailable else { return }
        let panel = NSOpenPanel()
        panel.title = "Import Videos into \(library.name)"
        panel.message = copy
            ? "The videos are copied into the library's Imported folder."
            : "The videos stay where they are; the library links to them."
        panel.prompt = "Import"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.movie, .video, .mpeg4Movie, .quickTimeMovie]
        panel.begin { [weak self] response in
            guard response == .OK else { return }
            let urls = panel.urls
            Task { @MainActor [weak self] in
                await self?.importVideos(urls, into: libraryID, copy: copy)
            }
        }
    }

    func importVideos(_ urls: [URL], into libraryID: UUID, copy: Bool) async {
        guard !urls.isEmpty, let library = libraries.first(where: { $0.id == libraryID }) else { return }
        importStatus = "Importing…"
        let root = library.url
        let result = await Task.detached(priority: .userInitiated) {
            await VideoImporter.importFiles(urls, into: root, copy: copy) { done, total in
                Task { @MainActor [weak self] in self?.importStatus = "Importing \(done) of \(total)…" }
            }
        }.value
        for item in result.items {
            upsert(item, in: libraryID)
        }
        var summary = "Imported \(result.items.count) video\(result.items.count == 1 ? "" : "s") into \(library.name)."
        if !result.unplayable.isEmpty {
            summary += " Skipped \(result.unplayable.count) macOS can't play (\(result.unplayable.prefix(3).joined(separator: ", "))). Convert them to MP4 or MOV first."
        }
        if !result.failed.isEmpty {
            summary += " Couldn't copy \(result.failed.joined(separator: ", "))."
        }
        importStatus = summary
    }

    func chooseLibraryFolder() {
        let panel = NSOpenPanel()
        panel.title = "Add Video Library"
        panel.message = "Choose a folder on this Mac or an external drive."
        panel.prompt = "Add Library"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor [weak self] in
                self?.addLibrary(url)
            }
        }
    }

    private func addLibrary(_ url: URL) {
        let standardizedURL = url.standardizedFileURL
        if let existing = libraries.first(where: { $0.path == standardizedURL.path }) {
            selectLibrary(existing.id)
            return
        }
        let name = standardizedURL.lastPathComponent.isEmpty
            ? standardizedURL.path
            : standardizedURL.lastPathComponent
        let location = LibraryLocation(name: name, url: standardizedURL)
        if selectedLibrary.isAvailable {
            write(items, to: selectedLibraryPersistenceURL)
        }
        libraries.append(location)
        selectedLibraryID = location.id
        selectedUploader = nil
        saveSettings()
        load()
    }

    func refreshLibraryAvailability() {
        refreshLibraryBookmarkResolution()
        if selectedLibrary.isAvailable {
            load()
        } else {
            items = []
        }
        saveSettings()
    }

    func cancelDownload(_ task: DownloadTask) {
        task.cancel()
    }

    /// "YouTube", "Nebula", or the site's host name.
    nonisolated static func siteName(for url: String) -> String {
        let host = URL(string: url)?.host?.lowercased() ?? ""
        if host.hasSuffix("youtube.com") || host == "youtu.be" { return "YouTube" }
        if host.hasSuffix("nebula.tv") || host.hasSuffix("nebula.app") { return "Nebula" }
        let trimmed = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        return trimmed.isEmpty ? "the website" : trimmed
    }

    @discardableResult
    func startDownload(
        url: String,
        libraryID requestedLibraryID: UUID? = nil,
        cookiesFromBrowser: BrowserCookieSource,
        rememberCookies: Bool,
        allowsPlaylist: Bool,
        resolution: DownloadResolution,
        quality: DownloadQuality,
        knownTitle: String? = nil,
        replacingExisting: Bool = false,
        toDownloadsFolder: Bool = false
    ) -> DownloadTask? {
        let trimmedURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedURL.isEmpty else { return nil }

        let task = DownloadTask()
        task.placeholderTitle = knownTitle
        task.sourceName = Self.siteName(for: trimmedURL)
        activeTasks.append(task)

        let targetLibrary = requestedLibraryID
            .flatMap { id in libraries.first(where: { $0.id == id }) }
            ?? selectedLibrary
        task.retry = { [weak self, weak task] in
            guard let self else { return }
            if let task { self.activeTasks.removeAll { $0.id == task.id } }
            // Pick up settings changed since the failure (e.g. the fix was
            // choosing a browser for cookies, or a different quality).
            let defaults = UserDefaults.standard
            self.startDownload(
                url: trimmedURL,
                libraryID: targetLibrary.id,
                cookiesFromBrowser: defaults.string(forKey: AppPreference.browserCookies)
                    .flatMap(BrowserCookieSource.init(rawValue:)) ?? cookiesFromBrowser,
                rememberCookies: defaults.object(forKey: AppPreference.rememberCookies) as? Bool ?? rememberCookies,
                allowsPlaylist: allowsPlaylist,
                resolution: defaults.string(forKey: AppPreference.resolution)
                    .flatMap(DownloadResolution.init(rawValue:)) ?? resolution,
                quality: defaults.string(forKey: AppPreference.quality)
                    .flatMap(DownloadQuality.init(rawValue:)) ?? quality,
                knownTitle: task?.videoItem?.title ?? knownTitle,
                replacingExisting: replacingExisting,
                toDownloadsFolder: toDownloadsFolder
            )
        }
        guard toDownloadsFolder || targetLibrary.isAvailable else {
            task.phase = .failed(DownloadFailure(
                title: "Library unavailable",
                explanation: unavailableMessage(for: targetLibrary),
                fix: .reconnectLibrary
            ))
            return task
        }

        let libraryID = targetLibrary.id
        // "Downloads Folder": yt-dlp works in a private temp folder and each
        // finished video is moved into ~/Downloads; nothing joins a library.
        let downloadsFolder = toDownloadsFolder
            ? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
            : nil
        let libraryURL = toDownloadsFolder
            ? FileManager.default.temporaryDirectory.appendingPathComponent("VideoLibrary-\(task.id.uuidString)", isDirectory: true)
            : targetLibrary.url
        let operation = Task {
            defer {
                if toDownloadsFolder { try? FileManager.default.removeItem(at: libraryURL) }
            }
            do {
                let service = try YtDlpService(outputRoot: libraryURL)
                var completedVideoCount = 0
                var itemsMissingSubtitles: [VideoItem] = []
                var outcome = DownloadOutcome()

                // Download without the YouTube sign-in first: YouTube withholds
                // HD stream URLs from some signed-in accounts (the "SABR-only"
                // experiment), leaving only a 360p fallback. The sign-in is
                // used only when YouTube actually requires it.
                let canUseSignIn = CookieCache.hasSavedCookies || cookiesFromBrowser != .none
                // Anonymous-first is a YouTube workaround; other sites (e.g.
                // Nebula) need the sign-in from the start.
                let host = URL(string: trimmedURL)?.host?.lowercased() ?? ""
                let isYouTube = host.hasSuffix("youtube.com") || host == "youtu.be"
                // If YouTube just turned a signed-out attempt away (its bot
                // check, common on VPN/datacenter networks), go straight to
                // the sign-in for a while instead of failing first every time.
                let anonymousBlocked = isYouTube && (Self.signedOutBlockedUntil.map { $0 > Date() } ?? false)
                var useSignIn = canUseSignIn && (!isYouTube || anonymousBlocked)
                // Signed-in YouTube downloads start with Safari's client (or
                // whichever client last got HD past SABR): the default
                // clients are SABR-limited to 360p for some accounts.
                var preferredClient = isYouTube && !allowsPlaylist ? Self.workingSABRClient() : nil
                var anonymousAttempts = 0
                var sabrLimited = false
                while true {
                    if !useSignIn { anonymousAttempts += 1 }
                    do {
                        try await self.runDownload(
                            task: task, service: service, url: trimmedURL, libraryID: libraryID,
                            saveToFolder: downloadsFolder,
                            cookiesFromBrowser: cookiesFromBrowser, rememberCookies: rememberCookies,
                            useSignIn: useSignIn, forceOverwrites: replacingExisting,
                            allowsPlaylist: allowsPlaylist, resolution: resolution, quality: quality,
                            playerClient: useSignIn ? preferredClient : nil,
                            abortOnLowSABR: isYouTube && !allowsPlaylist,
                            completedVideoCount: &completedVideoCount,
                            itemsMissingSubtitles: &itemsMissingSubtitles,
                            outcome: &outcome
                        )
                        break
                    } catch is SABRLimitedError {
                        // Stopped before downloading a 360p fallback file.
                        sabrLimited = true
                        break
                    } catch {
                        guard !(error is CancellationError), completedVideoCount == 0 else { throw error }
                        let failure = DownloadFailure.from(error)
                        if useSignIn, preferredClient != nil {
                            // The remembered client stopped working; forget it.
                            DebugLog.write("Remembered YouTube client \(preferredClient ?? "") failed; retrying with the default.", category: "sabr")
                            await MainActor.run { Self.sabrClientMemory = nil }
                            preferredClient = nil
                        } else if !useSignIn, failure.needsSignIn, canUseSignIn {
                            DebugLog.write("YouTube requires sign-in for this video; retrying with it.", category: "yt-dlp")
                            await MainActor.run { Self.signedOutBlockedUntil = Date().addingTimeInterval(30 * 60) }
                            useSignIn = true
                        } else if !useSignIn, !failure.needsSignIn, failure.canRetry, anonymousAttempts < 2 {
                            // 403s and rate limits are usually temporary.
                            DebugLog.write("Download hit a temporary error (\(failure.title)); retrying once.", category: "yt-dlp")
                            try await Task.sleep(for: .seconds(5))
                        } else {
                            throw error
                        }
                        await MainActor.run {
                            task.isRetryingWithSignIn = useSignIn
                            task.phase = .fetchingInfo
                            task.resetProgress()
                        }
                    }
                }
                // SABR: YouTube only offered SABR streams, so the regular
                // download would fall back to 360p. That's spotted as soon as
                // yt-dlp picks a format (before anything downloads); then
                // other clients are tried, then the optional SABR add-on, and
                // only if all of those fail is the 360p version downloaded.
                if sabrLimited || (isYouTube && !allowsPlaylist && outcome.sabrDetected && outcome.isLow(for: resolution)) {
                    let recovered = try await self.recoverFromSABR(
                        task: task, service: service, url: trimmedURL, libraryID: libraryID,
                        saveToFolder: downloadsFolder,
                        cookiesFromBrowser: cookiesFromBrowser, rememberCookies: rememberCookies,
                        useSignIn: useSignIn, resolution: resolution, quality: quality,
                        lowResult: sabrLimited ? nil : outcome,
                        alreadyTried: useSignIn ? preferredClient : nil
                    )
                    if let recovered {
                        outcome = recovered
                        completedVideoCount = max(completedVideoCount, 1)
                    } else if sabrLimited {
                        // Nothing better: save the 360p version after all.
                        await MainActor.run { task.stageNote = "Downloading the 360p version…" }
                        var lowOutcome = DownloadOutcome()
                        try await self.runDownload(
                            task: task, service: service, url: trimmedURL, libraryID: libraryID,
                            saveToFolder: downloadsFolder,
                            cookiesFromBrowser: cookiesFromBrowser, rememberCookies: rememberCookies,
                            useSignIn: useSignIn, forceOverwrites: replacingExisting,
                            allowsPlaylist: false, resolution: resolution, quality: quality,
                            completedVideoCount: &completedVideoCount,
                            itemsMissingSubtitles: &itemsMissingSubtitles,
                            outcome: &lowOutcome
                        )
                        outcome = lowOutcome
                    }
                }
                guard completedVideoCount > 0 else { throw YtDlpError.invalidOutput }
                if let savedFile = outcome.savedFile {
                    await MainActor.run { NSWorkspace.shared.activateFileViewerSelecting([savedFile]) }
                }

                await MainActor.run {
                    task.stageNote = nil
                    task.phase = .complete
                    // A quality notice stays in the panel until dismissed.
                    if task.qualityNotice == nil {
                        self.activeTasks.removeAll { $0.id == task.id }
                    }
                }

                // Captions are often rate-limited (HTTP 429) right after a video
                // download. The video is already saved; fetch captions later.
                if !allowsPlaylist, downloadsFolder == nil, let item = itemsMissingSubtitles.first {
                    await self.retrySubtitles(
                        for: item,
                        url: trimmedURL,
                        libraryID: libraryID,
                        service: service,
                        cookiesFromBrowser: cookiesFromBrowser,
                        rememberCookies: rememberCookies
                    )
                }
            } catch {
                await MainActor.run {
                    if error is CancellationError {
                        self.activeTasks.removeAll { $0.id == task.id }
                        return
                    }
                    let failure = DownloadFailure.from(error).forSite(task.sourceName)
                    DebugLog.write("Download failed: \(failure.title). \(failure.details)", category: "yt-dlp")
                    task.phase = .failed(failure)
                }
            }
        }
        task.operation = operation
        return task
    }

    /// One yt-dlp run: streams events into the task and saves finished items.
    private nonisolated func runDownload(
        task: DownloadTask,
        service: YtDlpService,
        url: String,
        libraryID: UUID,
        saveToFolder: URL?,
        cookiesFromBrowser: BrowserCookieSource,
        rememberCookies: Bool,
        useSignIn: Bool,
        forceOverwrites: Bool,
        allowsPlaylist: Bool,
        resolution: DownloadResolution,
        quality: DownloadQuality,
        playerClient: String? = nil,
        useSABR: Bool = false,
        abortOnLowSABR: Bool = false,
        completedVideoCount: inout Int,
        itemsMissingSubtitles: inout [VideoItem],
        outcome: inout DownloadOutcome
    ) async throws {
        var currentItem: VideoItem?
        var downloadedVideoPath: String?

        func finishCurrentItem(preferredVideoPath: String?) async throws {
            guard let item = currentItem else { return }

            let (videoPath, thumbnailPath, subtitlePaths, infoPath) = service.findDownloadedFiles(
                for: item,
                preferredVideoPath: preferredVideoPath
            )
            guard let videoPath else {
                if allowsPlaylist {
                    currentItem = nil
                    downloadedVideoPath = nil
                    return
                }
                throw YtDlpError.invalidOutput
            }

            outcome.shortSide = infoPath.flatMap(Self.shortSide(ofInfoJSONAt:))

            if let saveToFolder {
                // Just the video, named after its title, never overwriting.
                let ext = (videoPath as NSString).pathExtension
                let name = item.title
                    .replacingOccurrences(of: "/", with: "-")
                    .replacingOccurrences(of: ":", with: " -")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let destination = VideoSharingService.uniqueURL(
                    for: (name.isEmpty ? item.ytdlpID : name) + (ext.isEmpty ? "" : ".\(ext)"),
                    in: saveToFolder
                )
                let source = URL(fileURLWithPath: videoPath)
                do {
                    try FileManager.default.moveItem(at: source, to: destination)
                } catch {
                    try FileManager.default.copyItem(at: source, to: destination)
                }
                completedVideoCount += 1
                outcome.savedFile = destination
                let finalizedCount = completedVideoCount
                await MainActor.run { task.completedVideoCount = finalizedCount }
                currentItem = nil
                downloadedVideoPath = nil
                return
            }

            var completedItem = item
            completedItem.status = .downloaded
            completedItem.videoFilePath = videoPath
            completedItem.thumbnailPath = thumbnailPath
            completedItem.subtitlePaths = subtitlePaths
            completedItem.infoJSONPath = infoPath
            let attrs = try? FileManager.default.attributesOfItem(atPath: videoPath)
            completedItem.videoFileSize = (attrs?[.size] as? NSNumber)?.int64Value

            if subtitlePaths.isEmpty {
                itemsMissingSubtitles.append(completedItem)
            }
            completedVideoCount += 1
            let finalizedCount = completedVideoCount
            let finalizedItem = completedItem
            await MainActor.run {
                task.completedVideoCount = finalizedCount
                self.upsert(finalizedItem, in: libraryID)
            }

            currentItem = nil
            downloadedVideoPath = nil
        }

        for try await event in service.download(
            url: url,
            downloadID: task.id,
            cookiesFromBrowser: cookiesFromBrowser,
            rememberCookies: rememberCookies,
            useSignIn: useSignIn,
            forceOverwrites: forceOverwrites,
            allowsPlaylist: allowsPlaylist,
            resolution: resolution,
            quality: quality,
            playerClient: playerClient,
            useSABR: useSABR
        ) {
            switch event {
            case .info(var fetchedItem, let totalBytes, let shortSide):
                // SABR-limited and about to download the 360p fallback:
                // stop now so the fallbacks can run without a wasted download.
                if abortOnLowSABR, outcome.sabrDetected {
                    var preview = DownloadOutcome()
                    preview.shortSide = shortSide
                    if preview.isLow(for: resolution) {
                        DebugLog.write("SABR-limited: yt-dlp picked \(shortSide.map(String.init) ?? "?")p; stopping before the download.", category: "sabr")
                        throw SABRLimitedError()
                    }
                }
                try await finishCurrentItem(preferredVideoPath: downloadedVideoPath)
                fetchedItem.status = .downloading
                currentItem = fetchedItem
                downloadedVideoPath = nil
                let started = fetchedItem
                await MainActor.run {
                    task.isPlaylist = allowsPlaylist
                    task.videoItem = started
                    task.totalBytes = totalBytes
                    task.phase = .downloading
                }
            case .progress(let progress):
                await MainActor.run {
                    task.downloadedBytes = progress.downloaded
                    task.totalBytes = progress.total
                    task.speed = progress.speed
                }
            case .filePath(let path):
                downloadedVideoPath = path
                try await finishCurrentItem(preferredVideoPath: path)
            case .postProcessing:
                await MainActor.run {
                    task.phase = .postProcessing
                }
            case .sabrDetected:
                outcome.sabrDetected = true
            }
        }
        try await finishCurrentItem(preferredVideoPath: downloadedVideoPath)
    }

    /// Thrown to stop a run that's about to download YouTube's 360p fallback
    /// because only SABR streams were offered.
    struct SABRLimitedError: Error {}

    /// What one yt-dlp run produced, for the SABR fallback.
    struct DownloadOutcome: Sendable {
        var sabrDetected = false
        /// Short side of the downloaded video (720 for 1280×720), if known.
        var shortSide: Int?
        /// The file saved in Downloads Folder mode.
        var savedFile: URL?

        /// Below 480p when at least 720p was asked for: the 360p fallback.
        func isLow(for resolution: DownloadResolution) -> Bool {
            guard let shortSide else { return false }
            let wanted = resolution.maxHeight ?? 1080
            return shortSide < min(wanted, 720) * 2 / 3
        }
    }

    nonisolated static func shortSide(ofInfoJSONAt path: String) -> Int? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let width = json["width"] as? Int ?? 0
        let height = json["height"] as? Int ?? 0
        guard width > 0 || height > 0 else { return nil }
        return min(width > 0 ? width : height, height > 0 ? height : width)
    }

    /// YouTube clients that take a sign-in and often still get regular
    /// (non-SABR) HD streams: the TV app, and Safari's HLS streams.
    /// web_safari first: in testing it got 1080p (its HLS streams aren't
    /// SABR) while tv failed with "The page needs to be reloaded".
    nonisolated private static let sabrFallbackClients = ["web_safari", "tv"]

    /// Until when signed-out YouTube downloads are skipped (set when YouTube's
    /// bot check turned one away).
    static var signedOutBlockedUntil: Date?

    /// The fallback client that last got HD past SABR, and until when to
    /// use it first for signed-in YouTube downloads.
    static var sabrClientMemory: (client: String, until: Date)?

    static func workingSABRClient() -> String? {
        guard let memory = sabrClientMemory, memory.until > Date() else { return defaultSignedInClient }
        return memory.client
    }

    /// Used first for signed-in YouTube downloads when no other client is
    /// remembered.
    static let defaultSignedInClient = "web_safari"


    /// Runs the fallbacks after a SABR-limited low-quality download and
    /// returns the best outcome. In Downloads Folder mode, files from
    /// attempts that weren't kept are removed again.
    private nonisolated func recoverFromSABR(
        task: DownloadTask,
        service: YtDlpService,
        url: String,
        libraryID: UUID,
        saveToFolder: URL?,
        cookiesFromBrowser: BrowserCookieSource,
        rememberCookies: Bool,
        useSignIn: Bool,
        resolution: DownloadResolution,
        quality: DownloadQuality,
        lowResult: DownloadOutcome?,
        alreadyTried: String? = nil
    ) async throws -> DownloadOutcome? {
        var best = lowResult ?? DownloadOutcome()

        func attempt(client: String?, sabr: Bool, note: String) async throws -> Bool {
            await MainActor.run {
                task.stageNote = note
                task.phase = .fetchingInfo
                task.resetProgress()
            }
            var count = 0
            var missing: [VideoItem] = []
            var result = DownloadOutcome()
            do {
                try await self.runDownload(
                    task: task, service: service, url: url, libraryID: libraryID,
                    saveToFolder: saveToFolder,
                    cookiesFromBrowser: cookiesFromBrowser, rememberCookies: rememberCookies,
                    useSignIn: useSignIn, forceOverwrites: true,
                    allowsPlaylist: false, resolution: resolution, quality: quality,
                    playerClient: client, useSABR: sabr,
                    // A client that's also SABR-limited stops before downloading.
                    abortOnLowSABR: !sabr,
                    completedVideoCount: &count, itemsMissingSubtitles: &missing,
                    outcome: &result
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch is SABRLimitedError {
                DebugLog.write("SABR fallback (\(client ?? "default")) is SABR-limited too.", category: "sabr")
                return false
            } catch {
                DebugLog.write("SABR fallback (\(sabr ? "SABR add-on" : client ?? "default")) failed: \(error.localizedDescription)", category: "sabr")
                return false
            }
            let improved = !result.isLow(for: resolution)
                && (result.shortSide ?? 0) > (best.shortSide ?? 0)
            DebugLog.write("SABR fallback (\(sabr ? "SABR add-on" : client ?? "default")) got \(result.shortSide.map(String.init) ?? "?")p; \(improved ? "keeping it" : "not better")", category: "sabr")
            if improved {
                if let old = best.savedFile, old != result.savedFile { try? FileManager.default.removeItem(at: old) }
                best.shortSide = result.shortSide
                best.savedFile = result.savedFile ?? best.savedFile
                return true
            }
            if let extra = result.savedFile, extra != best.savedFile {
                try? FileManager.default.removeItem(at: extra)
            }
            return false
        }

        for client in Self.sabrFallbackClients where client != alreadyTried {
            if try await attempt(client: client, sabr: false, note: "Getting the HD version…") {
                await MainActor.run {
                    task.stageNote = nil
                    Self.sabrClientMemory = (client, Date().addingTimeInterval(6 * 60 * 60))
                }
                return best
            }
        }

        if SABRAddon.isInstalled {
            if try await attempt(client: nil, sabr: true, note: "Downloading HD with the SABR add-on…") {
                await MainActor.run { task.stageNote = nil }
                return best
            }
            await MainActor.run { task.qualityNotice = .sabrAddonFailed }
        } else {
            await MainActor.run { task.qualityNotice = .needsSABRAddon }
        }
        await MainActor.run { task.stageNote = nil }
        return lowResult
    }

    private func retrySubtitles(
        for item: VideoItem,
        url: String,
        libraryID: UUID,
        service: YtDlpService,
        cookiesFromBrowser: BrowserCookieSource,
        rememberCookies: Bool
    ) async {
        for delay in [45, 180, 600] {
            try? await Task.sleep(for: .seconds(delay))
            do {
                try await service.downloadSubtitlesOnly(
                    url: url,
                    cookiesFromBrowser: cookiesFromBrowser,
                    rememberCookies: rememberCookies
                )
            } catch {
                DebugLog.write(
                    "Subtitle retry for \(item.ytdlpID) failed: \(error.localizedDescription)",
                    category: "yt-dlp"
                )
            }
            let subtitles = service.findDownloadedFiles(
                for: item,
                preferredVideoPath: item.videoFilePath
            ).subtitles
            guard !subtitles.isEmpty else { continue }
            let libraryItems = libraryID == selectedLibraryID
                ? items
                : libraryPersistenceURL(for: libraryID).map(loadItems(from:)) ?? []
            guard var current = libraryItems.first(where: { $0.ytdlpID == item.ytdlpID }) else { return }
            current.subtitlePaths = subtitles
            upsert(current, in: libraryID)
            return
        }
    }

    private func unavailableMessage(for library: LibraryLocation) -> String {
        if library.isExternal {
            return "Connect the external drive for \(library.name), then try again."
        }
        return "The selected library folder is not available."
    }

    func promptRenameLibrary(_ library: LibraryLocation) {
        let alert = NSAlert()
        alert.messageText = "Rename Library"
        alert.informativeText = library.path
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")

        let input = NSTextField(string: library.name)
        input.frame = NSRect(x: 0, y: 0, width: 320, height: 24)
        alert.accessoryView = input

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        renameLibrary(library.id, to: input.stringValue)
    }

    func confirmRemoveLibrary(_ library: LibraryLocation) {
        guard libraries.count > 1 else {
            let alert = NSAlert()
            alert.messageText = "Cannot Remove Only Library"
            alert.informativeText = "Add another library folder before removing this one."
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }

        let alert = NSAlert()
        alert.messageText = "Remove \(library.name)?"
        alert.informativeText = "This removes the saved library entry from VideoLibrary. It does not delete the folder, videos, or .VideoLibrary index on disk."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        removeLibrary(library.id)
    }

    func renameLibrary(_ id: UUID, to name: String) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty,
              let index = libraries.firstIndex(where: { $0.id == id }) else { return }
        libraries[index].name = trimmedName
        saveSettings()
    }

    func removeLibrary(_ id: UUID) {
        guard libraries.count > 1,
              let index = libraries.firstIndex(where: { $0.id == id }) else { return }

        let wasSelected = selectedLibraryID == id
        if selectedLibrary.isAvailable {
            write(items, to: selectedLibraryPersistenceURL)
        }

        libraries.remove(at: index)
        if wasSelected {
            selectedLibraryID = libraries.first?.id ?? selectedLibraryID
            selectedUploader = nil
            load()
        }
        saveSettings()
    }

    func librarySystemImage(for library: LibraryLocation) -> String {
        if !library.isAvailable {
            return "externaldrive.badge.exclamationmark"
        }
        if library.isDefaultMoviesLibrary {
            return "film.stack"
        }
        return library.isExternal ? "externaldrive" : "folder"
    }

    func libraryStatusText(for library: LibraryLocation) -> String {
        if !library.isAvailable {
            return library.isExternal ? "Disconnected" : "Unavailable"
        }
        return library.isExternal ? "External drive" : "Local folder"
    }

    private func loadSettings() {
        guard let data = try? Data(contentsOf: settingsURL),
              let settings = try? JSONDecoder().decode(Settings.self, from: data),
              !settings.libraries.isEmpty else { return }
        libraries = settings.libraries
        refreshLibraryBookmarkResolution()
        selectedLibraryID = libraries.contains(where: { $0.id == settings.selectedLibraryID })
            ? settings.selectedLibraryID
            : libraries[0].id
    }

    private func saveSettings() {
        let settings = Settings(libraries: libraries, selectedLibraryID: selectedLibraryID)
        guard let data = try? JSONEncoder().encode(settings) else { return }
        try? data.write(to: settingsURL, options: .atomic)
    }

    private var selectedLibraryPersistenceURL: URL {
        selectedLibrary.url
            .appendingPathComponent(".VideoLibrary", isDirectory: true)
            .appendingPathComponent("library.json")
    }

    private func libraryPersistenceURL(for id: UUID) -> URL? {
        libraries.first(where: { $0.id == id })?.url
            .appendingPathComponent(".VideoLibrary", isDirectory: true)
            .appendingPathComponent("library.json")
    }

    private func loadItems(from url: URL) -> [VideoItem] {
        guard let data = try? Data(contentsOf: url),
              let items = try? JSONDecoder().decode([VideoItem].self, from: data) else { return [] }
        return items
    }

    private func write(_ items: [VideoItem], to url: URL) {
        guard canWriteLibraryIndex(at: url) else { return }
        guard let data = try? JSONEncoder().encode(items) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: url, options: .atomic)
    }

    private func canWriteLibraryIndex(at url: URL) -> Bool {
        let libraryRoot = url
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .standardizedFileURL
        let rootPath = libraryRoot.path

        if rootPath.hasPrefix("/Volumes/") {
            var isDirectory = ObjCBool(false)
            return FileManager.default.fileExists(atPath: rootPath, isDirectory: &isDirectory)
                && isDirectory.boolValue
        }
        return true
    }

    private func refreshLibraryBookmarkResolution() {
        for index in libraries.indices {
            libraries[index].refreshBookmarkResolution()
        }
    }

    /// Returns updated items if any downloaded video's file had moved.
    nonisolated private static func repairMissingFileReferences(in items: [VideoItem], root: URL) -> [VideoItem]? {
        func missing(_ item: VideoItem) -> Bool {
            item.status == .downloaded
                && !item.ytdlpID.hasPrefix("local-")
                && (item.videoFilePath == nil || !FileManager.default.fileExists(atPath: item.videoFilePath ?? ""))
        }
        guard items.contains(where: missing) else { return nil }
        var repaired = items
        var didRepair = false
        for index in repaired.indices where missing(repaired[index]) {
            let references = DownloadedFileLocator.find(in: root, for: repaired[index])
            guard let videoPath = references.video else { continue }
            repaired[index].videoFilePath = videoPath
            repaired[index].thumbnailPath = references.thumbnail
            repaired[index].subtitlePaths = references.subtitles
            repaired[index].infoJSONPath = references.infoJSON
            let attrs = try? FileManager.default.attributesOfItem(atPath: videoPath)
            repaired[index].videoFileSize = (attrs?[.size] as? NSNumber)?.int64Value
            didRepair = true
        }
        return didRepair ? repaired : nil
    }

    /// Downloads on disk (found by their .info.json) that library.json doesn't know about.
    nonisolated private static func indexDownloadedFiles(existing items: [VideoItem], root: URL) -> [VideoItem] {
        var existingIDs = Set(items.map(\.ytdlpID))
        var found: [VideoItem] = []
        for infoJSONPath in DownloadedFileLocator.infoJSONFiles(in: root) {
            guard let item = videoItem(fromInfoJSONPath: infoJSONPath),
                  !existingIDs.contains(item.ytdlpID) else { continue }
            let references = DownloadedFileLocator.references(nearInfoJSONPath: infoJSONPath)
            guard let videoPath = references.video else { continue }
            var completedItem = item
            completedItem.videoFilePath = videoPath
            completedItem.thumbnailPath = references.thumbnail
            completedItem.subtitlePaths = references.subtitles
            completedItem.infoJSONPath = references.infoJSON ?? infoJSONPath
            let attrs = try? FileManager.default.attributesOfItem(atPath: videoPath)
            completedItem.videoFileSize = (attrs?[.size] as? NSNumber)?.int64Value
            found.append(completedItem)
            existingIDs.insert(completedItem.ytdlpID)
        }
        return found
    }

    nonisolated private static func videoItem(fromInfoJSONPath path: String) -> VideoItem? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let raw = try? JSONDecoder().decode(DiskVideoInfo.self, from: data) else {
            return nil
        }

        var uploadDate: Date?
        if let dateStr = raw.upload_date, dateStr.count == 8 {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyyMMdd"
            uploadDate = formatter.date(from: dateStr)
        }

        return VideoItem(
            ytdlpID: raw.id,
            title: raw.title,
            uploader: raw.uploader ?? "Unknown",
            uploaderID: raw.uploader_id ?? raw.id,
            uploadDate: uploadDate,
            duration: raw.duration ?? 0,
            description: raw.description ?? "",
            tags: raw.tags ?? [],
            viewCount: raw.view_count,
            likeCount: raw.like_count,
            status: .downloaded
        )
    }

    private func migrateLegacyIndexIfNeeded() {
        let legacyItems = loadItems(from: legacyPersistenceURL)
        guard !legacyItems.isEmpty, let defaultLibrary = libraries.first else { return }

        var itemsByLibrary: [UUID: [VideoItem]] = [:]
        for item in legacyItems {
            let libraryID = libraryID(containing: item) ?? defaultLibrary.id
            itemsByLibrary[libraryID, default: []].append(item)
        }

        for (libraryID, items) in itemsByLibrary {
            guard let url = libraryPersistenceURL(for: libraryID),
                  !FileManager.default.fileExists(atPath: url.path) else { continue }
            write(items, to: url)
        }
    }

    private func libraryID(containing item: VideoItem) -> UUID? {
        guard let path = item.videoFilePath else { return nil }
        let standardizedPath = URL(fileURLWithPath: path).standardizedFileURL.path
        return libraries
            .sorted { $0.path.count > $1.path.count }
            .first { library in
                standardizedPath == library.path
                    || standardizedPath.hasPrefix(library.path + "/")
            }?
            .id
    }

    func remove(_ item: VideoItem) {
        remove([item])
    }

    /// Asks before deleting several videos (or a whole uploader) at once.
    /// Returns whether they were deleted.
    @discardableResult
    func confirmRemove(_ removed: [VideoItem], uploader: String? = nil) -> Bool {
        guard !removed.isEmpty else { return false }
        let count = removed.count == 1 ? "1 video" : "\(removed.count) videos"
        let alert = NSAlert()
        alert.messageText = uploader.map { "Delete all videos by \($0)?" } ?? "Delete \(count)?"
        alert.informativeText = (uploader == nil ? "" : "This deletes \(count) and the uploader's folder. ")
            + "The video files, thumbnails and captions are deleted from disk. This can't be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.buttons.first?.hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        remove(removed)
        return true
    }

    /// Every downloaded video by one uploader.
    func items(byUploader uploader: String) -> [VideoItem] {
        items.filter { $0.uploader == uploader }
    }

    /// Deletes videos and their files, then any uploader folder they leave
    /// empty (so deleting a whole channel leaves nothing behind in Finder).
    func remove(_ removed: [VideoItem]) {
        guard !removed.isEmpty else { return }
        let ids = Set(removed.map(\.id))
        items.removeAll { ids.contains($0.id) }
        if let selectedUploader, !items.contains(where: { $0.uploader == selectedUploader }) {
            self.selectedUploader = nil
        }
        save()

        // Only delete files inside this library's folder, so an edited or
        // corrupted library.json can't point "Delete" at other files.
        let libraryRoot = selectedLibraryURL.resolvingSymlinksInPath().standardizedFileURL.path
        let root = libraryRoot + "/"
        Task.detached {
            let fm = FileManager.default
            var folders = Set<String>()
            for item in removed {
                // An imported video that was linked rather than copied is the
                // user's own file: forget it, but don't delete it.
                let keepsVideo = item.ytdlpID.hasPrefix("local-")
                    && item.videoFilePath?.contains("/Imported/") != true
                let paths = [keepsVideo ? nil : item.videoFilePath, item.thumbnailPath, item.infoJSONPath].compactMap { $0 }
                    + Array(item.subtitlePaths.values)
                for path in paths {
                    let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
                    guard resolved.hasPrefix(root) else {
                        DebugLog.write("Refused to delete file outside the library: \(path)", category: "security")
                        continue
                    }
                    try? fm.removeItem(atPath: resolved)
                    folders.insert((resolved as NSString).deletingLastPathComponent)
                }
            }
            // Deepest first, so a nested folder goes before its parent.
            for folder in folders.sorted(by: { $0.count > $1.count }) {
                Self.removeFolderIfEmpty(folder, libraryRoot: libraryRoot)
            }
        }
    }

    /// Removes a folder inside the library that holds nothing but Finder or
    /// unfinished-download leftovers. Never the library folder itself or its
    /// `.VideoLibrary` data.
    nonisolated private static func removeFolderIfEmpty(_ folder: String, libraryRoot: String) {
        guard folder.hasPrefix(libraryRoot + "/"),
              !folder.contains("/.VideoLibrary") else { return }
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(atPath: folder) else { return }
        let leftovers: Set<String> = ["part", "ytdl"]
        let onlyJunk = contents.allSatisfy { name in
            name == ".DS_Store" || leftovers.contains((name as NSString).pathExtension.lowercased())
        }
        guard onlyJunk else { return }
        try? fm.removeItem(atPath: folder)
    }

    func move(_ item: VideoItem, to destinationLibraryID: UUID) {
        guard destinationLibraryID != selectedLibraryID,
              let destinationLibrary = libraries.first(where: { $0.id == destinationLibraryID }),
              destinationLibrary.isAvailable,
              let destinationPersistenceURL = libraryPersistenceURL(for: destinationLibraryID),
              let sourceVideoPath = item.videoFilePath,
              FileManager.default.fileExists(atPath: sourceVideoPath) else { return }

        let sourceLibrary = selectedLibrary
        var movedItem = item
        let fm = FileManager.default
        let sourceVideoURL = URL(fileURLWithPath: sourceVideoPath)
        let destinationDirectory = destinationDirectoryForMove(
            item: item,
            sourceFileURL: sourceVideoURL,
            sourceLibrary: sourceLibrary,
            destinationLibrary: destinationLibrary
        )

        do {
            try fm.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)

            movedItem.videoFilePath = try moveFileIfNeeded(
                at: sourceVideoPath,
                toDirectory: destinationDirectory
            )
            movedItem.thumbnailPath = try moveFileIfNeeded(
                at: item.thumbnailPath,
                toDirectory: destinationDirectory
            )
            var movedSubtitlePaths: [String: String] = [:]
            for (language, path) in item.subtitlePaths {
                movedSubtitlePaths[language] = try moveFileIfNeeded(
                    at: path,
                    toDirectory: destinationDirectory
                )
            }
            movedItem.subtitlePaths = movedSubtitlePaths
            movedItem.infoJSONPath = try moveFileIfNeeded(
                at: item.infoJSONPath,
                toDirectory: destinationDirectory
            )
            if let videoPath = movedItem.videoFilePath {
                let attrs = try? fm.attributesOfItem(atPath: videoPath)
                movedItem.videoFileSize = (attrs?[.size] as? NSNumber)?.int64Value
            }

            items.removeAll { $0.id == item.id }
            save()

            var destinationItems = loadItems(from: destinationPersistenceURL)
            destinationItems.removeAll {
                $0.id == movedItem.id || $0.ytdlpID == movedItem.ytdlpID
            }
            destinationItems.append(movedItem)
            write(destinationItems, to: destinationPersistenceURL)
        } catch {
            showMoveFailedAlert(item: item, destinationLibrary: destinationLibrary, error: error)
        }
    }

    private func destinationDirectoryForMove(
        item: VideoItem,
        sourceFileURL: URL,
        sourceLibrary: LibraryLocation,
        destinationLibrary: LibraryLocation
    ) -> URL {
        let sourceRoot = sourceLibrary.url.standardizedFileURL.path
        let sourceParent = sourceFileURL
            .deletingLastPathComponent()
            .standardizedFileURL
        let sourceParentPath = sourceParent.path

        if sourceParentPath != sourceRoot,
           sourceParentPath.hasPrefix(sourceRoot + "/") {
            let relativeFolder = String(sourceParentPath.dropFirst(sourceRoot.count + 1))
            return destinationLibrary.url.appendingPathComponent(relativeFolder, isDirectory: true)
        }

        return destinationLibrary.url
            .appendingPathComponent(sanitizedPathComponent(item.uploader), isDirectory: true)
    }

    private func moveFileIfNeeded(
        at path: String?,
        toDirectory destinationDirectory: URL
    ) throws -> String? {
        guard let path,
              FileManager.default.fileExists(atPath: path) else { return nil }
        let sourceURL = URL(fileURLWithPath: path)
        let destinationURL = uniqueDestinationURL(
            for: sourceURL.lastPathComponent,
            in: destinationDirectory
        )
        try FileManager.default.moveItem(at: sourceURL, to: destinationURL)
        return destinationURL.standardizedFileURL.path
    }

    private func uniqueDestinationURL(for fileName: String, in directory: URL) -> URL {
        let originalURL = directory.appendingPathComponent(fileName, isDirectory: false)
        guard FileManager.default.fileExists(atPath: originalURL.path) else {
            return originalURL
        }

        let base = originalURL.deletingPathExtension().lastPathComponent
        let ext = originalURL.pathExtension
        for counter in 2...999 {
            let candidateName = ext.isEmpty
                ? "\(base) \(counter)"
                : "\(base) \(counter).\(ext)"
            let candidateURL = directory.appendingPathComponent(candidateName, isDirectory: false)
            if !FileManager.default.fileExists(atPath: candidateURL.path) {
                return candidateURL
            }
        }

        return directory.appendingPathComponent(UUID().uuidString + "-" + fileName)
    }

    private func sanitizedPathComponent(_ value: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:")
            .union(.controlCharacters)
            .union(.newlines)
        let sanitized = value
            .components(separatedBy: invalid)
            .joined(separator: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return sanitized.isEmpty ? "Unknown" : sanitized
    }

    private func showMoveFailedAlert(
        item: VideoItem,
        destinationLibrary: LibraryLocation,
        error: Error
    ) {
        let alert = NSAlert()
        alert.messageText = "Could Not Move Video"
        alert.informativeText = "VideoLibrary could not move \"\(item.title)\" to \(destinationLibrary.name): \(error.localizedDescription)"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
