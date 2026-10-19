import Foundation
import Observation

enum YouTubeSubscriptionOrder: String, CaseIterable, Identifiable, Sendable {
    case relevance
    case unread
    case alphabetical

    var id: String { rawValue }

    var label: String {
        switch self {
        case .relevance: "Relevance"
        case .unread: "Activity"
        case .alphabetical: "Alphabetical"
        }
    }

    var helpText: String {
        switch self {
        case .relevance:
            "YouTube's default relevance order."
        case .unread:
            "YouTube's activity order, usually better for channels with recent uploads."
        case .alphabetical:
            "A-Z by subscription title."
        }
    }
}

/// Where Suggestions come from.
enum SuggestionFeedSource: String, CaseIterable, Identifiable, Sendable {
    /// The real subscriptions feed, read with the saved YouTube sign-in. No setup.
    case youtubeSignIn
    /// The YouTube Data API with the user's own Google Cloud OAuth client.
    case googleCloudAPI

    var id: String { rawValue }

    var label: String {
        switch self {
        case .youtubeSignIn: "YouTube sign-in (recommended)"
        case .googleCloudAPI: "Google Cloud API (advanced)"
        }
    }
}

@Observable
@MainActor
final class YouTubeSuggestionsStore {
    private static let sourceKey = "suggestionsSource"
    private static let cloudFallbackKey = "suggestionsCloudFallback"
    private static let feedLimitKey = "suggestionsFeedLimit"
    private static let feedKindKey = "suggestionsFeedKind"
    private static let clientIDKey = "youtubeOAuthClientID"
    /// Where older versions stored the client secret in plaintext (migrated by SecurityCheck).
    nonisolated static let legacyClientSecretKey = "youtubeOAuthClientSecret"
    private static let subscriptionOrderKey = "youtubeSuggestionsSubscriptionOrder"
    private static let subscriptionLimitKey = "youtubeSuggestionsSubscriptionLimit"
    private static let uploadsPerChannelKey = "youtubeSuggestionsUploadsPerChannel"
    private static let cacheFileName = "youtube-suggestions.json"
    private static let defaultSubscriptionLimit = 100
    /// Picker value meaning "every subscription" (YouTube caps follows at 2,000).
    static let allSubscriptions = 5000
    private static let defaultUploadsPerChannel = 2

    var clientID: String {
        didSet {
            UserDefaults.standard.set(clientID, forKey: Self.clientIDKey)
        }
    }
    var clientSecret: String {
        didSet {
            let trimmed = clientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
            // Encrypted vault, never UserDefaults (a plaintext plist).
            SecretVault.set(trimmed, for: .youtubeClientSecret)
        }
    }
    var subscriptionOrder: YouTubeSubscriptionOrder {
        didSet {
            UserDefaults.standard.set(subscriptionOrder.rawValue, forKey: Self.subscriptionOrderKey)
        }
    }
    var subscriptionLimit: Int {
        didSet {
            let clamped = Self.clampSubscriptionLimit(subscriptionLimit)
            if subscriptionLimit != clamped {
                subscriptionLimit = clamped
                return
            }
            UserDefaults.standard.set(subscriptionLimit, forKey: Self.subscriptionLimitKey)
        }
    }
    var uploadsPerChannel: Int {
        didSet {
            let clamped = Self.clampUploadsPerChannel(uploadsPerChannel)
            if uploadsPerChannel != clamped {
                uploadsPerChannel = clamped
                return
            }
            UserDefaults.standard.set(uploadsPerChannel, forKey: Self.uploadsPerChannelKey)
        }
    }
    var source: SuggestionFeedSource {
        didSet { UserDefaults.standard.set(source.rawValue, forKey: Self.sourceKey) }
    }
    /// With the sign-in source, use the Cloud API if the feed fails (when connected).
    var usesCloudFallback: Bool {
        didSet { UserDefaults.standard.set(usesCloudFallback, forKey: Self.cloudFallbackKey) }
    }
    var feedLimit: Int {
        didSet { UserDefaults.standard.set(feedLimit, forKey: Self.feedLimitKey) }
    }
    /// Subscriptions (newest first) or YouTube's Home recommendations.
    var feedKind: YouTubeFeedKind {
        didSet { UserDefaults.standard.set(feedKind.rawValue, forKey: Self.feedKindKey) }
    }
    /// Whether an encrypted YouTube sign-in (cookies) is saved.
    private(set) var hasYouTubeSignIn = CookieCache.hasYouTubeSignIn
    /// Which source produced the current list (shown in the UI).
    private(set) var lastSourceUsed: SuggestionFeedSource?

    var suggestions: [SuggestedVideo] = []
    /// YouTube search results; nil when showing the feed.
    private(set) var searchResults: [SuggestedVideo]?
    private(set) var searchedQuery = ""
    private(set) var isSearching = false
    private(set) var searchError: String?
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    var isLoading = false
    /// Connected to the Google Cloud API (OAuth token saved).
    var isSignedIn = false

    /// Whether a refresh can run with the current source (or its fallback).
    var isReady: Bool {
        switch source {
        case .youtubeSignIn: hasYouTubeSignIn || (usesCloudFallback && isSignedIn)
        case .googleCloudAPI: isSignedIn
        }
    }
    var errorMessage: String?
    var subscriptionCount = 0
    var totalSubscriptionCount: Int?
    var loadingStatus = ""
    var lastRefreshDate: Date?

    private let oauth = YouTubeOAuthService()
    private let cacheURL: URL
    @ObservationIgnored private var cookieObserver: NSObjectProtocol?

    init() {
        let defaults = UserDefaults.standard
        // Existing Cloud API users keep their setup; everyone else gets sign-in.
        let hadCloudSetup = !(defaults.string(forKey: Self.clientIDKey) ?? "").isEmpty
        source = SuggestionFeedSource(rawValue: defaults.string(forKey: Self.sourceKey) ?? "")
            ?? (hadCloudSetup && !CookieCache.hasYouTubeSignIn ? .googleCloudAPI : .youtubeSignIn)
        usesCloudFallback = defaults.object(forKey: Self.cloudFallbackKey) as? Bool ?? true
        feedLimit = defaults.object(forKey: Self.feedLimitKey) as? Int ?? 100
        feedKind = YouTubeFeedKind(rawValue: defaults.string(forKey: Self.feedKindKey) ?? "") ?? .subscriptions
        clientID = UserDefaults.standard.string(forKey: Self.clientIDKey) ?? ""
        clientSecret = SecretVault.value(.youtubeClientSecret) ?? ""
        subscriptionOrder = YouTubeSubscriptionOrder(
            rawValue: UserDefaults.standard.string(forKey: Self.subscriptionOrderKey) ?? ""
        ) ?? .relevance
        let savedLimit = UserDefaults.standard.object(forKey: Self.subscriptionLimitKey) as? Int
        subscriptionLimit = Self.clampSubscriptionLimit(savedLimit ?? Self.defaultSubscriptionLimit)
        let savedUploads = UserDefaults.standard.object(forKey: Self.uploadsPerChannelKey) as? Int
        uploadsPerChannel = Self.clampUploadsPerChannel(savedUploads ?? Self.defaultUploadsPerChannel)
        let dir = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0].appendingPathComponent("VideoLibrary", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        cacheURL = dir.appendingPathComponent(Self.cacheFileName)
        isSignedIn = oauth.storedToken() != nil
        loadCache()
        cookieObserver = NotificationCenter.default.addObserver(
            forName: CookieCache.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.hasYouTubeSignIn = CookieCache.hasYouTubeSignIn }
        }
    }

    func connect() {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil

        Task {
            do {
                _ = try await oauth.signIn(clientID: clientID, clientSecret: clientSecret)
                await MainActor.run {
                    self.isSignedIn = true
                    self.isLoading = false
                }
                await refresh()
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.isLoading = false
                    self.isSignedIn = self.oauth.storedToken() != nil
                }
            }
        }
    }

    func refresh() async {
        guard !isLoading else { return }
        hasYouTubeSignIn = CookieCache.hasYouTubeSignIn
        let canUseCloud = isSignedIn && !clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        guard source == .youtubeSignIn else {
            await refreshFromCloudAPI()
            return
        }
        guard hasYouTubeSignIn else {
            if usesCloudFallback, canUseCloud {
                await refreshFromCloudAPI()
            } else {
                errorMessage = YouTubeFeedService.FeedError.notSignedIn.localizedDescription
            }
            return
        }

        isLoading = true
        errorMessage = nil
        loadingStatus = feedKind == .subscriptions ? "Loading your subscriptions feed..." : "Loading your recommendations..."
        DebugLog.write("Feed refresh started. kind=\(feedKind.rawValue), limit=\(feedLimit)", category: "youtube")
        do {
            let videos = try await YouTubeFeedService.fetchFeed(feedKind, limit: feedLimit)
            suggestions = videos
            subscriptionCount = 0
            totalSubscriptionCount = nil
            lastRefreshDate = Date()
            lastSourceUsed = .youtubeSignIn
            saveCache()
            DebugLog.write("Feed refresh completed. suggestions=\(videos.count)", category: "youtube")
            loadingStatus = ""
            isLoading = false
        } catch {
            DebugLog.write("Feed refresh failed: \(error.localizedDescription)", category: "youtube")
            loadingStatus = ""
            isLoading = false
            if usesCloudFallback, canUseCloud {
                await refreshFromCloudAPI()
                if errorMessage == nil {
                    errorMessage = "Your subscriptions feed couldn't load (\(error.localizedDescription)), so these came from the Google Cloud API instead."
                }
            } else {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func refreshFromCloudAPI() async {
        guard !isLoading else { return }
        let trimmedClientID = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedClientID.isEmpty else {
            errorMessage = YouTubeOAuthError.missingClientID.localizedDescription
            DebugLog.write("Refresh aborted: missing client ID.", category: "youtube")
            return
        }

        isLoading = true
        errorMessage = nil
        loadingStatus = "Connecting to YouTube..."
        DebugLog.write(
            "Refresh started. subscriptionLimit=\(subscriptionLimit), uploadsPerChannel=\(uploadsPerChannel), order=\(subscriptionOrder.rawValue)",
            category: "youtube"
        )
        do {
            let accessToken = try await oauth.validAccessToken(
                clientID: trimmedClientID,
                clientSecret: clientSecret
            )
            DebugLog.write("OAuth access token available.", category: "youtube")
            loadingStatus = "Scanning recent subscriptions..."
            let api = YouTubeAPIClient(accessToken: accessToken)
            let result = try await api.subscriptionSuggestions(
                subscriptionLimit: subscriptionLimit,
                uploadsPerChannel: uploadsPerChannel,
                subscriptionOrder: subscriptionOrder
            )
            suggestions = result.videos
            subscriptionCount = result.scannedSubscriptionCount
            totalSubscriptionCount = result.totalSubscriptionCount
            lastRefreshDate = Date()
            isSignedIn = true
            lastSourceUsed = .googleCloudAPI
            saveCache()
            DebugLog.write(
                "Refresh completed. suggestions=\(suggestions.count), scannedSubscriptions=\(subscriptionCount), totalSubscriptions=\(totalSubscriptionCount.map(String.init) ?? "unknown")",
                category: "youtube"
            )
        } catch {
            errorMessage = error.localizedDescription
            isSignedIn = oauth.storedToken() != nil
            DebugLog.write("Refresh failed: \(error.localizedDescription)", category: "youtube")
        }
        loadingStatus = ""
        isLoading = false
    }

    func search(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { clearSearch(); return }
        searchTask?.cancel()
        searchedQuery = trimmed
        isSearching = true
        searchError = nil
        searchTask = Task {
            do {
                let results = try await YouTubeFeedService.search(trimmed)
                guard !Task.isCancelled, searchedQuery == trimmed else { return }
                searchResults = results
            } catch {
                guard !Task.isCancelled else { return }
                searchError = error.localizedDescription
                searchResults = []
            }
            isSearching = false
        }
    }

    func clearSearch() {
        searchTask?.cancel()
        searchResults = nil
        searchedQuery = ""
        isSearching = false
        searchError = nil
    }

    /// Disconnects the Google Cloud API (the YouTube sign-in is separate).
    func disconnect() {
        oauth.clearToken()
        isSignedIn = false
        guard source == .googleCloudAPI else { return }
        suggestions = []
        subscriptionCount = 0
        totalSubscriptionCount = nil
        loadingStatus = ""
        lastRefreshDate = nil
        errorMessage = nil
        try? FileManager.default.removeItem(at: cacheURL)
    }

    private func loadCache() {
        guard let data = try? Data(contentsOf: cacheURL),
              let cache = try? JSONDecoder().decode(Cache.self, from: data) else { return }
        suggestions = cache.suggestions
        subscriptionCount = cache.subscriptionCount
        totalSubscriptionCount = cache.totalSubscriptionCount
        lastRefreshDate = cache.lastRefreshDate
    }

    private func saveCache() {
        let cache = Cache(
            suggestions: suggestions,
            subscriptionCount: subscriptionCount,
            totalSubscriptionCount: totalSubscriptionCount,
            lastRefreshDate: lastRefreshDate
        )
        guard let data = try? JSONEncoder().encode(cache) else { return }
        try? data.write(to: cacheURL, options: .atomic)
    }

    private static func clampSubscriptionLimit(_ value: Int) -> Int {
        min(Self.allSubscriptions, max(5, value))
    }

    private static func clampUploadsPerChannel(_ value: Int) -> Int {
        min(5, max(1, value))
    }

    private struct Cache: Codable {
        let suggestions: [SuggestedVideo]
        let subscriptionCount: Int
        let totalSubscriptionCount: Int?
        let lastRefreshDate: Date?
    }
}

private struct YouTubeAPIClient {
    let accessToken: String

    func subscriptionSuggestions(
        subscriptionLimit: Int,
        uploadsPerChannel: Int,
        subscriptionOrder: YouTubeSubscriptionOrder
    ) async throws -> (
        videos: [SuggestedVideo],
        scannedSubscriptionCount: Int,
        totalSubscriptionCount: Int?
    ) {
        let subscriptionPage = try await fetchSubscriptions(
            limit: subscriptionLimit,
            order: subscriptionOrder
        )
        let subscriptions = subscriptionPage.subscriptions
        DebugLog.write(
            "Fetched subscriptions page slice. scanned=\(subscriptions.count), total=\(subscriptionPage.totalSubscriptionCount.map(String.init) ?? "unknown")",
            category: "youtube"
        )
        let channels = try await fetchChannels(ids: subscriptions.map(\.channelID))
        DebugLog.write("Fetched upload playlist IDs. channels=\(channels.count)", category: "youtube")
        let videos = try await fetchUploadSuggestions(
            subscriptions: subscriptions,
            channels: channels,
            uploadsPerChannel: uploadsPerChannel
        )
        DebugLog.write("Fetched upload suggestions before durations. videos=\(videos.count)", category: "youtube")

        let details = try await fetchVideoDetails(videoIDs: videos.map(\.id))
        DebugLog.write("Fetched video details. count=\(details.count)", category: "youtube")
        let videosWithDurations = videos.map { video in
            var copy = video
            let detail = details[video.id]
            copy.duration = detail?.duration
            copy.isVerticalShort = detail.flatMap { detail in
                detail.isVertical.map { $0 && (detail.duration ?? 0) <= 180 }
            }
            return copy
        }
        DebugLog.write(
            "Shorts detected by aspect ratio: \(videosWithDurations.filter { $0.isVerticalShort == true }.count)",
            category: "youtube"
        )

        let uniqueVideos = Dictionary(grouping: videosWithDurations, by: \.id)
            .compactMap { _, videos in videos.first }
            .sorted {
                ($0.publishedAt ?? .distantPast) > ($1.publishedAt ?? .distantPast)
            }
        return (
            uniqueVideos,
            subscriptions.count,
            subscriptionPage.totalSubscriptionCount
        )
    }

    private func fetchSubscriptions(
        limit: Int,
        order: YouTubeSubscriptionOrder
    ) async throws -> SubscriptionPage {
        var subscriptions: [Subscription] = []
        var pageToken: String?
        var totalSubscriptionCount: Int?

        while subscriptions.count < limit {
            let remaining = max(1, min(50, limit - subscriptions.count))
            DebugLog.write(
                "Requesting subscriptions. alreadyFetched=\(subscriptions.count), maxResults=\(remaining), hasPageToken=\(pageToken != nil)",
                category: "youtube"
            )
            var query: [String: String] = [
                "part": "snippet",
                "mine": "true",
                "order": order.rawValue,
                "maxResults": "\(remaining)"
            ]
            if let pageToken {
                query["pageToken"] = pageToken
            }
            let response: SubscriptionsResponse = try await get(
                path: "subscriptions",
                query: query
            )
            subscriptions.append(contentsOf: response.items.compactMap { item in
                guard let channelID = item.snippet.resourceId.channelId else { return nil }
                return Subscription(
                    channelID: channelID,
                    title: item.snippet.title
                )
            })
            if totalSubscriptionCount == nil {
                totalSubscriptionCount = response.pageInfo?.totalResults
            }
            DebugLog.write(
                "Subscriptions response. pageItems=\(response.items.count), accumulated=\(subscriptions.count), total=\(totalSubscriptionCount.map(String.init) ?? "unknown"), hasNext=\(response.nextPageToken != nil)",
                category: "youtube"
            )
            pageToken = response.nextPageToken
            if pageToken == nil { break }
        }

        return SubscriptionPage(
            subscriptions: subscriptions,
            totalSubscriptionCount: totalSubscriptionCount
        )
    }

    private func fetchChannels(ids: [String]) async throws -> [String: Channel] {
        var channels: [String: Channel] = [:]
        for chunk in ids.chunked(into: 50) {
            DebugLog.write("Requesting channels contentDetails. count=\(chunk.count)", category: "youtube")
            let response: ChannelsResponse = try await get(
                path: "channels",
                query: [
                    "part": "contentDetails",
                    "id": chunk.joined(separator: ","),
                    "maxResults": "50"
                ]
            )
            for item in response.items {
                let playlistID = item.contentDetails.relatedPlaylists.uploads
                channels[item.id] = Channel(
                    id: item.id,
                    uploadsPlaylistID: playlistID
                )
            }
            DebugLog.write("Channels response. requested=\(chunk.count), returned=\(response.items.count)", category: "youtube")
        }
        return channels
    }

    private func fetchUploadSuggestions(
        subscriptions: [Subscription],
        channels: [String: Channel],
        uploadsPerChannel: Int
    ) async throws -> [SuggestedVideo] {
        var videos: [SuggestedVideo] = []
        for (batchIndex, batch) in subscriptions.chunked(into: 16).enumerated() {
            DebugLog.write(
                "Requesting upload batch \(batchIndex + 1). channels=\(batch.count)",
                category: "youtube"
            )
            let batchVideos = try await withThrowingTaskGroup(of: [SuggestedVideo].self) { group in
                for subscription in batch {
                    guard let channel = channels[subscription.channelID] else { continue }
                    group.addTask {
                        // One channel failing (e.g. no uploads → 404) shouldn't
                        // sink the whole refresh, especially when scanning hundreds.
                        let uploads: [PlaylistVideo]
                        do {
                            uploads = try await fetchPlaylistItems(
                                playlistID: channel.uploadsPlaylistID,
                                maxResults: uploadsPerChannel
                            )
                        } catch {
                            DebugLog.write(
                                "Skipping channel \(subscription.channelID): \(error.localizedDescription)",
                                category: "youtube"
                            )
                            return []
                        }
                        return uploads.map { item in
                            SuggestedVideo(
                                id: item.videoID,
                                title: item.title,
                                channelTitle: item.channelTitle,
                                channelID: item.channelID,
                                thumbnailURL: item.thumbnailURL,
                                publishedAt: item.publishedAt,
                                duration: nil,
                                source: .subscription
                            )
                        }
                    }
                }

                var collected: [SuggestedVideo] = []
                for try await result in group {
                    collected.append(contentsOf: result)
                }
                return collected
            }
            videos.append(contentsOf: batchVideos)
            DebugLog.write(
                "Upload batch \(batchIndex + 1) complete. videos=\(batchVideos.count), accumulated=\(videos.count)",
                category: "youtube"
            )
        }
        return videos
    }

    private func fetchPlaylistItems(
        playlistID: String,
        maxResults: Int
    ) async throws -> [PlaylistVideo] {
        DebugLog.write("Requesting playlistItems. playlistID=\(playlistID), maxResults=\(maxResults)", category: "youtube")
        let response: PlaylistItemsResponse = try await get(
            path: "playlistItems",
            query: [
                "part": "snippet,contentDetails",
                "playlistId": playlistID,
                "maxResults": "\(maxResults)"
            ]
        )
        let videos: [PlaylistVideo] = response.items.compactMap { item in
            guard let videoID = item.contentDetails.videoId,
                  item.snippet.title != "Private video",
                  item.snippet.title != "Deleted video" else { return nil }
            return PlaylistVideo(
                videoID: videoID,
                title: item.snippet.title,
                channelTitle: item.snippet.videoOwnerChannelTitle ?? item.snippet.channelTitle,
                channelID: item.snippet.videoOwnerChannelId ?? item.snippet.channelId,
                thumbnailURL: item.snippet.thumbnails.bestURL,
                publishedAt: item.contentDetails.videoPublishedAt ?? item.snippet.publishedAt
            )
        }
        DebugLog.write("playlistItems response. playlistID=\(playlistID), rawItems=\(response.items.count), usableVideos=\(videos.count)", category: "youtube")
        return videos
    }

    /// Durations plus player shape. The Data API has no "is a Short" flag,
    /// but with `maxWidth` set it sizes `player.embedWidth/embedHeight` to the
    /// video's real aspect ratio, so vertical videos come back taller than wide.
    private func fetchVideoDetails(
        videoIDs: [String]
    ) async throws -> [String: (duration: TimeInterval?, isVertical: Bool?)] {
        var details: [String: (duration: TimeInterval?, isVertical: Bool?)] = [:]
        for chunk in videoIDs.chunked(into: 50) {
            DebugLog.write("Requesting video details. count=\(chunk.count)", category: "youtube")
            let response: VideosResponse = try await get(
                path: "videos",
                query: [
                    "part": "contentDetails,player",
                    "id": chunk.joined(separator: ","),
                    "maxWidth": "640",
                    "maxResults": "50"
                ]
            )
            for item in response.items {
                let isVertical: Bool? = {
                    guard let width = item.player?.embedWidth,
                          let height = item.player?.embedHeight,
                          width > 0, height > 0 else { return nil }
                    return height > width
                }()
                details[item.id] = (
                    Self.parseISO8601Duration(item.contentDetails.duration),
                    isVertical
                )
            }
            DebugLog.write("Video details response. requested=\(chunk.count), returned=\(response.items.count)", category: "youtube")
        }
        return details
    }

    private func get<Response: Decodable>(
        path: String,
        query: [String: String]
    ) async throws -> Response {
        var components = URLComponents(string: "https://www.googleapis.com/youtube/v3/\(path)")!
        components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 25
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        let startedAt = Date()
        DebugLog.write("HTTP GET \(path) query=\(Self.redactedQuery(query))", category: "youtube")
        let (data, response) = try await URLSession.shared.data(for: request)
        let elapsed = Date().timeIntervalSince(startedAt)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "HTTP error"
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            DebugLog.write(
                "HTTP GET \(path) failed. status=\(status), seconds=\(String(format: "%.2f", elapsed)), body=\(String(message.prefix(1000)))",
                category: "youtube"
            )
            throw YouTubeAPIError.requestFailed(message)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        DebugLog.write(
            "HTTP GET \(path) succeeded. status=\(status), seconds=\(String(format: "%.2f", elapsed)), bytes=\(data.count)",
            category: "youtube"
        )
        return try JSONDecoder.youtube.decode(Response.self, from: data)
    }

    private static func redactedQuery(_ query: [String: String]) -> String {
        query
            .sorted { $0.key < $1.key }
            .map { key, value in
                key.lowercased().contains("token") ? "\(key)=<redacted>" : "\(key)=\(value)"
            }
            .joined(separator: "&")
    }

    private static func parseISO8601Duration(_ value: String) -> TimeInterval? {
        var total: TimeInterval = 0
        var number = ""
        for character in value {
            if character.isNumber || character == "." {
                number.append(character)
                continue
            }
            guard let amount = Double(number) else {
                number = ""
                continue
            }
            switch character {
            case "H": total += amount * 3600
            case "M": total += amount * 60
            case "S": total += amount
            default: break
            }
            number = ""
        }
        return total > 0 ? total : nil
    }

    private struct Subscription {
        let channelID: String
        let title: String
    }

    private struct SubscriptionPage {
        let subscriptions: [Subscription]
        let totalSubscriptionCount: Int?
    }

    private struct Channel {
        let id: String
        let uploadsPlaylistID: String
    }

    private struct PlaylistVideo {
        let videoID: String
        let title: String
        let channelTitle: String
        let channelID: String
        let thumbnailURL: URL?
        let publishedAt: Date?
    }

    private enum YouTubeAPIError: Error, LocalizedError {
        case requestFailed(String)

        var errorDescription: String? {
            switch self {
            case .requestFailed(let message):
                "YouTube API request failed: \(message)"
            }
        }
    }
}

private struct SubscriptionsResponse: Decodable {
    let nextPageToken: String?
    let pageInfo: PageInfo?
    let items: [SubscriptionItem]

    struct PageInfo: Decodable {
        let totalResults: Int?
    }

    struct SubscriptionItem: Decodable {
        let snippet: Snippet

        struct Snippet: Decodable {
            let title: String
            let resourceId: ResourceID
        }

        struct ResourceID: Decodable {
            let channelId: String?
        }
    }
}

private struct ChannelsResponse: Decodable {
    let items: [ChannelItem]

    struct ChannelItem: Decodable {
        let id: String
        let contentDetails: ContentDetails

        struct ContentDetails: Decodable {
            let relatedPlaylists: RelatedPlaylists
        }

        struct RelatedPlaylists: Decodable {
            let uploads: String
        }
    }
}

private struct PlaylistItemsResponse: Decodable {
    let items: [PlaylistItem]

    struct PlaylistItem: Decodable {
        let snippet: Snippet
        let contentDetails: ContentDetails

        struct Snippet: Decodable {
            let publishedAt: Date?
            let title: String
            let channelTitle: String
            let channelId: String
            let videoOwnerChannelTitle: String?
            let videoOwnerChannelId: String?
            let thumbnails: ThumbnailSet
        }

        struct ContentDetails: Decodable {
            let videoId: String?
            let videoPublishedAt: Date?
        }
    }
}

private struct VideosResponse: Decodable {
    let items: [Video]

    struct Video: Decodable {
        let id: String
        let contentDetails: ContentDetails
        let player: Player?

        struct ContentDetails: Decodable {
            let duration: String
        }

        struct Player: Decodable {
            let embedWidth: Int?
            let embedHeight: Int?

            enum CodingKeys: String, CodingKey { case embedWidth, embedHeight }

            // The API documents these as numbers but sends them as strings.
            init(from decoder: Decoder) throws {
                let values = try decoder.container(keyedBy: CodingKeys.self)
                func flexibleInt(_ key: CodingKeys) -> Int? {
                    if let int = try? values.decode(Int.self, forKey: key) { return int }
                    return (try? values.decode(String.self, forKey: key)).flatMap(Int.init)
                }
                embedWidth = flexibleInt(.embedWidth)
                embedHeight = flexibleInt(.embedHeight)
            }
        }
    }
}

private struct ThumbnailSet: Decodable {
    let `default`: Thumbnail?
    let medium: Thumbnail?
    let high: Thumbnail?
    let standard: Thumbnail?
    let maxres: Thumbnail?

    var bestURL: URL? {
        (maxres ?? standard ?? high ?? medium ?? `default`)?.url
    }
}

private struct Thumbnail: Decodable {
    let url: URL
}

private extension JSONDecoder {
    static var youtube: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
