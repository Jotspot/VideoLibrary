import Foundation

/// Reads the user's real YouTube subscriptions feed through yt-dlp, using the
/// saved (encrypted) YouTube sign-in. No Google Cloud project or API quota.
/// Which YouTube feed to read with the sign-in.
enum YouTubeFeedKind: String, CaseIterable, Identifiable, Sendable {
    /// Uploads from subscribed channels, newest first.
    case subscriptions
    /// YouTube's personalised Home feed ("recommended for you").
    case recommended

    var id: String { rawValue }

    var label: String {
        switch self {
        case .subscriptions: "Subscriptions"
        case .recommended: "Recommended"
        }
    }

    var url: String {
        switch self {
        case .subscriptions: "https://www.youtube.com/feed/subscriptions"
        case .recommended: "https://www.youtube.com/"
        }
    }
}

enum YouTubeFeedService {
    enum FeedError: LocalizedError {
        case notSignedIn
        case toolMissing
        case signInExpired
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .notSignedIn:
                "Sign in to YouTube (or import your sign-in from a browser) to see your subscriptions."
            case .toolMissing:
                "Suggestions need yt-dlp. Install it from Settings › Tools."
            case .signInExpired:
                "Your YouTube sign-in has expired. Sign in again in Settings › Downloads."
            case .failed(let message):
                "Couldn't load your subscriptions feed: \(message)"
            }
        }
    }

    static func fetchFeed(_ kind: YouTubeFeedKind, limit: Int) async throws -> [SuggestedVideo] {
        guard CookieCache.hasYouTubeSignIn else { throw FeedError.notSignedIn }
        return try await fetch(target: kind.url, limit: limit, useSignIn: true)
    }

    /// Searches YouTube. Uses the sign-in when there is one (age-restricted
    /// results, personalisation), but works without it.
    static func search(_ query: String, limit: Int = 40) async throws -> [SuggestedVideo] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        return try await fetch(target: "ytsearch\(limit):\(trimmed)", limit: limit, useSignIn: CookieCache.hasYouTubeSignIn)
    }

    private static func fetch(target: String, limit: Int, useSignIn: Bool) async throws -> [SuggestedVideo] {
        guard let ytdlp = YtDlpService.findExecutable(named: "yt-dlp") else { throw FeedError.toolMissing }

        let videos = try await Task.detached(priority: .userInitiated) {
            let session = useSignIn ? try CookieCache.beginSession() : nil
            defer { session?.finish(keepUpdates: true) }

            var arguments = session.map { ["--cookies", $0.fileURL.path] } ?? []
            arguments += [
                "--flat-playlist",
                "--dump-single-json",
                "--playlist-end", String(limit),
                "--extractor-args", "youtubetab:approximate_date",
                "--no-warnings"
            ]
            if let runtime = ["deno", "node"].lazy.compactMap({ name in
                YtDlpService.findExecutable(named: name).map { "\(name):\($0)" }
            }).first {
                arguments += ["--js-runtimes", runtime]
            }
            arguments += ["--", target]

            let (status, stdout, stderr) = try run(ytdlp, arguments)
            guard status == 0, let data = stdout.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                let message = stderr.split(separator: "\n").last { $0.contains("ERROR") }.map(String.init)
                    ?? stderr.split(separator: "\n").last.map(String.init) ?? "yt-dlp exited with \(status)"
                if useSignIn, message.localizedCaseInsensitiveContains("sign in") || message.contains("cookies") {
                    throw FeedError.signInExpired
                }
                throw FeedError.failed(DebugLog.redact(message))
            }
            let entries = json["entries"] as? [[String: Any]] ?? []
            if let first = entries.first {
                DebugLog.write("Feed entry fields: \(first.keys.sorted().joined(separator: ","))", category: "youtube")
            }
            return entries.compactMap(video(from:))
        }.value
        return await ShortsDetector.markShorts(in: videos)
    }

    private static func video(from entry: [String: Any]) -> SuggestedVideo? {
        guard let id = entry["id"] as? String, !id.isEmpty,
              let title = entry["title"] as? String else { return nil }
        // Skip upcoming premieres and live streams; there's nothing to download yet.
        if let live = entry["live_status"] as? String, live == "is_upcoming" || live == "is_live" { return nil }

        let url = entry["url"] as? String ?? ""
        let duration = (entry["duration"] as? NSNumber)?.doubleValue
        // A /shorts/ link is definitive; anything 3 min or shorter is checked
        // by ShortsDetector, since feeds don't always mark Shorts.
        let isShort: Bool? = url.contains("/shorts/") ? true
            : (duration.map { $0 > 180 } == true ? false : nil)

        let thumbnails = (entry["thumbnails"] as? [[String: Any]] ?? [])
            .compactMap { thumb -> (URL, Int)? in
                guard let raw = thumb["url"] as? String, let url = URL(string: raw) else { return nil }
                return (url, (thumb["width"] as? Int ?? 0) * (thumb["height"] as? Int ?? 0))
            }
            .max { $0.1 < $1.1 }?.0
            ?? URL(string: "https://i.ytimg.com/vi/\(id)/hqdefault.jpg")

        let timestamp = (entry["timestamp"] as? NSNumber)?.doubleValue
        var video = SuggestedVideo(
            id: id,
            title: title,
            channelTitle: entry["channel"] as? String ?? entry["uploader"] as? String ?? "",
            channelID: entry["channel_id"] as? String ?? "",
            thumbnailURL: thumbnails,
            publishedAt: timestamp.map { Date(timeIntervalSince1970: $0) },
            duration: duration,
            source: .subscription
        )
        video.isVerticalShort = isShort
        return video
    }

    private static func run(_ executable: String, _ arguments: [String]) throws -> (Int32, String, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        // Drain stderr concurrently so a full pipe can't deadlock the process.
        var stderrData = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            stderrData = err.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        let stdoutData = out.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        process.waitUntilExit()
        return (process.terminationStatus,
                String(decoding: stdoutData, as: UTF8.self),
                String(decoding: stderrData, as: UTF8.self))
    }
}

/// Tells Shorts from regular videos: youtube.com/shorts/<id> answers 200 for
/// a Short and redirects to /watch for anything else. It must look like a
/// desktop browser — YouTube sends other clients to m.youtube.com for every
/// video, which made an earlier version of this check useless.
enum ShortsDetector {
    static let browserUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15"

    /// Fills in `isVerticalShort` for videos where it's still unknown.
    static func markShorts(in videos: [SuggestedVideo]) async -> [SuggestedVideo] {
        let candidates = videos.filter { $0.isVerticalShort == nil }.map(\.id)
        guard !candidates.isEmpty else { return videos }
        let session = URLSession(configuration: .ephemeral, delegate: NoRedirects(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        var results: [String: Bool] = [:]
        for chunk in candidates.chunked(into: 8) {
            await withTaskGroup(of: (String, Bool?).self) { group in
                for id in chunk {
                    group.addTask { (id, await isShort(id, session: session)) }
                }
                for await (id, value) in group {
                    if let value { results[id] = value }
                }
            }
        }
        DebugLog.write("Shorts check: \(candidates.count) checked, \(results.values.filter { $0 }.count) Shorts.", category: "youtube")
        return videos.map { video in
            guard video.isVerticalShort == nil, let value = results[video.id] else { return video }
            var copy = video
            copy.isVerticalShort = value
            return copy
        }
    }

    private static func isShort(_ id: String, session: URLSession) async -> Bool? {
        guard let url = URL(string: "https://www.youtube.com/shorts/\(id)") else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 10
        request.setValue(browserUserAgent, forHTTPHeaderField: "User-Agent")
        guard let (_, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse else { return nil }
        if http.statusCode == 200 { return true }
        if (300..<400).contains(http.statusCode),
           let location = http.value(forHTTPHeaderField: "Location"), location.contains("/watch") {
            return false
        }
        return nil
    }

    private final class NoRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest) async -> URLRequest? { nil }
    }
}
