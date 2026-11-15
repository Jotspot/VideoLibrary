import SwiftUI
import AppKit

struct AddVideoSheet: View {
    @Environment(LibraryStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openSettings) private var openSettings

    @State private var urlText = ""
    @State private var downloadPlaylist = false
    @State private var libraryID: UUID?
    @State private var tools = ToolsService.shared
    /// The Resolution picker's choice: a DownloadResolution raw value, or
    /// `mp3Tag` for audio only. Starts at the default from Settings.
    @State private var format = AddVideoSheet.defaultFormat
    /// Where MP3s for Music go: nil is the default "Downloaded Music" folder.
    @State private var musicFolder: URL?
    @State private var playlistChoice = PlaylistChoice.none
    @State private var newPlaylistName = ""
    /// The Music collection's folders and playlists, read once per library.
    @State private var folderChoices: [(folder: URL, name: String)] = []
    @State private var playlistChoices: [MusicPlaylist] = []
    @AppStorage("audioDownloadShowsInVideos") private var audioShowsInVideos = true
    @AppStorage("audioDownloadAddsToMusic") private var audioAddsToMusic = true
    @AppStorage(AppPreference.resolution) private var resolutionRaw = DownloadResolution.p1080.rawValue
    @AppStorage(AppPreference.quality) private var qualityRaw = DownloadQuality.balanced.rawValue
    @AppStorage(AppPreference.browserCookies) private var browserCookiesRaw = BrowserCookieSource.none.rawValue
    @AppStorage(AppPreference.rememberCookies) private var rememberCookies = false

    init(initialURL: String = "") {
        _urlText = State(initialValue: initialURL)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Label("Add Video", systemImage: "arrow.down.to.line.circle.fill")
                    .font(.title2.bold())
                Spacer()
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    TextField("Paste a YouTube link", text: $urlText)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                        .onSubmit(startDownload)
                    Button("Paste") {
                        if let text = NSPasteboard.general.string(forType: .string) {
                            urlText = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        }
                    }
                }
                if let problem = urlProblem {
                    Text(problem).font(.caption).foregroundStyle(.orange)
                }
                if let playlistProblem {
                    Text(playlistProblem).font(.caption).foregroundStyle(.orange)
                }
                if looksLikePlaylist {
                    Toggle("Download the whole playlist", isOn: $downloadPlaylist)
                        .toggleStyle(.checkbox)
                    Text(downloadPlaylist
                         ? (audioOnly ? "Every video in the playlist is saved as its own MP3."
                                      : "Every video in the playlist becomes its own library card.")
                         : "Only the video in this link will be downloaded.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Form {
                Picker("Save to", selection: libraryBinding) {
                    ForEach(store.sortedLibraries) { library in
                        Text(library.isAvailable ? library.name : "\(library.name) (unavailable)")
                            .tag(library.id)
                    }
                    Divider()
                    Text("Downloads Folder").tag(Self.downloadsFolderTag)
                }
                if savesToDownloads {
                    Text(audioOnly
                         ? "Saves just the MP3 file to your Downloads folder. It won't be added to a library."
                         : "Saves just the video file to your Downloads folder. It won't be added to a library.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Picker("Resolution", selection: $format) {
                    ForEach(DownloadResolution.allCases) { Text($0.label).tag($0.rawValue) }
                    Divider()
                    Text("Audio Only (MP3)").tag(Self.mp3Tag)
                }
                if !audioOnly {
                    Picker("Quality", selection: $qualityRaw) {
                        ForEach(DownloadQuality.allCases) { Text($0.label).tag($0.rawValue) }
                    }
                }
                if audioOnly, !savesToDownloads {
                    LabeledContent("Add to") {
                        VStack(alignment: .leading, spacing: 4) {
                            Toggle("Videos", isOn: $audioShowsInVideos)
                            Toggle("Music", isOn: musicBinding)
                                .disabled(musicDestination == nil)
                        }
                        .toggleStyle(.checkbox)
                    }
                    Text(audioDestinationNote)
                        .font(.caption)
                        .foregroundStyle(musicDestinationMissing ? .orange : .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if addsToMusic {
                        musicPickers
                    }
                }
                LabeledContent("YouTube sign-in") {
                    HStack(spacing: 6) {
                        Text(cookieSummary).foregroundStyle(.secondary)
                        Button("Change…") { openSettings(tab: .downloads) }
                            .buttonStyle(.link)
                    }
                }
            }
            .formStyle(.columns)

            if !tools.missingTools.isEmpty, tools.lastChecked != nil {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Missing: \(tools.missingTools.map(\.name).joined(separator: ", "))")
                            .font(.callout.weight(.semibold))
                        Text("Downloads need these free tools. Install them with one click.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button(tools.isUpdating ? "Installing…" : "Install Tools") {
                            Task { await tools.updateAll() }
                        }
                        .disabled(tools.isUpdating)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.orange.opacity(0.1), in: .rect(cornerRadius: 10))
            }

            HStack {
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Download", systemImage: "arrow.down.circle", action: startDownload)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canDownload)
            }
        }
        .padding(24)
        .frame(width: 520)
        .task(id: musicDestination?.collectionDirectory) {
            // A different library has its own folders and playlists.
            folderChoices = musicDestination?.folderChoices() ?? []
            playlistChoices = musicDestination?.playlistChoices() ?? []
            if let musicFolder, !folderChoices.contains(where: { $0.folder == musicFolder }) { self.musicFolder = nil }
            if case .existing(let id) = playlistChoice, !playlistChoices.contains(where: { $0.id == id }) {
                playlistChoice = .none
            }
        }
        .task {
            if urlText.isEmpty,
               let clip = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
               URL(string: clip)?.host != nil {
                urlText = clip
            }
            await tools.refresh()
        }
    }

    @ViewBuilder
    private var musicPickers: some View {
        Picker("Music folder", selection: $musicFolder) {
            ForEach(Array(folderChoices.enumerated()), id: \.offset) { index, choice in
                Text(index == 0 ? "\(choice.name) (default)" : choice.name)
                    .tag(index == 0 ? nil : Optional(choice.folder))
            }
        }
        Picker("Playlist", selection: $playlistChoice) {
            Text("None").tag(PlaylistChoice.none)
            if !playlistChoices.isEmpty {
                Divider()
                ForEach(playlistChoices) { Text($0.name).tag(PlaylistChoice.existing($0.id)) }
            }
            Divider()
            Text("New Playlist…").tag(PlaylistChoice.new)
        }
        if playlistChoice == .new {
            TextField("Playlist name", text: $newPlaylistName, prompt: Text("New playlist name"))
        }
    }

    /// The Resolution picker's tag for "Audio Only (MP3)".
    static let mp3Tag = "mp3"

    /// The Resolution choice Add Video starts with, from Settings.
    static var defaultFormat: String {
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: AppPreference.defaultsToAudio) { return mp3Tag }
        return defaults.string(forKey: AppPreference.resolution) ?? DownloadResolution.p1080.rawValue
    }

    private var audioOnly: Bool { format == Self.mp3Tag }

    private enum PlaylistChoice: Hashable {
        case none, new, existing(UUID)
    }

    /// The Music destination with the chosen folder and playlist.
    private var chosenMusicDestination: MusicDownloadDestination? {
        guard addsToMusic, var destination = musicDestination else { return nil }
        if let musicFolder { destination.folder = musicFolder }
        switch playlistChoice {
        case .none: destination.playlist = nil
        case .existing(let id): destination.playlist = .existing(id)
        case .new:
            let name = newPlaylistName.trimmingCharacters(in: .whitespacesAndNewlines)
            destination.playlist = name.isEmpty ? nil : .new(name)
        }
        return destination
    }

    private var trimmedURL: String {
        urlText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var urlProblem: String? {
        guard !trimmedURL.isEmpty else { return nil }
        guard let url = URL(string: trimmedURL), let scheme = url.scheme, ["http", "https"].contains(scheme),
              url.host != nil else {
            return "That doesn't look like a web link. Copy the address from your browser and paste it here."
        }
        return nil
    }

    /// A YouTube playlist ID ("PL" + 16 or 32 characters) that's too short
    /// to be real: the link was cut off when it was copied.
    private var playlistProblem: String? {
        guard let components = URLComponents(string: trimmedURL),
              let list = components.queryItems?.first(where: { $0.name == "list" })?.value,
              list.hasPrefix("PL"), list.count < 18 else { return nil }
        return "This playlist link looks cut off (its playlist ID is too short), so YouTube won't find the playlist. Open the playlist on YouTube and copy the full address."
    }

    private var looksLikePlaylist: Bool {
        trimmedURL.contains("list=") || trimmedURL.contains("/playlist")
    }

    private var selectedLibrary: LibraryLocation {
        store.libraries.first { $0.id == libraryID } ?? store.selectedLibrary
    }

    /// Picker tag for "Downloads Folder" (not a library).
    private static let downloadsFolderTag = UUID(uuidString: "00000000-0000-0000-0000-00000000D0D0")!

    private var savesToDownloads: Bool { libraryID == Self.downloadsFolderTag }

    private var libraryBinding: Binding<UUID> {
        Binding(get: { savesToDownloads ? Self.downloadsFolderTag : selectedLibrary.id },
                set: { libraryID = $0 })
    }

    private var musicDestination: MusicDownloadDestination? {
        MusicSettings.downloadDestination(for: selectedLibrary)
    }

    private var musicDestinationMissing: Bool { musicDestination == nil && !audioShowsInVideos }

    private var musicBinding: Binding<Bool> {
        Binding(get: { musicDestination != nil && audioAddsToMusic },
                set: { audioAddsToMusic = $0 })
    }

    /// Where an MP3 download goes, as chosen.
    private var addsToMusic: Bool { audioOnly && !savesToDownloads && musicDestination != nil && audioAddsToMusic }
    private var showsInVideos: Bool { !audioOnly || savesToDownloads || audioShowsInVideos }

    private var audioDestinationNote: String {
        guard let musicDestination else {
            return "To add songs to Music, turn on Music for \(selectedLibrary.name) in Settings › Music."
        }
        let folder = (musicFolder ?? musicDestination.folder).lastPathComponent
        switch (audioShowsInVideos, audioAddsToMusic) {
        case (true, true): return "Shows up with your videos and as a song in Music (saved in \(folder))."
        case (false, true): return "Added to Music only, saved in the \(folder) folder."
        case (true, false): return "Shows up with your videos; plays like a video without a picture."
        case (false, false): return "Choose Videos, Music or both."
        }
    }

    private var canDownload: Bool {
        guard !trimmedURL.isEmpty, urlProblem == nil else { return false }
        if savesToDownloads { return true }
        if audioOnly {
            guard showsInVideos || addsToMusic else { return false }
            // Music-only with app-wide music doesn't need the library's drive.
            if !showsInVideos { return true }
        }
        if addsToMusic, playlistChoice == .new,
           newPlaylistName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return false }
        return selectedLibrary.isAvailable
    }

    private var cookieSummary: String {
        let source = BrowserCookieSource(rawValue: browserCookiesRaw) ?? .none
        if CookieCache.hasSavedCookies, rememberCookies { return "Saved cookies" }
        return source == .none ? "Not signed in" : source.label
    }

    private func startDownload() {
        guard canDownload else { return }
        store.startDownload(
            url: trimmedURL,
            libraryID: selectedLibrary.id,
            cookiesFromBrowser: BrowserCookieSource(rawValue: browserCookiesRaw) ?? .none,
            rememberCookies: rememberCookies,
            allowsPlaylist: looksLikePlaylist && downloadPlaylist,
            resolution: DownloadResolution(rawValue: format) ?? DownloadResolution(rawValue: resolutionRaw) ?? .p1080,
            quality: DownloadQuality(rawValue: qualityRaw) ?? .balanced,
            toDownloadsFolder: savesToDownloads,
            audioOnly: audioOnly,
            toMusic: chosenMusicDestination,
            showInVideos: showsInVideos
        )
        dismiss()
    }
}
