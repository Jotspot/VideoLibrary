import SwiftUI
import AppKit

enum SettingsTab: String, CaseIterable, Identifiable {
    case general, captions, downloads, suggestions, music, tools, privacy, help
    var id: String { rawValue }
}

/// Shared @AppStorage keys so every screen reads the same preferences.
enum AppPreference {
    static let settingsTab = "settingsTab"
    static let opensFullScreen = "playerOpensFullScreen"
    static let captionsEnabled = "captionsEnabled"
    static let fitWindowToVideo = "playerFitsWindowToVideo"
    static let autoMiniplayer = "playerAutoMiniplayer"
    static let resolution = "downloadResolution"
    static let quality = "downloadQuality"
    static let browserCookies = "browserCookies"
    static let rememberCookies = "rememberCookies"
    static let suggestionsLibraryID = "suggestionsDownloadLibraryID"
    static let hideShorts = "suggestionsHideShorts"
    static let minimumLength = "suggestionsMinimumLength"
}

extension OpenSettingsAction {
    /// Opens Settings on a specific tab: `openSettings(tab: .tools)`.
    @MainActor
    func callAsFunction(tab: SettingsTab) {
        UserDefaults.standard.set(tab.rawValue, forKey: AppPreference.settingsTab)
        callAsFunction()
    }
}

struct SettingsView: View {
    @Bindable var suggestionsStore: YouTubeSuggestionsStore
    @AppStorage(AppPreference.settingsTab) private var selectedTab = SettingsTab.general.rawValue

    var body: some View {
        TabView(selection: $selectedTab) {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(SettingsTab.general.rawValue)
            CaptionSettingsView()
                .tabItem { Label("Captions", systemImage: "captions.bubble") }
                .tag(SettingsTab.captions.rawValue)
            DownloadSettingsView()
                .tabItem { Label("Downloads", systemImage: "arrow.down.circle") }
                .tag(SettingsTab.downloads.rawValue)
            SuggestionSettingsView(suggestionsStore: suggestionsStore)
                .tabItem { Label("Suggestions", systemImage: "sparkles.tv") }
                .tag(SettingsTab.suggestions.rawValue)
            MusicSettingsView()
                .tabItem { Label("Music", systemImage: "music.note") }
                .tag(SettingsTab.music.rawValue)
            ToolsSettingsView()
                .tabItem { Label("Tools", systemImage: "wrench.and.screwdriver") }
                .tag(SettingsTab.tools.rawValue)
            PrivacySettingsView()
                .tabItem { Label("Privacy", systemImage: "lock.shield") }
                .tag(SettingsTab.privacy.rawValue)
            HelpSettingsView()
                .tabItem { Label("Help", systemImage: "questionmark.circle") }
                .tag(SettingsTab.help.rawValue)
        }
        .frame(width: 560)
        .frame(minHeight: 420)
    }
}

// MARK: - General

private struct GeneralSettingsView: View {
    @Environment(LibraryStore.self) private var store
    @AppStorage(AppPreference.opensFullScreen) private var opensFullScreen = false
    @AppStorage(AppPreference.fitWindowToVideo) private var fitsWindowToVideo = true
    @AppStorage(AppPreference.autoMiniplayer) private var autoMiniplayer = true

    var body: some View {
        Form {
            Section("Player") {
                Toggle("Open videos in full screen", isOn: $opensFullScreen)
                Toggle("Resize the window to fit each video", isOn: $fitsWindowToVideo)
                    .disabled(opensFullScreen)
                Toggle("Keep playing in a miniplayer when going back to the library", isOn: $autoMiniplayer)
                Text("Videos fill the window, which resizes to the video's shape and back. Move the pointer over the video to show controls; press F or double-click for full screen. The miniplayer is skipped when a video has finished.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Libraries") {
                ForEach(store.sortedLibraries) { library in
                    HStack {
                        Label(library.name, systemImage: store.librarySystemImage(for: library))
                        Spacer()
                        Text(library.isAvailable ? library.path : store.libraryStatusText(for: library))
                            .font(.caption)
                            .foregroundStyle(library.isAvailable ? Color.secondary : Color.orange)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: 260, alignment: .trailing)
                        Menu {
                            Button("Copy Videos into Library…") {
                                store.chooseVideosToImport(into: library.id, copy: true)
                            }
                            Button("Link Videos Where They Are…") {
                                store.chooseVideosToImport(into: library.id, copy: false)
                            }
                        } label: {
                            Label("Import Videos", systemImage: "square.and.arrow.down.on.square")
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        .disabled(!library.isAvailable)
                        .help("Add videos you didn't download from YouTube — the file name becomes the title and an early frame the thumbnail")
                    }
                }
                Button("Add Library Folder…") { store.chooseLibraryFolder() }
                if let status = store.importStatus {
                    Label(status, systemImage: status.hasPrefix("Importing") ? "arrow.down.circle" : "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Captions

private struct CaptionSettingsView: View {
    @AppStorage(AppPreference.captionsEnabled) private var captionsEnabled = true
    @AppStorage(CaptionPreference.behavior) private var behavior = CaptionBehavior.pairs
    @AppStorage(CaptionPreference.size) private var size = CaptionSize.medium
    @AppStorage(CaptionPreference.font) private var font = CaptionFont.system
    @AppStorage(CaptionPreference.weight) private var weight = CaptionWeight.semibold
    @AppStorage(CaptionPreference.color) private var color = CaptionColor.white
    @AppStorage(CaptionPreference.background) private var background = CaptionBackground.box
    @AppStorage(CaptionPreference.backgroundOpacity) private var backgroundOpacity = 0.72
    @AppStorage(CaptionPreference.position) private var position = CaptionPosition.bottom
    @AppStorage(CaptionPreference.revealWords) private var revealWords = true
    @AppStorage(CaptionPreference.animated) private var animated = false
    @AppStorage(CaptionPreference.holdThroughPauses) private var holdThroughPauses = true

    private var style: CaptionStyle {
        CaptionStyle(behavior: behavior, size: size, font: font, weight: weight, color: color,
                     background: background, backgroundOpacity: backgroundOpacity, position: position,
                     animated: animated)
    }

    var body: some View {
        Form {
            Section {
                preview
                    .listRowInsets(EdgeInsets())
            } footer: {
                Text("Live preview: plays a short sample with your current settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Presets") {
                presetPicker
            }

            Section("Captions") {
                Toggle("Show captions when available", isOn: $captionsEnabled)
                Picker("Auto-generated captions", selection: $behavior) {
                    ForEach(CaptionBehavior.allCases) { Text($0.label).tag($0) }
                }
                Text(behaviorHelp)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Show words as they're spoken", isOn: $revealWords)
                Text("For YouTube's auto-generated captions, each word pops in the moment it's said, like on YouTube. Hand-made captions always appear whole.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("Position", selection: $position) {
                    ForEach(CaptionPosition.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
            }

            Section {
                Toggle("Animate captions", isOn: $animated)
                Toggle("Keep captions on screen through short pauses", isOn: $holdThroughPauses)
            } header: {
                Text("Motion")
            } footer: {
                Text("Animations: lines scroll smoothly, the box resizes gently and captions fade in and out. Turn off for instant changes. Keeping captions through pauses stops the box blinking off between sentences.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Text") {
                Picker("Size", selection: $size) {
                    ForEach(CaptionSize.allCases) { Text($0.label).tag($0) }
                }
                Picker("Font", selection: $font) {
                    ForEach(CaptionFont.allCases) { Text($0.label).tag($0) }
                }
                Picker("Weight", selection: $weight) {
                    ForEach(CaptionWeight.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                Picker("Color", selection: $color) {
                    ForEach(CaptionColor.allCases) { option in
                        Label {
                            Text(option.label)
                        } icon: {
                            Image(systemName: "circle.fill").foregroundStyle(option.color)
                        }
                        .tag(option)
                    }
                }
            }

            Section("Background") {
                Picker("Style", selection: $background) {
                    ForEach(CaptionBackground.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                if background.hasBox {
                    LabeledContent("Opacity") {
                        Slider(value: $backgroundOpacity, in: 0.2...1)
                            .frame(width: 200)
                    }
                }
            }

            Section {
                Button("Reset to Defaults") {
                    behavior = .pairs; size = .medium; font = .system; weight = .semibold
                    color = .white; background = .box; backgroundOpacity = 0.72; position = .bottom
                    revealWords = true; animated = false; holdThroughPauses = true
                }
            }
        }
        .formStyle(.grouped)
    }

    private var behaviorHelp: String {
        switch behavior {
        case .pairs: "Two lines appear together, then flip to the next two. Easiest to read."
        case .lines: "A single line at a time. Smallest footprint over the video."
        case .rolling: "Like YouTube: the previous line moves up as a new one appears underneath."
        }
    }

    private var preview: some View {
        CaptionLivePreview(
            style: style,
            revealWords: revealWords,
            holdThroughPauses: holdThroughPauses
        )
    }

    // MARK: Presets

    private enum Preset: String, CaseIterable, Identifiable {
        case youtube, classic, large, minimal
        var id: String { rawValue }
        var label: String {
            switch self {
            case .youtube: "YouTube"
            case .classic: "Classic"
            case .large: "Large & Clear"
            case .minimal: "Minimal"
            }
        }
        var symbol: String {
            switch self {
            case .youtube: "play.rectangle"
            case .classic: "film"
            case .large: "textformat.size.larger"
            case .minimal: "text.alignleft"
            }
        }
    }

    private func apply(_ preset: Preset) {
        switch preset {
        case .youtube:
            behavior = .rolling; revealWords = true; animated = true; size = .medium; font = .system
            weight = .semibold; color = .white; background = .box; backgroundOpacity = 0.75
        case .classic:
            behavior = .pairs; revealWords = false; animated = false; size = .large; font = .system
            weight = .semibold; color = .white; background = .outline; backgroundOpacity = 0.72
        case .large:
            behavior = .pairs; revealWords = false; animated = false; size = .extraLarge; font = .rounded
            weight = .bold; color = .yellow; background = .box; backgroundOpacity = 0.85
        case .minimal:
            behavior = .lines; revealWords = true; animated = false; size = .medium; font = .system
            weight = .regular; color = .white; background = .none; backgroundOpacity = 0.72
        }
    }

    private func isCurrent(_ preset: Preset) -> Bool {
        switch preset {
        case .youtube: behavior == .rolling && revealWords && animated && background == .box && size == .medium
        case .classic: behavior == .pairs && !revealWords && background == .outline && size == .large
        case .large: behavior == .pairs && size == .extraLarge && weight == .bold && color == .yellow
        case .minimal: behavior == .lines && background == .none && weight == .regular
        }
    }

    private var presetPicker: some View {
        HStack(spacing: 8) {
            ForEach(Preset.allCases) { preset in
                Button {
                    apply(preset)
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: preset.symbol).font(.title3)
                        Text(preset.label).font(.caption)
                    }
                    .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
                .tint(isCurrent(preset) ? .accentColor : nil)
            }
        }
    }

}

// MARK: - Downloads

private struct DownloadSettingsView: View {
    @AppStorage(AppPreference.resolution) private var resolutionRaw = DownloadResolution.p1080.rawValue
    @AppStorage(AppPreference.quality) private var qualityRaw = DownloadQuality.balanced.rawValue

    var body: some View {
        Form {
            Section("Quality") {
                Picker("Resolution", selection: $resolutionRaw) {
                    ForEach(DownloadResolution.allCases) { Text($0.label).tag($0.rawValue) }
                }
                Picker("Quality", selection: $qualityRaw) {
                    ForEach(DownloadQuality.allCases) { Text($0.label).tag($0.rawValue) }
                }
                Text((DownloadQuality(rawValue: qualityRaw) ?? .balanced).helpText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                YouTubeSignInControls()
            } header: {
                Text("YouTube Sign-In")
            } footer: {
                Text("Sign in here, or import your sign-in from any browser you already use (Arc, Dia, Chrome, Safari, Firefox and more). It fixes “confirm you're not a bot”, age-restricted and members-only errors, helps with rate limits, and powers Suggestions. Stored encrypted with a key in your Mac's Keychain.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            NebulaSettingsSection()
        }
        .formStyle(.grouped)
    }
}

// MARK: - Nebula

private struct NebulaSettingsSection: View {
    @State private var isConnected = NebulaAccount.isConnected
    @State private var token = ""
    @State private var isChecking = false
    @State private var message: (text: String, success: Bool)?

    var body: some View {
        Section {
            if isConnected {
                LabeledContent("Status") {
                    Label("Connected · stored encrypted", systemImage: "lock.fill")
                        .foregroundStyle(.green)
                }
                Button("Disconnect Nebula", role: .destructive) {
                    NebulaAccount.disconnect()
                    message = nil
                }
            } else {
                BrowserImportMenu(service: .nebula) { result in
                    message = result
                    isConnected = NebulaAccount.isConnected
                }
                HStack {
                    SecureField("Or paste your Nebula token", text: $token)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(connect)
                    Button(isChecking ? "Checking…" : "Connect", action: connect)
                        .disabled(isChecking || token.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            if let message {
                Label(message.text, systemImage: message.success ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(message.success ? .green : .orange)
            }
        } header: {
            Text("Nebula")
        } footer: {
            Text("Lets you download from nebula.tv with your subscription. Easiest: sign in on nebula.tv in your browser, then use Import from Browser here. Or paste the token: on nebula.tv, it's the value of the “nebula_auth.apiToken” cookie (Developer Tools › Storage › Cookies). The token is checked with Nebula, then stored encrypted.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .onReceive(NotificationCenter.default.publisher(for: CookieCache.didChangeNotification)) { _ in
            isConnected = NebulaAccount.isConnected
        }
    }

    private func connect() {
        let value = token
        isChecking = true
        message = nil
        Task {
            do {
                try await NebulaAccount.connect(token: value)
                token = ""
                message = ("Nebula connected.", true)
            } catch {
                message = (error.localizedDescription, false)
            }
            isChecking = false
            isConnected = NebulaAccount.isConnected
        }
    }
}

// MARK: - Suggestions

private struct SuggestionSettingsView: View {
    @Environment(LibraryStore.self) private var store
    @Bindable var suggestionsStore: YouTubeSuggestionsStore
    @AppStorage(AppPreference.hideShorts) private var hideShorts = true
    @AppStorage(AppPreference.minimumLength) private var minimumLength = 60
    @AppStorage(AppPreference.suggestionsLibraryID) private var libraryIDRaw = ""

    var body: some View {
        Form {
            Section {
                Picker("Get suggestions using", selection: $suggestionsStore.source) {
                    ForEach(SuggestionFeedSource.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.radioGroup)

                if suggestionsStore.source == .youtubeSignIn {
                    YouTubeSignInControls()
                    Picker("Feed", selection: $suggestionsStore.feedKind) {
                        Text("Subscriptions (newest first)").tag(YouTubeFeedKind.subscriptions)
                        Text("Recommended (your YouTube Home)").tag(YouTubeFeedKind.recommended)
                    }
                    Picker("Videos to load", selection: $suggestionsStore.feedLimit) {
                        ForEach([50, 100, 200, 400], id: \.self) { Text("\($0)").tag($0) }
                    }
                    Toggle("Fall back to the Google Cloud API if the feed fails", isOn: $suggestionsStore.usesCloudFallback)
                        .disabled(!suggestionsStore.isSignedIn)
                }
            } header: {
                Text("Source")
            } footer: {
                Text(suggestionsStore.source == .youtubeSignIn
                     ? "Reads your real subscriptions feed with your YouTube sign-in. No setup and no daily quota."
                       + (suggestionsStore.isSignedIn ? "" : " Connect the Google Cloud API below to enable the fallback.")
                     : "Uses the official YouTube Data API with your own Google Cloud OAuth client.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Feed") {
                Toggle("Hide YouTube Shorts", isOn: $hideShorts)
                Picker("Also hide clips shorter than", selection: $minimumLength) {
                    Text("Don't hide").tag(0)
                    Text("30 seconds").tag(30)
                    Text("1 minute").tag(60)
                    Text("2 minutes").tag(120)
                    Text("3 minutes").tag(180)
                }
                .disabled(!hideShorts)
                Picker("Download to", selection: libraryBinding) {
                    ForEach(store.libraries) { Text($0.name).tag($0.id.uuidString) }
                }
            }

            Section {
                if suggestionsStore.isSignedIn {
                    LabeledContent("Status") {
                        Label("Connected", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                    Picker("Subscription order", selection: $suggestionsStore.subscriptionOrder) {
                        ForEach(YouTubeSubscriptionOrder.allCases) { Text($0.label).tag($0) }
                    }
                    Picker("Subscriptions to scan", selection: $suggestionsStore.subscriptionLimit) {
                        ForEach([10, 30, 50, 100, 200], id: \.self) { Text("\($0)").tag($0) }
                        Text(suggestionsStore.totalSubscriptionCount.map { "All (\($0))" } ?? "All")
                            .tag(YouTubeSuggestionsStore.allSubscriptions)
                    }
                    Picker("Uploads per channel", selection: $suggestionsStore.uploadsPerChannel) {
                        ForEach(1...5, id: \.self) { Text("\($0)").tag($0) }
                    }
                    Button("Disconnect Google Cloud API", role: .destructive) {
                        suggestionsStore.disconnect()
                    }
                } else {
                    TextField("OAuth desktop client ID", text: $suggestionsStore.clientID)
                        .autocorrectionDisabled()
                    SecureField("Client secret", text: $suggestionsStore.clientSecret)
                        .autocorrectionDisabled()
                    HStack {
                        Button("Connect") { suggestionsStore.connect() }
                            .disabled(suggestionsStore.isLoading
                                      || suggestionsStore.clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        Button("Open Google Cloud Console…") {
                            NSWorkspace.shared.open(URL(string: "https://console.cloud.google.com/apis/credentials")!)
                        }
                        .buttonStyle(.link)
                    }
                    if let error = suggestionsStore.errorMessage, suggestionsStore.source == .googleCloudAPI {
                        Text(error).font(.caption).foregroundStyle(.orange)
                    }
                }
            } header: {
                Text("Google Cloud API (advanced)")
            } footer: {
                Text("Create a “Desktop app” OAuth client in Google Cloud, enable the YouTube Data API v3, and paste its ID and secret. Read-only access; the secret and token are stored encrypted. Each refresh uses about 1 unit of the free 10,000-a-day quota per subscription scanned.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var libraryBinding: Binding<String> {
        Binding(
            get: {
                store.libraries.contains { $0.id.uuidString == libraryIDRaw }
                    ? libraryIDRaw
                    : store.selectedLibraryID.uuidString
            },
            set: { libraryIDRaw = $0 }
        )
    }
}

// MARK: - Music

private struct MusicSettingsView: View {
    @Environment(LibraryStore.self) private var store
    @AppStorage(MusicSettings.enabledKey) private var enabled = false
    @AppStorage(MusicSettings.librariesKey) private var libraryIDs = ""
    @AppStorage(MusicSettings.scopeKey) private var scope = "library"
    @State private var copyMessage: String?
    @State private var appWideHasMusic = MusicSettings.hasMusic(in: MusicSettings.appWideDirectory)
    @AppStorage(MusicSettings.autoHideBarKey) private var barAutoHides = false

    var body: some View {
        Form {
            Section {
                Toggle("Enable Music", isOn: $enabled)
            } footer: {
                Text("Adds a Music tab to the libraries you choose below: play songs from folders on your Mac or a drive, browse by song, album, artist or playlist, and use your keyboard's media keys.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if enabled {
                Section {
                    Picker("Music library", selection: $scope) {
                        Text("One for the whole app").tag("app")
                        Text("Separate for each library").tag("library")
                    }
                    .pickerStyle(.radioGroup)
                } footer: {
                    Text(scope == "app"
                         ? "The Music tab is the same in every library. It's kept in the app's own folder, so it works even when a library's drive isn't connected."
                         : "Each library you choose below has its own songs and playlists, stored with that library (handy for music on an external drive).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section {
                    Toggle("Hide the music bar when leaving Music", isOn: $barAutoHides)
                } footer: {
                    Text("Music keeps playing. You can also right-click the bar to hide it; it comes back when you open Music.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if scope == "app" {
                    appWideSection
                } else {
                Section {
                    ForEach(store.sortedLibraries) { library in
                        Toggle(isOn: binding(for: library.id)) {
                            Label(library.name, systemImage: store.librarySystemImage(for: library))
                        }
                    }
                } header: {
                    Text("Show Music In")
                } footer: {
                    Text("In a library's Music tab, use the + button to add a folder of songs. The folder and every folder inside it become playlists. The music index is kept with that library, in .VideoLibrary/music.json; your song files are never moved or changed.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                }
            }
        }
        .formStyle(.grouped)
    }

    /// Offer to start the shared collection from a library that already has music.
    @ViewBuilder
    private var appWideSection: some View {
        let withMusic = store.sortedLibraries.filter {
            $0.isAvailable && MusicSettings.hasMusic(in: MusicSettings.libraryDirectory($0))
        }
        if !appWideHasMusic, !withMusic.isEmpty {
            Section {
                ForEach(withMusic) { library in
                    Button("Copy Music from \(library.name)", systemImage: "square.on.square") {
                        do {
                            try MusicSettings.copyIntoAppWide(from: library)
                            appWideHasMusic = true
                            copyMessage = "Copied \(library.name)'s music, playlists and cover art."
                        } catch {
                            copyMessage = "Couldn't copy: \(error.localizedDescription)"
                        }
                    }
                }
            } header: {
                Text("Start From a Library")
            } footer: {
                Text("Your app-wide music is empty. Copy a library's songs and playlists to start, or add folders with + in the Music tab. The library keeps its own copy.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        if let copyMessage {
            Text(copyMessage).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func binding(for id: UUID) -> Binding<Bool> {
        Binding(
            get: { libraryIDs.split(separator: ",").contains { $0 == id.uuidString } },
            set: { on in
                var ids = Set(libraryIDs.split(separator: ",").map(String.init))
                if on { ids.insert(id.uuidString) } else { ids.remove(id.uuidString) }
                libraryIDs = ids.sorted().joined(separator: ",")
            }
        )
    }
}

// MARK: - Tools

private struct ToolsSettingsView: View {
    @State private var tools = ToolsService.shared
    @State private var showLog = false
    @State private var sabr = SABRAddon.shared
    /// Which "are you sure" alert is showing (0 = none).
    @State private var sabrConfirmation = 0

    var body: some View {
        Form {
            Section {
                ForEach(tools.tools) { tool in
                    let unknown = tools.lastChecked == nil
                    HStack(spacing: 12) {
                        Image(systemName: unknown ? "circle.dotted"
                              : tool.isInstalled ? "checkmark.circle.fill" : "xmark.octagon.fill")
                            .foregroundStyle(unknown ? .secondary : tool.isInstalled ? Color.green : Color.red)
                            .font(.title3)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(tool.name).font(.headline)
                            Text(tool.purpose).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(unknown ? "Checking…" : tool.isInstalled ? (tool.version ?? "Installed") : "Not installed")
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(unknown || tool.isInstalled ? Color.secondary : Color.red)
                    }
                    .padding(.vertical, 2)
                }
            } header: {
                Text("Download Tools")
            } footer: {
                Text("YouTube changes often. If downloads start failing, updating these usually fixes it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                if tools.brewPath == nil {
                    Text("These tools are installed with Homebrew, which isn't on this Mac yet.")
                    Button("Get Homebrew…") {
                        NSWorkspace.shared.open(URL(string: "https://brew.sh")!)
                    }
                } else {
                    HStack {
                        Button {
                            Task { await tools.updateAll() }
                        } label: {
                            Label(tools.lastChecked == nil || tools.missingTools.isEmpty ? "Update All" : "Install & Update All",
                                  systemImage: "arrow.triangle.2.circlepath")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(tools.isUpdating)

                        Button("Check Again") { Task { await tools.refresh() } }
                            .disabled(tools.isUpdating || tools.isChecking)

                        Spacer()

                        if tools.isUpdating || tools.isChecking {
                            ProgressView().controlSize(.small)
                            Text(tools.isUpdating ? "Updating… this can take a minute" : "Checking…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                switch tools.lastResult {
                case .success(let message):
                    Label(message, systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                case .failure(let message):
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                case nil:
                    EmptyView()
                }

                if !tools.log.isEmpty {
                    DisclosureGroup("Show Log", isExpanded: $showLog) {
                        ScrollView {
                            Text(tools.log)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(height: 140)
                    }
                }
            }

            sabrSection
        }
        .formStyle(.grouped)
        .task {
            await tools.refresh()
            await sabr.refresh()
        }
    }

    /// The SABR add-on. Downloads offer it on their own when YouTube only
    /// serves SABR streams; installing it from here asks several times first.
    @ViewBuilder
    private var sabrSection: some View {
        Section {
            HStack(spacing: 12) {
                Image(systemName: "flask.fill")
                    .foregroundStyle(.purple)
                    .font(.title3)
                VStack(alignment: .leading, spacing: 2) {
                    Text("SABR Add-on").font(.headline)
                    Text("yt-dlp's preview build, used only when YouTube serves SABR-only streams")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text(sabr.installed ? (sabr.version ?? "Installed") : "Not installed")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            HStack {
                if sabr.installed {
                    Button(sabr.isInstalling ? "Updating…" : "Update Add-on", systemImage: "arrow.triangle.2.circlepath") {
                        Task { await sabr.install() }
                    }
                    .disabled(sabr.isInstalling)
                    Button("Remove", role: .destructive) { sabr.remove() }
                        .disabled(sabr.isInstalling)
                } else {
                    Button(sabr.isInstalling ? "Installing…" : "Install SABR Add-on…", systemImage: "exclamationmark.triangle") {
                        sabrConfirmation = 1
                    }
                    .disabled(sabr.isInstalling)
                }
                Spacer()
                if sabr.isInstalling { ProgressView().controlSize(.small) }
            }
            if let error = sabr.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
        } header: {
            Text("Experimental")
        } footer: {
            Text("Most people never need this. If YouTube only offers your account SABR streams, a download will offer the add-on by itself. It's a preview of yt-dlp with SABR support (yt-dlp pull request #13515), checked against its published checksum, kept in Application Support, and it never replaces your Homebrew yt-dlp.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .alert("Install experimental software?", isPresented: confirmationBinding(1)) {
            Button("Continue") { advanceSABRConfirmation() }
            Button("Cancel", role: .cancel) { sabrConfirmation = 0 }
        } message: {
            Text("The SABR add-on is a preview build of yt-dlp that hasn't been released yet. It may be unstable, and it may break when YouTube changes something.")
        }
        .alert("Are you sure?", isPresented: confirmationBinding(2)) {
            Button("Continue") { advanceSABRConfirmation() }
            Button("Cancel", role: .cancel) { sabrConfirmation = 0 }
        } message: {
            Text("You probably don't need it. VideoLibrary already tries other YouTube clients when SABR limits a download, and it offers the add-on by itself if those don't work.")
        }
        .alert("Download a second copy of yt-dlp?", isPresented: confirmationBinding(3)) {
            Button("Continue") { advanceSABRConfirmation() }
            Button("Cancel", role: .cancel) { sabrConfirmation = 0 }
        } message: {
            Text("This downloads about 37 MB from GitHub (github.com/bashonly/yt-dlp, a yt-dlp maintainer's preview) into Application Support. It isn't from Homebrew, so brew upgrade won't update it; use Update Add-on here instead.")
        }
        .alert("Really install the SABR add-on?", isPresented: confirmationBinding(4)) {
            Button("Install", role: .destructive) {
                sabrConfirmation = 0
                Task { await sabr.install() }
            }
            Button("Cancel", role: .cancel) { sabrConfirmation = 0 }
        } message: {
            Text("Last check. It's only used for YouTube videos that are limited to SABR streams, and you can remove it here at any time.")
        }
    }

    private func confirmationBinding(_ step: Int) -> Binding<Bool> {
        Binding(get: { sabrConfirmation == step }, set: { if !$0, sabrConfirmation == step { sabrConfirmation = 0 } })
    }

    /// Shows the next alert after the current one has closed.
    private func advanceSABRConfirmation() {
        let next = sabrConfirmation + 1
        sabrConfirmation = 0
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { sabrConfirmation = next }
    }
}

// MARK: - Privacy

private struct PrivacySettingsView: View {
    @Environment(LibraryStore.self) private var store
    @State private var check = SecurityCheck.shared

    var body: some View {
        Form {
            Section {
                storedRow("YouTube sign-in cookies", "Encrypted (AES-256-GCM)")
                storedRow("YouTube account token", "Encrypted (AES-256-GCM)")
                storedRow("Google client secret", "Encrypted (AES-256-GCM)")
                storedRow("Local sharing access code", "Encrypted (AES-256-GCM)")
                storedRow("Encryption key", "macOS Keychain")
                storedRow("Debug log", "Tokens & cookies redacted")
            } header: {
                Text("How Your Data Is Stored")
            } footer: {
                Text("While a download runs, yt-dlp needs a readable cookies file. The app decrypts one into a private temporary folder and destroys it as soon as the download ends.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    Button("Run Security Check") {
                        Task { await check.run(libraryFolders: store.libraries.filter(\.isAvailable).map(\.url)) }
                    }
                    .disabled(check.isRunning)
                    if check.isRunning { ProgressView().controlSize(.small) }
                    Spacer()
                    if let lastRun = check.lastRun {
                        Text("Last run \(lastRun.formatted(date: .omitted, time: .shortened))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if check.findings.isEmpty, check.lastRun != nil {
                    Label("No plaintext secrets found.", systemImage: "checkmark.shield.fill")
                        .foregroundStyle(.green)
                }
                ForEach(check.findings) { finding in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: finding.fixed ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(finding.fixed ? .green : .orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(finding.title).font(.callout.weight(.medium))
                            Text(finding.detail).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text("Security Check")
            } footer: {
                Text("Looks for sign-in data older versions stored unencrypted (cookie files, tokens, preferences, logs, video info files), encrypts what's still needed and deletes the plaintext. Runs automatically at launch.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func storedRow(_ item: String, _ how: String) -> some View {
        LabeledContent(item) {
            Label(how, systemImage: "lock.fill")
                .labelStyle(.titleAndIcon)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Help

private struct HelpSettingsView: View {
    var body: some View {
        Form {
            Section {
                HStack {
                    Button("Open User Manual", systemImage: "book") { NSWorkspace.shared.open(AppLinks.manual) }
                        .buttonStyle(.borderedProminent)
                    Button("What's New") { NSWorkspace.shared.open(AppLinks.changelog) }
                    Spacer()
                    Button("Report a Problem…") { NSWorkspace.shared.open(AppLinks.issues) }
                }
            } header: {
                Text("Manual")
            } footer: {
                Text("The manual covers libraries, downloading, signing in, the player, captions, music, Wi-Fi sharing and troubleshooting. It opens in your browser (Help › VideoLibrary Manual, ⌘?).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Player Shortcuts") {
                shortcut("Play / Pause", "Space or K")
                shortcut("Back / forward 5 seconds", "← / →")
                shortcut("Back / forward 10 seconds", "J / L")
                shortcut("Previous / next frame", ", / .")
                shortcut("Volume", "↑ / ↓")
                shortcut("Mute", "M")
                shortcut("Captions", "C")
                shortcut("Full screen", "F or double-click")
                shortcut("Picture in Picture", "I")
                shortcut("Exit full screen, then close", "Esc")
            }

            Section("Troubleshooting") {
                Text("The debug log records every download step and error. Attach it when reporting a problem.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Open Debug Log") { NSWorkspace.shared.open(DebugLog.fileURL) }
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([DebugLog.fileURL]) }
                    Spacer()
                    Button("Clear Log", role: .destructive) { DebugLog.clear() }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func shortcut(_ action: String, _ keys: String) -> some View {
        LabeledContent(action) {
            Text(keys).font(.callout.monospaced()).foregroundStyle(.secondary)
        }
    }
}
