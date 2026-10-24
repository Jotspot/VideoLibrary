import Darwin
import Foundation

enum YtDlpError: Error, LocalizedError {
    case binaryNotFound
    case ffmpegNotFound
    case outputDirectoryUnavailable(String)
    case cookieCacheUnavailable(String)
    case youtubeAuthenticationRequired
    case nonZeroExit(Int32, String)
    case invalidOutput

    var errorDescription: String? {
        switch self {
        case .binaryNotFound:
            "yt-dlp not found. Install via: brew install yt-dlp"
        case .ffmpegNotFound:
            "ffmpeg not found. Install via: brew install ffmpeg"
        case .outputDirectoryUnavailable(let path):
            "The selected library folder is unavailable or not writable: \(path)"
        case .cookieCacheUnavailable(let path):
            "Could not create the cookie cache at: \(path)"
        case .youtubeAuthenticationRequired:
            "YouTube requires sign-in verification. Choose the browser where you are signed in under Browser Cookies, then retry."
        case .nonZeroExit(let code, let output):
            "yt-dlp exited with code \(code). Output: \(output)"
        case .invalidOutput:
            "Failed to parse yt-dlp output."
        }
    }
}

enum BrowserCookieSource: String, CaseIterable, Identifiable, Sendable {
    case none
    case safari
    case chrome
    case firefox
    case brave
    case edge
    case chromium
    case opera
    case vivaldi

    var id: String { rawValue }

    var label: String {
        switch self {
        case .none: "None"
        case .safari: "Safari"
        case .chrome: "Google Chrome"
        case .firefox: "Firefox"
        case .brave: "Brave"
        case .edge: "Microsoft Edge"
        case .chromium: "Chromium"
        case .opera: "Opera"
        case .vivaldi: "Vivaldi"
        }
    }

    var ytdlpValue: String? {
        self == .none ? nil : rawValue
    }
}

enum DownloadResolution: String, CaseIterable, Identifiable, Sendable {
    case best
    case p2160
    case p1440
    case p1080
    case p720
    case p480

    var id: String { rawValue }

    var label: String {
        switch self {
        case .best: "Best Available"
        case .p2160: "2160p"
        case .p1440: "1440p"
        case .p1080: "1080p"
        case .p720: "720p"
        case .p480: "480p"
        }
    }

    var maxHeight: Int? {
        switch self {
        case .best: nil
        case .p2160: 2160
        case .p1440: 1440
        case .p1080: 1080
        case .p720: 720
        case .p480: 480
        }
    }
}

enum DownloadQuality: String, CaseIterable, Identifiable, Sendable {
    case best
    case balanced
    case smallerFile

    var id: String { rawValue }

    var label: String {
        switch self {
        case .best: "Best"
        case .balanced: "Balanced"
        case .smallerFile: "Smaller File"
        }
    }

    var helpText: String {
        switch self {
        case .best:
            "Uses the best H.264 MP4 stream within the selected resolution."
        case .balanced:
            "Prefers 30 fps H.264 MP4 when available to keep downloads smaller."
        case .smallerFile:
            "Prefers 30 fps and caps best-available downloads at 720p."
        }
    }
}

struct DownloadProgress: Sendable {
    let downloaded: Int64
    let total: Int64
    let speed: Double
}

enum DownloadEvent: Sendable {
    /// shortSide: the chosen format's short side (360 for 640×360), if known.
    case info(VideoItem, totalBytes: Int64, shortSide: Int?)
    case progress(DownloadProgress)
    case filePath(String)
    case postProcessing
    /// yt-dlp warned that YouTube is serving SABR-only streams, so HD
    /// formats may be missing (the result can fall back to 360p).
    case sabrDetected
}

// Raw JSON shape emitted by yt-dlp's before-download print hook.
private struct YtDlpFormatJSON: Decodable {
    let filesize: Int64?
    let filesize_approx: Int64?
    /// Average bitrate in kbit/s; used when no size is listed.
    let tbr: Double?
    let `protocol`: String?

    /// HLS sizes are guessed from the advertised peak bitrate and come out
    /// two or three times too big (540 MB for a 220 MB video).
    var isHLS: Bool { `protocol`?.contains("m3u8") ?? false }

    func estimatedBytes(duration: Double?) -> Int64 {
        if let size = filesize ?? filesize_approx { return size }
        guard let tbr, let duration, tbr > 0, duration > 0 else { return 0 }
        return Int64(tbr * 1000 / 8 * duration)
    }
}

private struct YtDlpInfoJSON: Decodable {
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
    let filesize: Int64?
    let filesize_approx: Int64?
    let tbr: Double?
    let width: Int?
    let height: Int?
    let `protocol`: String?
    let requested_formats: [YtDlpFormatJSON]?

    var shortSide: Int? {
        let w = width ?? 0, h = height ?? 0
        guard w > 0 || h > 0 else { return nil }
        return min(w > 0 ? w : h, h > 0 ? h : w)
    }

    /// 0 (unknown) for HLS: its estimates are far off, and the download's
    /// own fragment-based estimate takes over once it starts.
    var estimatedBytes: Int64 {
        if `protocol`?.contains("m3u8") == true { return 0 }
        if let requested_formats {
            if requested_formats.contains(where: \.isHLS) { return 0 }
            return requested_formats.reduce(0) { $0 + $1.estimatedBytes(duration: duration) }
        }
        if let size = filesize ?? filesize_approx { return size }
        guard let tbr, let duration, tbr > 0, duration > 0 else { return 0 }
        return Int64(tbr * 1000 / 8 * duration)
    }
}

private struct StreamDownloadProgress {
    let downloaded: Int64
    let total: Int64
    let speed: Double
    /// For fragmented (HLS/DASH) downloads; nil otherwise.
    var fragmentIndex: Int? = nil
    var fragmentCount: Int? = nil
}

private struct DownloadProgressAccumulator {
    var expectedTotal: Int64 = 0
    private var completedBytes: Int64 = 0
    private var previousDownloaded: Int64 = 0
    private var previousStreamTotal: Int64 = 0

    private var previousFragmentIndex: Int?

    mutating func update(_ stream: StreamDownloadProgress) -> DownloadProgress {
        // A new stream (e.g. audio after video) starts from zero. With
        // fragments the byte count can also dip within one stream (fragments
        // download 4 at a time), so only a restart of the fragment count
        // means a new stream; counting each dip made the size grow forever.
        let isNewStream: Bool
        if let index = stream.fragmentIndex, let previous = previousFragmentIndex {
            isNewStream = index < previous
        } else {
            isNewStream = stream.downloaded < previousDownloaded
        }
        if isNewStream {
            completedBytes += max(previousStreamTotal, previousDownloaded)
            previousStreamTotal = 0
            previousDownloaded = 0
        }
        previousFragmentIndex = stream.fragmentIndex

        previousDownloaded = max(previousDownloaded, stream.downloaded)
        // Fragment-based totals are re-estimated as they go; take the latest.
        previousStreamTotal = stream.fragmentIndex == nil ? max(previousStreamTotal, stream.total) : stream.total
        let downloaded = completedBytes + previousDownloaded
        // 0 = size genuinely unknown (shown as an indeterminate bar rather
        // than a fake 100%).
        guard expectedTotal > 0 || stream.total > 0 else {
            return DownloadProgress(downloaded: downloaded, total: 0, speed: stream.speed)
        }
        // yt-dlp's up-front estimate for streamed formats can be far off
        // (540 MB estimated for a 200 MB file), so the fragment-based
        // estimate wins once it exists.
        let streamTotal = completedBytes + previousStreamTotal
        if let index = stream.fragmentIndex, let count = stream.fragmentCount, expectedTotal == 0 {
            // The first few fragments (4 download at once) give wild
            // guesses; show no size until the estimate has settled.
            guard index >= min(10, max(1, count / 2)), previousStreamTotal > 0 else {
                return DownloadProgress(downloaded: downloaded, total: 0, speed: stream.speed)
            }
        }
        let total = stream.fragmentIndex != nil && previousStreamTotal > 0
            ? max(streamTotal, downloaded)
            : max(expectedTotal, streamTotal, downloaded)
        return DownloadProgress(downloaded: downloaded, total: total, speed: stream.speed)
    }
}

actor YtDlpService {
    nonisolated private static let infoPrefix = "video-library-info:"
    nonisolated private static let progressPrefix = "video-library-progress:"
    nonisolated private static let filePrefix = "video-library-file:"
    nonisolated private static let infoFields = [
        "id", "title", "uploader", "uploader_id", "upload_date", "duration", "description", "tags",
        "view_count", "like_count", "filesize", "filesize_approx", "tbr", "width", "height", "protocol",
        "format_id", "requested_formats"
    ].joined(separator: ",")

    // All stored properties are immutable — nonisolated lets them be read from any context.
    nonisolated let ytdlpPath: String
    nonisolated let ffmpegPath: String
    nonisolated private let outputRoot: URL
    nonisolated private let javaScriptRuntimeArguments: [String]

    init(outputRoot: URL) throws {
        // External tools are never bundled — they come from Homebrew (or another
        // standard install location) so `brew upgrade` keeps them current.
        guard let path = Self.findExecutable(named: "yt-dlp") else {
            throw YtDlpError.binaryNotFound
        }
        self.ytdlpPath = path

        guard let ff = Self.findExecutable(named: "ffmpeg") else {
            throw YtDlpError.ffmpegNotFound
        }
        self.ffmpegPath = ff

        self.javaScriptRuntimeArguments = Self.findJavaScriptRuntime().map {
            ["--js-runtimes", $0]
        } ?? []

        self.outputRoot = outputRoot.standardizedFileURL
        if self.outputRoot.path.hasPrefix("/Volumes/"),
           !FileManager.default.fileExists(atPath: self.outputRoot.path) {
            throw YtDlpError.outputDirectoryUnavailable(self.outputRoot.path)
        }
        do {
            try FileManager.default.createDirectory(
                at: self.outputRoot,
                withIntermediateDirectories: true
            )
        } catch {
            throw YtDlpError.outputDirectoryUnavailable(self.outputRoot.path)
        }
        guard FileManager.default.isWritableFile(atPath: self.outputRoot.path) else {
            throw YtDlpError.outputDirectoryUnavailable(self.outputRoot.path)
        }
        DebugLog.write(
            "Initialized yt-dlp service. outputRoot=\(self.outputRoot.path), ytDlp=\(self.ytdlpPath), ffmpeg=\(self.ffmpegPath), jsRuntime=\(self.javaScriptRuntimeArguments.joined(separator: " "))",
            category: "yt-dlp"
        )
    }

    nonisolated private func parseInfo(line: String) throws -> (VideoItem, Int64, Int?)? {
        guard line.hasPrefix(Self.infoPrefix) else { return nil }
        let jsonText = String(line.dropFirst(Self.infoPrefix.count))
        guard let data = jsonText.data(using: .utf8) else {
            throw YtDlpError.invalidOutput
        }
        let raw = try JSONDecoder().decode(YtDlpInfoJSON.self, from: data)

        var uploadDate: Date? = nil
        if let dateStr = raw.upload_date, dateStr.count == 8 {
            // YYYYMMDD
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyyMMdd"
            uploadDate = formatter.date(from: dateStr)
        }

        let item = VideoItem(
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
            status: .notDownloaded
        )
        return (item, raw.estimatedBytes, raw.shortSide)
    }

    nonisolated func download(
        url: String,
        downloadID: UUID,
        cookiesFromBrowser: BrowserCookieSource,
        rememberCookies: Bool,
        useSignIn: Bool = true,
        forceOverwrites: Bool = false,
        allowsPlaylist: Bool,
        resolution: DownloadResolution,
        quality: DownloadQuality,
        playerClient: String? = nil,
        useSABR: Bool = false
    ) -> AsyncThrowingStream<DownloadEvent, Error> {
        AsyncThrowingStream { continuation in
            let worker = Task {
                let logContext = downloadID.uuidString
                var progressAccumulator = DownloadProgressAccumulator()
                let temporaryDirectory = self.outputRoot
                    .appendingPathComponent(".VideoLibrary", isDirectory: true)
                    .appendingPathComponent("tmp", isDirectory: true)
                    .appendingPathComponent(downloadID.uuidString, isDirectory: true)
                // Relative template + `--paths home:` so yt-dlp honours the
                // separate temp path (an absolute template makes it ignore --paths).
                let outputTemplate = "%(uploader)s/%(title)s [%(id)s].%(ext)s"

                var args: [String] = [
                    // "video" fires right after format selection, before
                    // captions/thumbnails are fetched, so the title shows up
                    // immediately instead of after the subtitle step.
                    // Only the fields the app reads: the whole info dict (every
                    // format, caption track and heatmap) was ~12 MB for some
                    // videos, slow to print and parse.
                    "--print", "video:\(Self.infoPrefix)%(.{\(Self.infoFields)})j",
                    "--print", "after_move:\(Self.filePrefix)%(filepath)j",
                    "--no-simulate",
                    "--format", useSABR
                        ? self.sabrFormatSelector(resolution: resolution, quality: quality)
                        : self.formatSelector(resolution: resolution, quality: quality),
                    "--merge-output-format", "mp4",
                    "--concurrent-fragments", "4",
                    "--write-thumbnail",
                    "--convert-thumbnails", "jpg",
                    "--write-subs",
                    "--write-auto-subs",
                    "--sub-langs", "en,en-orig",
                    // Space out subtitle requests; YouTube rate-limits them with 429s.
                    "--sleep-subtitles", "2",
                    "--write-info-json",
                    "--paths", "home:\(self.outputRoot.path)",
                    "--paths", "temp:\(temporaryDirectory.path)",
                    "--progress-template",
                    "download:\(Self.progressPrefix)%(progress.downloaded_bytes)s %(progress.total_bytes)s %(progress.total_bytes_estimate)s %(progress.speed)s %(progress.fragment_index)s %(progress.fragment_count)s",
                    "--progress",
                    "--newline",
                    "--ffmpeg-location", self.ffmpegPath,
                    "--output", outputTemplate
                ]
                // --ignore-errors turns subtitle/thumbnail fetch failures (e.g.
                // HTTP 429 on captions) into warnings instead of aborting the
                // whole download. Video failures still exit non-zero, and
                // LibraryStore verifies the video file exists afterwards.
                args.append("--ignore-errors")
                args.append(allowsPlaylist ? "--yes-playlist" : "--no-playlist")
                if forceOverwrites { args.append("--force-overwrites") }
                args.append(contentsOf: self.javaScriptRuntimeArguments)
                // A different YouTube client (e.g. "tv"), and/or SABR formats
                // from the experimental build (`formats=duplicate` lists them
                // next to the regular ones).
                var youtubeArguments: [String] = []
                if useSABR { youtubeArguments.append("formats=duplicate") }
                if let playerClient { youtubeArguments.append("player_client=\(playerClient)") }
                if !youtubeArguments.isEmpty {
                    args.append(contentsOf: ["--extractor-args", "youtube:" + youtubeArguments.joined(separator: ";")])
                }
                let executable = useSABR ? SABRAddon.executableURL.path : self.ytdlpPath
                var reportedSABR = false

                // Decrypted cookies exist only for this run; re-encrypted and
                // wiped however the download ends.
                var cookieSession: CookieCache.Session?
                defer { cookieSession?.finish(keepUpdates: true) }

                do {
                    DebugLog.write(
                        "Download \(logContext) preparing. url=\(url), playlist=\(allowsPlaylist), resolution=\(resolution.rawValue), quality=\(quality.rawValue), temp=\(temporaryDirectory.path), output=\(outputTemplate)",
                        category: "yt-dlp"
                    )
                    try FileManager.default.createDirectory(
                        at: temporaryDirectory,
                        withIntermediateDirectories: true
                    )
                    let cookies = useSignIn
                        ? try self.cookieArguments(cookiesFromBrowser: cookiesFromBrowser, rememberCookies: rememberCookies)
                        : (arguments: [String](), session: nil)
                    cookieSession = cookies.session
                    args.append(contentsOf: cookies.arguments)
                    // "--" so a URL can never be read as a yt-dlp option.
                    args.append(contentsOf: ["--", url])
                    DebugLog.write(
                        "Download \(logContext) starting process: \(self.redactedArguments(args).joined(separator: " "))",
                        category: "yt-dlp"
                    )

                    for try await line in self.runProcess(arguments: args, logContext: logContext, executable: executable) {
                        try Task.checkCancellation()
                        if !reportedSABR, !useSABR, line.contains("SABR") {
                            reportedSABR = true
                            DebugLog.write("Download \(logContext) SABR detected: \(line)", category: "yt-dlp")
                            continuation.yield(.sabrDetected)
                        }
                        if let (info, totalBytes, shortSide) = try self.parseInfo(line: line) {
                            DebugLog.write(
                                "Download \(logContext) info received. id=\(info.ytdlpID), title=\(info.title), estimatedBytes=\(totalBytes)",
                                category: "yt-dlp"
                            )
                            progressAccumulator.expectedTotal = totalBytes
                            continuation.yield(.info(info, totalBytes: totalBytes, shortSide: shortSide))
                        } else if let streamProgress = self.parseProgress(line: line) {
                            continuation.yield(.progress(progressAccumulator.update(streamProgress)))
                        } else if let filePath = self.parseFilePath(line: line) {
                            DebugLog.write(
                                "Download \(logContext) file moved: \(filePath)",
                                category: "yt-dlp"
                            )
                            continuation.yield(.filePath(filePath))
                        }
                        if line.contains("[Merger]") || line.contains("[ExtractAudio]") {
                            continuation.yield(.postProcessing)
                        }
                    }
                    DebugLog.write("Download \(logContext) completed.", category: "yt-dlp")
                    self.cleanupTemporaryDownloadDirectory(temporaryDirectory)
                    continuation.finish()
                } catch is CancellationError {
                    DebugLog.write("Download \(logContext) cancelled.", category: "yt-dlp")
                    self.cleanupTemporaryDownloadDirectory(temporaryDirectory)
                    continuation.finish(throwing: CancellationError())
                } catch let YtDlpError.nonZeroExit(_, output)
                    where output.contains("Sign in to confirm") && output.contains("not a bot") {
                    DebugLog.write(
                        "Download \(logContext) failed with YouTube auth requirement. outputTail=\(output)",
                        category: "yt-dlp"
                    )
                    self.cleanupTemporaryDownloadDirectory(temporaryDirectory)
                    continuation.finish(throwing: YtDlpError.youtubeAuthenticationRequired)
                } catch {
                    DebugLog.write(
                        "Download \(logContext) failed: \(error.localizedDescription)",
                        category: "yt-dlp"
                    )
                    self.cleanupTemporaryDownloadDirectory(temporaryDirectory)
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in
                worker.cancel()
            }
        }
    }

    /// Re-fetches only the subtitles for a video whose captions failed earlier
    /// (typically HTTP 429). Writes next to the existing video file.
    nonisolated func downloadSubtitlesOnly(
        url: String,
        cookiesFromBrowser: BrowserCookieSource,
        rememberCookies: Bool,
        useSignIn: Bool = false
    ) async throws {
        var args: [String] = [
            "--skip-download",
            "--write-subs",
            "--write-auto-subs",
            "--sub-langs", "en,en-orig",
            "--no-playlist",
            "--paths", "home:\(outputRoot.path)",
            "--output", "%(uploader)s/%(title)s [%(id)s].%(ext)s"
        ]
        args.append(contentsOf: javaScriptRuntimeArguments)
        let cookies = useSignIn
            ? try cookieArguments(cookiesFromBrowser: cookiesFromBrowser, rememberCookies: rememberCookies)
            : (arguments: [String](), session: nil)
        defer { cookies.session?.finish(keepUpdates: true) }
        args.append(contentsOf: cookies.arguments)
        args.append(contentsOf: ["--", url])
        for try await _ in runProcess(arguments: args, logContext: "subtitles") {}
    }

    /// Saved (encrypted) cookies always win. Otherwise yt-dlp reads the
    /// chosen browser directly, and with "remember" on, writes what it read
    /// into a session file that gets encrypted afterwards.
    nonisolated private func cookieArguments(
        cookiesFromBrowser: BrowserCookieSource,
        rememberCookies: Bool
    ) throws -> (arguments: [String], session: CookieCache.Session?) {
        let browserArguments = cookiesFromBrowser.ytdlpValue.map { ["--cookies-from-browser", $0] } ?? []
        guard CookieCache.hasSavedCookies || (rememberCookies && !browserArguments.isEmpty) else {
            return (browserArguments, nil)
        }
        do {
            let session = try CookieCache.beginSession()
            let fromBrowser = CookieCache.hasSavedCookies ? [] : browserArguments
            return (fromBrowser + ["--cookies", session.fileURL.path], session)
        } catch {
            throw YtDlpError.cookieCacheUnavailable(SecureStore.directory.path)
        }
    }

    nonisolated func findDownloadedFiles(for item: VideoItem) -> (video: String?, thumbnail: String?, subtitles: [String: String], infoJSON: String?) {
        let references = DownloadedFileLocator.find(in: outputRoot, for: item)
        return (references.video, references.thumbnail, references.subtitles, references.infoJSON)
    }

    nonisolated func findDownloadedFiles(for item: VideoItem, preferredVideoPath: String?) -> (video: String?, thumbnail: String?, subtitles: [String: String], infoJSON: String?) {
        let references = DownloadedFileLocator.find(
            in: outputRoot,
            for: item,
            preferredVideoPath: preferredVideoPath
        )
        return (references.video, references.thumbnail, references.subtitles, references.infoJSON)
    }

    /// SABR streams only (from the experimental build), still H.264 + AAC
    /// so the app's player can play the result.
    nonisolated private func sabrFormatSelector(
        resolution: DownloadResolution,
        quality: DownloadQuality
    ) -> String {
        let maxHeight = effectiveMaxHeight(resolution: resolution, quality: quality)
        let heightFilter = maxHeight.map { "[height<=\($0)]" } ?? ""
        let fpsFilter = quality == .best ? "" : "[fps<=30]"
        let video = "bestvideo[protocol=sabr][vcodec^=avc1]\(heightFilter)"
        let audio = "bestaudio[protocol=sabr][ext=m4a]"
        return orderedUnique([
            "\(video)\(fpsFilter)+\(audio)",
            "\(video)+\(audio)",
            "\(video)+bestaudio[protocol=sabr]"
        ]).joined(separator: "/")
    }

    nonisolated private func formatSelector(
        resolution: DownloadResolution,
        quality: DownloadQuality
    ) -> String {
        let maxHeight = effectiveMaxHeight(resolution: resolution, quality: quality)
        let heightFilter = maxHeight.map { "[height<=\($0)]" } ?? ""
        let fpsFilter = quality == .best ? "" : "[fps<=30]"
        let preferredAudio = quality == .smallerFile
            ? "bestaudio[ext=m4a][abr<=128]"
            : "bestaudio[ext=m4a]"
        let fallbackAudio = "bestaudio[ext=m4a]"

        let strictVideo = "bestvideo[vcodec^=avc1][ext=mp4]\(heightFilter)\(fpsFilter)"
        let fallbackVideo = "bestvideo[vcodec^=avc1][ext=mp4]\(heightFilter)"
        let looseStrictVideo = "bestvideo[vcodec^=avc1]\(heightFilter)\(fpsFilter)"
        let looseFallbackVideo = "bestvideo[vcodec^=avc1]\(heightFilter)"
        let strictSingle = "best[ext=mp4][vcodec^=avc1]\(heightFilter)\(fpsFilter)"
        let fallbackSingle = "best[ext=mp4][vcodec^=avc1]\(heightFilter)"
        let looseSingle = "best[vcodec^=avc1]\(heightFilter)"

        return orderedUnique([
            "\(strictVideo)+\(preferredAudio)",
            "\(strictVideo)+\(fallbackAudio)",
            strictSingle,
            "\(fallbackVideo)+\(preferredAudio)",
            "\(fallbackVideo)+\(fallbackAudio)",
            fallbackSingle,
            "\(looseStrictVideo)+bestaudio",
            "\(looseFallbackVideo)+bestaudio",
            looseSingle
        ]).joined(separator: "/")
    }

    nonisolated private func effectiveMaxHeight(
        resolution: DownloadResolution,
        quality: DownloadQuality
    ) -> Int? {
        guard quality == .smallerFile else { return resolution.maxHeight }
        return min(resolution.maxHeight ?? 720, 720)
    }

    nonisolated private func orderedUnique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }

    nonisolated private func cleanupTemporaryDownloadDirectory(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    nonisolated private func parseFilePath(line: String) -> String? {
        guard line.hasPrefix(Self.filePrefix) else { return nil }
        let rawPath = String(line.dropFirst(Self.filePrefix.count))
        if let data = rawPath.data(using: .utf8),
           let decodedPath = try? JSONDecoder().decode(String.self, from: data) {
            return decodedPath
        }
        return rawPath.isEmpty ? nil : rawPath
    }

    nonisolated private static func findJavaScriptRuntime() -> String? {
        for name in ["deno", "node"] {
            if let path = findExecutable(named: name) {
                return "\(name):\(path)"
            }
        }
        return nil
    }

    /// Finds a command-line tool installed on the system. Apps launched from
    /// Finder get a minimal PATH, so the common install locations are checked
    /// explicitly before falling back to PATH.
    nonisolated static func findExecutable(named name: String) -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let fixedDirectories = [
            "/opt/homebrew/bin",        // Homebrew (Apple Silicon)
            "/usr/local/bin",           // Homebrew (Intel) / manual installs
            "\(home)/.local/bin",       // pipx / pip --user
            "/opt/local/bin",           // MacPorts
            "/usr/bin"
        ]
        let pathDirectories = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)

        return (fixedDirectories + pathDirectories)
            .map { URL(fileURLWithPath: $0).appendingPathComponent(name).path }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    nonisolated private func parseProgress(line: String) -> StreamDownloadProgress? {
        guard line.hasPrefix(Self.progressPrefix) else { return nil }
        let parts = line.dropFirst(Self.progressPrefix.count).split(separator: " ")
        guard parts.count >= 4 else { return nil }
        // yt-dlp prints estimates as decimals ("4410123.5"); "NA" when unknown.
        func bytes(_ part: Substring) -> Int64? {
            Double(part).flatMap { $0.isFinite && $0 > 0 ? Int64($0) : nil }
        }
        let downloaded = bytes(parts[0]) ?? 0
        var total = bytes(parts[1]) ?? bytes(parts[2]) ?? 0
        // Streamed (HLS/DASH fragment) downloads, e.g. Nebula: extrapolate
        // from how many fragments are done.
        var fragmentIndex: Int?
        var fragmentCount: Int?
        if parts.count >= 6, let index = Double(parts[4]), let count = Double(parts[5]), index >= 0, count > 0 {
            fragmentIndex = Int(index)
            fragmentCount = Int(count)
            if total == 0, downloaded > 0, index > 0 {
                total = Int64(Double(downloaded) * count / index)
            }
        }
        let speed = Double(parts[3]) ?? 0
        return StreamDownloadProgress(downloaded: downloaded, total: total, speed: speed,
                                      fragmentIndex: fragmentIndex, fragmentCount: fragmentCount)
    }

    nonisolated private func redactedArguments(_ arguments: [String]) -> [String] {
        var redacted = arguments
        for index in redacted.indices {
            if ["--cookies", "--cookies-from-browser"].contains(redacted[index]),
               redacted.indices.contains(index + 1) {
                redacted[index + 1] = redacted[index] == "--cookies"
                    ? "<cookies-file>"
                    : "<browser>"
            }
        }
        return redacted
    }

    nonisolated private func runProcess(
        arguments: [String],
        logContext: String,
        executable: String? = nil
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            final class ProcessHandle: @unchecked Sendable {
                let process = Process()
                private let lock = NSLock()
                private var terminationRequested = false

                func requestTermination() {
                    lock.lock()
                    terminationRequested = true
                    lock.unlock()

                    guard process.isRunning else { return }
                    process.terminate()
                    DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [weak self] in
                        guard let self, self.process.isRunning else { return }
                        kill(self.process.processIdentifier, SIGKILL)
                    }
                }

                var wasTerminationRequested: Bool {
                    lock.lock()
                    defer { lock.unlock() }
                    return terminationRequested
                }
            }

            let processHandle = ProcessHandle()
            let process = processHandle.process
            process.executableURL = URL(fileURLWithPath: executable ?? self.ytdlpPath)
            process.arguments = arguments

            let stdoutPipe = Pipe()
            process.standardOutput = stdoutPipe
            // yt-dlp writes progress and post-processing status to stderr.
            // Drain both streams continuously to avoid blocking on a full pipe.
            process.standardError = stdoutPipe

            // Shared mutable state accessed only from readabilityHandler (serial GCD
            // source) and terminationHandler (runs after readabilityHandler is nil'd).
            // No concurrent access occurs — @unchecked Sendable is warranted.
            final class LineBuffer: @unchecked Sendable {
                var value = ""
                var outputTail = ""
                var progressLineCount = 0

                func append(_ text: String) -> [String] {
                    value += text
                    outputTail += text
                    outputTail = String(outputTail.suffix(64 * 1024))

                    let lines = value.components(separatedBy: "\n")
                    value = lines.last ?? ""
                    return Array(lines.dropLast().filter { !$0.isEmpty })
                }
            }
            let buf = LineBuffer()

            stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                guard let text = String(data: data, encoding: .utf8) else { return }
                for line in buf.append(text) {
                    if line.hasPrefix(Self.progressPrefix) {
                        buf.progressLineCount += 1
                        if buf.progressLineCount == 1 || buf.progressLineCount.isMultiple(of: 25) {
                            DebugLog.write(
                                "Download \(logContext) progress line: \(line)",
                                category: "yt-dlp"
                            )
                        }
                    } else if line.hasPrefix(Self.infoPrefix) {
                        // The full info JSON is huge and full of signed media
                        // URLs; the parsed summary is logged separately.
                        DebugLog.write(
                            "Download \(logContext) info JSON received (\(line.utf8.count) bytes).",
                            category: "yt-dlp"
                        )
                    } else {
                        DebugLog.write(
                            "Download \(logContext) output: \(line)",
                            category: "yt-dlp"
                        )
                    }
                    continuation.yield(line)
                }
            }

            process.terminationHandler = { p in
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                let remainingData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                if let text = String(data: remainingData, encoding: .utf8) {
                    for line in buf.append(text) {
                        continuation.yield(line)
                    }
                }
                if !buf.value.isEmpty {
                    DebugLog.write(
                        "Download \(logContext) trailing output: \(buf.value)",
                        category: "yt-dlp"
                    )
                    continuation.yield(buf.value)
                }
                DebugLog.write(
                    "Download \(logContext) process exited. status=\(p.terminationStatus), terminationReason=\(p.terminationReason.rawValue), requestedTermination=\(processHandle.wasTerminationRequested)",
                    category: "yt-dlp"
                )
                if processHandle.wasTerminationRequested {
                    continuation.finish(throwing: CancellationError())
                } else if p.terminationStatus != 0 {
                    continuation.finish(throwing: YtDlpError.nonZeroExit(
                        p.terminationStatus, buf.outputTail
                    ))
                } else {
                    continuation.finish()
                }
            }

            do {
                try process.run()
                DebugLog.write(
                    "Download \(logContext) process launched. pid=\(process.processIdentifier)",
                    category: "yt-dlp"
                )
            } catch {
                DebugLog.write(
                    "Download \(logContext) failed to launch process: \(error.localizedDescription)",
                    category: "yt-dlp"
                )
                continuation.finish(throwing: error)
            }

            continuation.onTermination = { @Sendable _ in
                DebugLog.write(
                    "Download \(logContext) stream terminated; requesting process termination if still running.",
                    category: "yt-dlp"
                )
                processHandle.requestTermination()
            }
        }
    }
}
