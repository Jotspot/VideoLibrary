import Foundation

struct VideoItem: Identifiable, Codable, Sendable, Hashable {
    var id: UUID
    var ytdlpID: String
    var title: String
    var uploader: String
    var uploaderID: String
    var uploadDate: Date?
    var duration: TimeInterval
    var description: String
    var tags: [String]
    var viewCount: Int?
    var likeCount: Int?

    var videoFilePath: String?
    var thumbnailPath: String?
    var subtitlePaths: [String: String]
    var infoJSONPath: String?
    var status: DownloadStatus
    var watchProgress: TimeInterval
    var videoFileSize: Int64?
    var dateAdded: Date

    var videoURL: URL? { videoFilePath.flatMap { URL(fileURLWithPath: $0) } }
    var thumbnailURL: URL? { thumbnailPath.flatMap { URL(fileURLWithPath: $0) } }

    enum DownloadStatus: String, Codable, Sendable {
        case notDownloaded, downloading, downloaded, failed
    }

    init(
        id: UUID = UUID(),
        ytdlpID: String,
        title: String,
        uploader: String,
        uploaderID: String,
        uploadDate: Date? = nil,
        duration: TimeInterval,
        description: String = "",
        tags: [String] = [],
        viewCount: Int? = nil,
        likeCount: Int? = nil,
        videoFilePath: String? = nil,
        thumbnailPath: String? = nil,
        subtitlePaths: [String: String] = [:],
        infoJSONPath: String? = nil,
        status: DownloadStatus = .notDownloaded,
        watchProgress: TimeInterval = 0,
        videoFileSize: Int64? = nil,
        dateAdded: Date = Date()
    ) {
        self.id = id
        self.ytdlpID = ytdlpID
        self.title = title
        self.uploader = uploader
        self.uploaderID = uploaderID
        self.uploadDate = uploadDate
        self.duration = duration
        self.description = description
        self.tags = tags
        self.viewCount = viewCount
        self.likeCount = likeCount
        self.videoFilePath = videoFilePath
        self.thumbnailPath = thumbnailPath
        self.subtitlePaths = subtitlePaths
        self.infoJSONPath = infoJSONPath
        self.status = status
        self.watchProgress = watchProgress
        self.videoFileSize = videoFileSize
        self.dateAdded = dateAdded
    }

    private enum CodingKeys: String, CodingKey {
        case id, ytdlpID, title, uploader, uploaderID, uploadDate, duration
        case description, tags, viewCount, likeCount, videoFilePath, thumbnailPath
        case subtitlePaths, infoJSONPath, status, watchProgress, videoFileSize, dateAdded
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        ytdlpID = try values.decode(String.self, forKey: .ytdlpID)
        title = try values.decode(String.self, forKey: .title)
        uploader = try values.decode(String.self, forKey: .uploader)
        uploaderID = try values.decode(String.self, forKey: .uploaderID)
        uploadDate = try values.decodeIfPresent(Date.self, forKey: .uploadDate)
        duration = try values.decode(TimeInterval.self, forKey: .duration)
        description = try values.decode(String.self, forKey: .description)
        tags = try values.decode([String].self, forKey: .tags)
        viewCount = try values.decodeIfPresent(Int.self, forKey: .viewCount)
        likeCount = try values.decodeIfPresent(Int.self, forKey: .likeCount)
        videoFilePath = try values.decodeIfPresent(String.self, forKey: .videoFilePath)
        thumbnailPath = try values.decodeIfPresent(String.self, forKey: .thumbnailPath)
        subtitlePaths = try values.decode([String: String].self, forKey: .subtitlePaths)
        infoJSONPath = try values.decodeIfPresent(String.self, forKey: .infoJSONPath)
        status = try values.decode(DownloadStatus.self, forKey: .status)
        watchProgress = try values.decodeIfPresent(TimeInterval.self, forKey: .watchProgress) ?? 0
        videoFileSize = try values.decodeIfPresent(Int64.self, forKey: .videoFileSize)
        dateAdded = try values.decodeIfPresent(Date.self, forKey: .dateAdded)
            ?? uploadDate
            ?? Date(timeIntervalSince1970: 0)
    }
}

extension VideoItem {
    func formattedDuration() -> String {
        // Int(_:) traps on NaN/infinity, which a bad info.json could contain.
        guard duration.isFinite, duration >= 0, duration < 1_000_000_000 else { return "--:--" }
        let total = Int(duration)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%d:%02d", m, s)
    }

    var watchProgressFraction: Double {
        guard duration > 0 else { return 0 }
        return min(1, max(0, watchProgress / duration))
    }

    var formattedVideoFileSize: String? {
        let bytes = videoFileSize ?? videoFilePath.flatMap {
            let attrs = try? FileManager.default.attributesOfItem(atPath: $0)
            return (attrs?[.size] as? NSNumber)?.int64Value
        }
        guard let bytes else { return nil }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
