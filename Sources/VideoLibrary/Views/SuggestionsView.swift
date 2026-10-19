import AppKit
import SwiftUI

struct SuggestionsView: View {
    @Environment(LibraryStore.self) private var store
    @AppStorage("downloadResolution") private var downloadResolutionRaw = DownloadResolution.p1080.rawValue
    @AppStorage("downloadQuality") private var downloadQualityRaw = DownloadQuality.balanced.rawValue
    @AppStorage(AppPreference.browserCookies) private var browserCookiesRaw = BrowserCookieSource.none.rawValue
    @AppStorage(AppPreference.rememberCookies) private var rememberCookies = false
    @AppStorage("suggestionsDownloadLibraryID") private var downloadLibraryIDRaw = ""
    @AppStorage("suggestionsHideShorts") private var hideShorts = true
    @AppStorage(AppPreference.minimumLength) private var minimumLength = 60
    @Environment(\.openSettings) private var openSettings
    @Bindable var suggestionsStore: YouTubeSuggestionsStore

    private let columns = [
        GridItem(.adaptive(minimum: 300, maximum: 300), spacing: 20, alignment: .top)
    ]

    private var notDownloadedSuggestions: [SuggestedVideo] {
        let downloadedIDs = Set(store.items.map(\.ytdlpID))
        let source = suggestionsStore.searchResults ?? suggestionsStore.suggestions
        return source.filter { !downloadedIDs.contains($0.id) }
    }

    private var visibleSuggestions: [SuggestedVideo] {
        guard hideShorts else { return notDownloadedSuggestions }
        // Real Shorts, plus short regular clips (ads, teasers) under the
        // chosen minimum length, which most people also think of as Shorts.
        return notDownloadedSuggestions.filter { video in
            !video.looksLikeShort && (video.duration ?? .infinity) >= Double(minimumLength)
        }
    }

    private var hiddenShortsCount: Int {
        hideShorts ? notDownloadedSuggestions.count - visibleSuggestions.count : 0
    }

    private var selectedDownloadResolution: DownloadResolution {
        DownloadResolution(rawValue: downloadResolutionRaw) ?? .p1080
    }

    private var selectedDownloadQuality: DownloadQuality {
        DownloadQuality(rawValue: downloadQualityRaw) ?? .balanced
    }

    private var selectedBrowserCookies: BrowserCookieSource {
        BrowserCookieSource(rawValue: browserCookiesRaw) ?? .none
    }

    private var selectedDownloadLibrary: LibraryLocation {
        if let id = UUID(uuidString: downloadLibraryIDRaw),
           let library = store.libraries.first(where: { $0.id == id }) {
            return library
        }
        return store.selectedLibrary
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header

                if isShowingSearch {
                    searchBanner
                }

                if isShowingSearch, visibleSuggestions.isEmpty, !suggestionsStore.isSearching {
                    ContentUnavailableView(
                        "No Results",
                        systemImage: "magnifyingglass",
                        description: Text(suggestionsStore.searchError
                            ?? (hiddenShortsCount > 0
                                ? "\(hiddenShortsCount) Shorts and short clips are hidden. Turn off Hide Shorts to see them."
                                : "Try different words."))
                    )
                    .frame(maxWidth: .infinity)
                    .padding(.top, 40)
                } else if !isShowingSearch, !suggestionsStore.isReady {
                    connectCard
                } else if !isShowingSearch, visibleSuggestions.isEmpty, !suggestionsStore.isLoading {
                    ContentUnavailableView(
                        "No New Suggestions",
                        systemImage: "sparkles.tv",
                        description: Text(hiddenShortsCount > 0
                            ? "\(hiddenShortsCount) Shorts and short clips are hidden. Turn off Hide Shorts to see them, or refresh to check your subscriptions."
                            : "Refresh to check your subscriptions, or download more videos so the app has more channels to suggest from later.")
                    )
                    .frame(maxWidth: .infinity)
                    .padding(.top, 60)
                } else {
                    LazyVGrid(columns: columns, spacing: 24) {
                        ForEach(visibleSuggestions) { video in
                            SuggestionCardView(
                                video: video,
                                resolution: selectedDownloadResolution,
                                quality: selectedDownloadQuality,
                                canDownload: selectedDownloadLibrary.isAvailable
                            ) {
                                store.startDownload(
                                    url: video.youtubeURL.absoluteString,
                                    libraryID: selectedDownloadLibrary.id,
                                    cookiesFromBrowser: selectedBrowserCookies,
                                    rememberCookies: rememberCookies,
                                    allowsPlaylist: false,
                                    resolution: selectedDownloadResolution,
                                    quality: selectedDownloadQuality,
                                    knownTitle: video.title
                                )
                            }
                        }
                    }
                }
            }
            .padding(24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            // Also refresh caches from before Shorts detection used the
            // video's shape (no entry has it yet).
            let needsShortsInfo = !suggestionsStore.suggestions.isEmpty
                && suggestionsStore.suggestions.allSatisfy { $0.isVerticalShort == nil }
            let isStale = suggestionsStore.lastRefreshDate.map { Date().timeIntervalSince($0) > 15 * 60 } ?? true
            if suggestionsStore.isReady,
               suggestionsStore.suggestions.isEmpty || needsShortsInfo || isStale {
                await suggestionsStore.refresh()
            }
        }
        .onChange(of: suggestionsStore.feedKind) { _, _ in
            Task { await suggestionsStore.refresh() }
        }
        // Signing in (or importing) from this screen loads the feed right away.
        .onChange(of: suggestionsStore.isReady) { _, ready in
            if ready, suggestionsStore.suggestions.isEmpty {
                Task { await suggestionsStore.refresh() }
            }
        }
    }

    private var isShowingSearch: Bool {
        suggestionsStore.searchResults != nil || suggestionsStore.isSearching
    }

    private var searchBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            Text("YouTube results for “\(suggestionsStore.searchedQuery)”")
                .font(.headline)
                .lineLimit(1)
            if suggestionsStore.isSearching {
                ProgressView().controlSize(.small)
            }
            Spacer()
            Button("Back to Feed", systemImage: "chevron.left") {
                store.searchQuery = ""
                suggestionsStore.clearSearch()
            }
        }
        .padding(12)
        .background(.secondary.opacity(0.1), in: .rect(cornerRadius: 12))
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Suggestions")
                    .font(.largeTitle.bold())
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                Text("Videos from YouTube you might want to save, minus ones already in your library. Use the search box to search all of YouTube.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if suggestionsStore.isReady {
                headerControls
            }

            if suggestionsStore.isLoading {
                ProgressView(suggestionsStore.loadingStatus.isEmpty ? "Loading subscriptions..." : suggestionsStore.loadingStatus)
                    .controlSize(.small)
            }

            if let lastRefreshDate = suggestionsStore.lastRefreshDate {
                Text("\(subscriptionSummary)\(hiddenShortsCount > 0 ? ", \(hiddenShortsCount) Shorts & short clips hidden" : ""). Last refreshed \(lastRefreshDate.formatted(date: .abbreviated, time: .shortened)).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let error = suggestionsStore.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(10)
                    .background(.orange.opacity(0.1), in: .rect(cornerRadius: 10))
            }
        }
    }

    private var headerControls: some View {
        HStack(spacing: 8) {
            if suggestionsStore.source == .youtubeSignIn {
                Picker("Feed", selection: $suggestionsStore.feedKind) {
                    ForEach(YouTubeFeedKind.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .help("Subscriptions: newest uploads from channels you follow. Recommended: your YouTube Home feed.")
            }

            Button {
                Task { await suggestionsStore.refresh() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .disabled(suggestionsStore.isLoading)

            Toggle(isOn: $hideShorts) {
                Label("Hide Shorts", systemImage: "rectangle.portrait.slash")
            }
            .toggleStyle(.button)
            .help(hideShorts
                ? "Shorts and clips under the minimum length (Settings) are hidden. Click to show them."
                : "Click to hide YouTube Shorts from suggestions.")

            Button {
                openSettings(tab: .suggestions)
            } label: {
                Label("Settings…", systemImage: "slider.horizontal.3")
            }
        }
    }

    private var subscriptionSummary: String {
        if suggestionsStore.lastSourceUsed == .youtubeSignIn || suggestionsStore.subscriptionCount == 0 {
            let feed = suggestionsStore.feedKind == .subscriptions ? "subscriptions feed" : "recommendations"
            return "\(suggestionsStore.suggestions.count) videos from your \(feed)"
        }
        if let total = suggestionsStore.totalSubscriptionCount,
           total > suggestionsStore.subscriptionCount {
            return "Scanned first \(suggestionsStore.subscriptionCount) of \(total) subscriptions"
        }
        return "Scanned \(suggestionsStore.subscriptionCount) subscriptions"
    }

    private var connectCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("See new videos from your subscriptions", systemImage: "person.crop.circle.badge.plus")
                .font(.title3.bold())

            if suggestionsStore.source == .youtubeSignIn {
                Text("Sign in to YouTube, or import your sign-in from a browser you already use. That's it: no setup, and your sign-in is stored encrypted.")
                    .foregroundStyle(.secondary)
                YouTubeSignInControls(showsStatus: false)
            } else {
                Text("Suggestions are set to use the Google Cloud API, which isn't connected yet.")
                    .foregroundStyle(.secondary)
            }

            Button(suggestionsStore.source == .youtubeSignIn
                   ? "Use the Google Cloud API instead…"
                   : "Connect in Settings…") {
                openSettings(tab: .suggestions)
            }
            .buttonStyle(.link)
        }
        .padding(18)
        .frame(maxWidth: 620, alignment: .leading)
        .background(.secondary.opacity(0.12), in: .rect(cornerRadius: 16))
    }
}

private struct SuggestionCardView: View {
    let video: SuggestedVideo
    let resolution: DownloadResolution
    let quality: DownloadQuality
    let canDownload: Bool
    let download: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .bottomTrailing) {
                AsyncImage(url: video.thumbnailURL) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    case .failure:
                        Rectangle()
                            .fill(.secondary.opacity(0.18))
                            .overlay(Image(systemName: "photo").foregroundStyle(.secondary))
                    case .empty:
                        Rectangle()
                            .fill(.secondary.opacity(0.18))
                            .overlay(ProgressView().controlSize(.small))
                    @unknown default:
                        Rectangle().fill(.secondary.opacity(0.18))
                    }
                }
                .frame(width: 300, height: 169)
                .clipped()

                if let duration = video.formattedDuration() {
                    Text(duration)
                        .font(.caption2.monospacedDigit().weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(.black.opacity(0.75), in: .capsule)
                        .padding(8)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                // Always two lines tall so every card in a row lines up.
                Text(video.title)
                    .font(.headline)
                    .lineLimit(2, reservesSpace: true)
                    .frame(maxWidth: .infinity, alignment: .topLeading)

                HStack {
                    Text(video.channelTitle)
                        .lineLimit(1)
                    Spacer()
                    if let publishedDate = video.formattedPublishedDate() {
                        Text(publishedDate)
                            .monospacedDigit()
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                // Kept even when the size is unknown, for the same reason.
                Text(video.formattedEstimatedFileSize(resolution: resolution, quality: quality)
                        .map { "Approx download: \($0)" } ?? " ")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)

                HStack {
                    Button {
                        download()
                    } label: {
                        Label("Download", systemImage: "arrow.down.circle")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canDownload)
                    .help(canDownload ? "Download this video" : "Select an available library before downloading.")

                    Button {
                        NSWorkspace.shared.open(video.youtubeURL)
                    } label: {
                        Label("Open", systemImage: "safari")
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(14)
        }
        .frame(width: 300, alignment: .topLeading)
        .background(.background.secondary, in: .rect(cornerRadius: 18))
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .stroke(.separator.opacity(0.5))
        )
        .clipShape(RoundedRectangle(cornerRadius: 18))
    }
}
