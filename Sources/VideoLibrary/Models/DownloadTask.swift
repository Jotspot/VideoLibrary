import Foundation
import Observation

@Observable
final class DownloadTask: Identifiable, @unchecked Sendable {
    let id = UUID()
    var videoItem: VideoItem?
    var downloadedBytes: Int64 = 0
    var totalBytes: Int64 = 0
    var speed: Double = 0
    var isPlaylist = false
    var completedVideoCount = 0
    var phase: Phase = .fetchingInfo
    /// The site being downloaded from ("YouTube", "Nebula", …), for messages.
    var sourceName = "YouTube"
    /// Shown until yt-dlp reports the real title (e.g. known from Suggestions).
    var placeholderTitle: String?
    /// Set while retrying with the YouTube sign-in after an anonymous attempt.
    var isRetryingWithSignIn = false
    @ObservationIgnored var operation: Task<Void, Never>?
    /// Starts the same download again (set by LibraryStore.startDownload).
    @ObservationIgnored var retry: (() -> Void)?

    var progress: Double {
        guard totalBytes > 0 else { return 0 }
        return min(1.0, Double(downloadedBytes) / Double(totalBytes))
    }

    var hasDeterminateProgress: Bool {
        totalBytes > 0
    }

    /// Status line, naming the site ("Contacting Nebula…").
    var statusText: String {
        if case .fetchingInfo = phase { return "Contacting \(sourceName)…" }
        return phase.label
    }

    var percentageLabel: String {
        guard hasDeterminateProgress else {
            return downloadedBytes > 0
                ? ByteCountFormatter.string(fromByteCount: downloadedBytes, countStyle: .file)
                : "Preparing…"
        }
        return String(format: "%.0f%%", progress * 100)
    }

    var title: String {
        if isPlaylist {
            guard let title = videoItem?.title else { return "Fetching playlist info..." }
            return "Playlist: \(title)"
        }
        return videoItem?.title ?? placeholderTitle ?? "Getting video info…"
    }

    var canCancel: Bool {
        switch phase {
        case .fetchingInfo, .downloading, .postProcessing:
            true
        case .cancelling, .complete, .failed:
            false
        }
    }

    func cancel() {
        guard canCancel else { return }
        phase = .cancelling
        operation?.cancel()
    }

    enum Phase: Sendable {
        case fetchingInfo
        case downloading
        case postProcessing
        case cancelling
        case complete
        case failed(DownloadFailure)

        var label: String {
            switch self {
            case .fetchingInfo: "Contacting YouTube…"
            case .downloading: "Downloading"
            case .postProcessing: "Processing..."
            case .cancelling: "Cancelling..."
            case .complete: "Complete"
            case .failed(let failure): failure.title
            }
        }
    }

    init(videoItem: VideoItem? = nil) {
        self.videoItem = videoItem
    }
}
