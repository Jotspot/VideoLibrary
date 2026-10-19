import Foundation

struct SuggestedVideo: Identifiable, Codable, Sendable, Hashable {
    var id: String
    var title: String
    var channelTitle: String
    var channelID: String
    var thumbnailURL: URL?
    var publishedAt: Date?
    var duration: TimeInterval?
    var source: SuggestionSource
    /// Vertical video of 3 minutes or less, i.e. a YouTube Short. nil when
    /// the API didn't report the player shape (or for old cached entries).
    var isVerticalShort: Bool?

    var looksLikeShort: Bool {
        if isVerticalShort == true { return true }
        if title.localizedCaseInsensitiveContains("#short") { return true }
        guard isVerticalShort == nil, let duration else { return false }
        return duration <= 60
    }

    var youtubeURL: URL {
        var components = URLComponents(string: "https://www.youtube.com/watch")!
        components.queryItems = [URLQueryItem(name: "v", value: id)]
        return components.url ?? URL(string: "https://www.youtube.com")!
    }

    enum SuggestionSource: String, Codable, Sendable {
        case subscription
        case libraryChannel
    }
}

extension SuggestedVideo {
    func formattedDuration() -> String? {
        guard let duration, duration.isFinite, duration >= 0, duration < 1_000_000_000 else { return nil }
        let total = Int(duration)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%d:%02d", m, s)
    }

    func formattedPublishedDate(referenceDate: Date = Date()) -> String? {
        guard let publishedAt else { return nil }
        let calendar = Calendar.current
        if calendar.isDateInToday(publishedAt) {
            return "Today"
        }
        if calendar.isDateInYesterday(publishedAt) {
            return "Yesterday"
        }

        let formatter = DateFormatter()
        formatter.dateStyle = calendar.component(.year, from: publishedAt) == calendar.component(.year, from: referenceDate)
            ? .medium
            : .long
        formatter.timeStyle = .none
        return formatter.string(from: publishedAt)
    }

    func formattedEstimatedFileSize(
        resolution: DownloadResolution,
        quality: DownloadQuality
    ) -> String? {
        guard let bytes = estimatedFileSizeBytes(resolution: resolution, quality: quality) else {
            return nil
        }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func estimatedFileSizeBytes(
        resolution: DownloadResolution,
        quality: DownloadQuality
    ) -> Int64? {
        guard let duration, duration > 0 else { return nil }
        let effectiveHeight: Int
        if quality == .smallerFile {
            effectiveHeight = min(resolution.maxHeight ?? 720, 720)
        } else {
            effectiveHeight = resolution.maxHeight ?? 1080
        }

        let videoMbps: Double
        switch effectiveHeight {
        case 0...480:
            videoMbps = 0.9
        case 481...720:
            videoMbps = 1.8
        case 721...1080:
            videoMbps = 3.0
        case 1081...1440:
            videoMbps = 6.5
        default:
            videoMbps = 13.0
        }

        let qualityMultiplier: Double
        switch quality {
        case .best:
            qualityMultiplier = 1.25
        case .balanced:
            qualityMultiplier = 1.0
        case .smallerFile:
            qualityMultiplier = 0.7
        }

        let audioMbps = 0.128
        let totalMbps = videoMbps * qualityMultiplier + audioMbps
        return Int64((totalMbps * 1_000_000 / 8) * duration)
    }
}
