import SwiftUI
import AppKit

struct RootView: View {
    @Environment(LibraryStore.self) private var store
    /// The video open in the player. The player replaces the whole window
    /// (and fullscreens it) rather than living in a split-view column.
    @State private var playingItem: VideoItem?
    /// Video continuing in the corner miniplayer while browsing.
    @State private var miniItem: VideoItem?
    /// Video playing in the system Picture in Picture window after leaving the player.
    @State private var pipItem: VideoItem?
    @AppStorage(AppPreference.autoMiniplayer) private var autoMiniplayer = true
    @State private var lastPlayedID: UUID?
    @State private var showDownloadPanel = false
    @State private var showAddSheet = false
    @State private var pendingAddURL = ""
    @State private var showSharingPanel = false
    @State private var player = NativePlayerService()
    @State private var musicStore = MusicLibraryStore()
    @State private var musicPlayer = MusicPlayerService()
    @AppStorage(MusicSettings.enabledKey) private var musicEnabled = false
    @AppStorage(MusicSettings.librariesKey) private var musicLibraryIDs = ""
    @AppStorage(MusicSettings.scopeKey) private var musicScope = "library"
    @AppStorage(MusicSettings.autoHideBarKey) private var musicBarAutoHides = false
    /// Hidden from its right-click menu (or by the auto-hide setting) until
    /// the Music tab is opened again.
    @State private var musicBarHidden = false

    private var musicIsOn: Bool {
        MusicSettings.isEnabled(for: store.selectedLibraryID, enabled: musicEnabled, libraryIDs: musicLibraryIDs, scope: musicScope)
    }
    @AppStorage(AppPreference.captionsEnabled) private var captionsEnabled = true
    @State private var sharingServer = LocalSharingServer()
    let suggestionsStore: YouTubeSuggestionsStore

    var body: some View {
        Group {
            if let item = playingItem {
                PlayerView(
                    item: item,
                    player: player,
                    captionsEnabled: $captionsEnabled,
                    close: { leaveVideo(item) }
                )
            } else {
                libraryView
            }
        }
        .sheet(isPresented: $showAddSheet) {
            AddVideoSheet(initialURL: pendingAddURL)
                .environment(store)
        }
        .overlay(alignment: .bottomTrailing) {
            if playingItem == nil {
                VStack(alignment: .trailing, spacing: 12) {
                    if showDownloadPanel || !store.activeTasks.isEmpty {
                        DownloadPanelView()
                            .environment(store)
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                    if let mini = miniItem {
                        MiniPlayerView(
                            item: mini,
                            player: player,
                            expand: {
                                playingItem = mini
                                miniItem = nil
                            },
                            close: {
                                player.stop()
                                miniItem = nil
                            }
                        )
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .padding()
                // Animate only the corner overlay. Attached to the whole
                // window, these also cross-faded the player into the library,
                // which made going back feel slow.
                .animation(.spring(.snappy), value: miniItem?.id)
                .animation(.spring(.snappy), value: showDownloadPanel)
                .animation(.smooth, value: store.activeTasks.isEmpty)
            }
        }
        .onAppear {
            // "Return to app" in the PiP window reopens the full player.
            player.onPictureInPictureRestore = {
                if let item = pipItem {
                    pipItem = nil
                    playingItem = item
                }
            }
        }
        .task(id: "\(store.selectedLibraryID)|\(musicIsOn)|\(store.selectedLibraryIsAvailable)|\(musicScope)") {
            if !musicIsOn {
                musicStore.load(directory: nil, key: nil)
            } else if musicScope == "app" {
                musicStore.load(directory: MusicSettings.appWideDirectory, key: "app")
            } else {
                let library = store.selectedLibrary
                musicStore.load(
                    directory: library.isAvailable ? MusicSettings.libraryDirectory(library) : nil,
                    key: library.id.uuidString
                )
            }
            if !musicIsOn {
                musicPlayer.stop()
                if store.selectedFilter == .music { store.selectedFilter = .all }
            }
            musicPlayer.artworkURL = { musicStore.artworkURL(for: $0.artworkFile) }
            // A queue still playing from another library keeps its own key.
            if musicIsOn, musicPlayer.current == nil, let key = musicStore.collectionKey {
                musicPlayer.collectionKey = key
                musicPlayer.restoreSession(from: musicStore.tracks, collection: key)
            }
            musicPlayer.onTrackStarted = { track in
                musicStore.recordPlay(of: track.id)
                player.pause()   // a song starting pauses any video
            }
        }
        .onChange(of: playingItem?.id) { _, id in
            if id != nil { musicPlayer.pause() }   // a video starting pauses the music
        }
        .onChange(of: player.isPictureInPictureActive) { _, active in
            // PiP window closed while browsing: stop that video.
            if !active, pipItem != nil {
                pipItem = nil
                player.stop()
            }
        }
        .task {
            // Full security scan, including .info.json files in each library.
            await SecurityCheck.shared.run(
                libraryFolders: store.libraries.filter(\.isAvailable).map(\.url)
            )
        }
        .onChange(of: store.selectedLibraryID) { _, _ in
            playingItem = nil
            if miniItem != nil || pipItem != nil { player.stop(); miniItem = nil; pipItem = nil }
            syncSharing()
        }
        .onChange(of: store.items) { _, _ in
            syncSharing()
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didMountNotification)) { _ in
            store.refreshLibraryAvailability()
            syncSharing()
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didUnmountNotification)) { _ in
            store.refreshLibraryAvailability()
            syncSharing()
            if let path = playingItem?.videoFilePath,
               !FileManager.default.fileExists(atPath: path) {
                playingItem = nil
            }
        }
    }

    /// Updates the LAN sharing server's library list, but only while it's
    /// running: gathering it reads every library's index from disk, which
    /// made switching libraries slow for nothing.
    private func syncSharing() {
        guard sharingServer.isRunning else { return }
        sharingServer.update(libraries: store.sharingSnapshots(), selectedLibraryID: store.selectedLibraryID)
    }

    /// Back to the library: Picture in Picture keeps going if it's on;
    /// otherwise an unfinished video continues in the miniplayer (setting).
    private func leaveVideo(_ item: VideoItem) {
        let finished = player.duration > 0 && player.currentPlaybackTime >= player.duration - 5
        if player.isPictureInPictureActive {
            player.isHandingOff = true
            pipItem = item
        } else if autoMiniplayer, player.duration > 0, !finished {
            player.isHandingOff = true
            miniItem = item
        }
        playingItem = nil
    }

    private var libraryView: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 240)
        } detail: {
            VStack(spacing: 0) {
            Group {
                if store.selectedFilter == .suggestions {
                    SuggestionsView(suggestionsStore: suggestionsStore)
                } else if store.selectedFilter == .music, musicIsOn,
                          musicScope == "app" || store.selectedLibraryIsAvailable {
                    MusicView(store: musicStore, player: musicPlayer, searchQuery: store.searchQuery)
                } else if store.selectedLibraryIsAvailable {
                    LibraryGridView(lastPlayedID: lastPlayedID) { item in
                        lastPlayedID = item.id
                        // Playing something else replaces the miniplayer/PiP video.
                        let current = miniItem ?? pipItem
                        if let current, current.id != item.id { player.stop() }
                        miniItem = nil
                        pipItem = nil
                        playingItem = item
                    }
                } else {
                    ContentUnavailableView(
                        "Library Unavailable",
                        systemImage: "externaldrive.badge.exclamationmark",
                        description: Text(store.selectedLibraryUnavailableMessage)
                    )
                }
            }
            .frame(maxHeight: .infinity)
            }
            // Floats over the content (which scrolls underneath the glass).
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if !musicBarHidden {
                    NowPlayingBar(
                        player: musicPlayer, store: musicStore,
                        onHide: store.selectedFilter == .music ? nil : { withAnimation(.smooth) { musicBarHidden = true } }
                    )
                }
            }
            // A fixed minimum keeps the split view's size constraints stable;
            // content-dependent minimums made AppKit loop on constraint
            // updates and abort.
            .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
        }
        .toolbar {
            AppToolbarContent(
                showDownloadPanel: $showDownloadPanel,
                showAddSheet: $showAddSheet,
                pendingAddURL: $pendingAddURL,
                showSharingPanel: $showSharingPanel,
                sharingServer: sharingServer,
                addMusic: store.selectedFilter == .music && musicIsOn ? { musicStore.chooseFolders() } : nil
            )
        }
        // One search box: it searches the library, or all of YouTube while
        // Suggestions is showing (press Return to search).
        .searchable(
            text: Bindable(store).searchQuery,
            placement: .toolbar,
            prompt: store.selectedFilter == .suggestions ? "Search YouTube…"
                : store.selectedFilter == .music ? "Search music…" : "Search library…"
        )
        .onSubmit(of: .search) {
            if store.selectedFilter == .suggestions {
                suggestionsStore.search(store.searchQuery)
            }
        }
        .onChange(of: store.searchQuery) { _, query in
            if query.isEmpty, store.selectedFilter == .suggestions {
                suggestionsStore.clearSearch()
            }
        }
        .onChange(of: store.selectedFilter) { old, new in
            if new == .music {
                musicBarHidden = false
            } else if old == .music, musicBarAutoHides {
                musicBarHidden = true
            }
            // Don't carry a YouTube query into the library filter (or back).
            store.searchQuery = ""
            suggestionsStore.clearSearch()
        }
    }
}
