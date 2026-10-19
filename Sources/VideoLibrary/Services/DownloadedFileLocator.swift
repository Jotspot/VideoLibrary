import Foundation

struct DownloadedFileReferences: Sendable {
    var video: String?
    var thumbnail: String?
    var subtitles: [String: String]
    var infoJSON: String?
}

enum DownloadedFileLocator {
    private static let videoExtensions = Set(["mp4", "m4v", "mkv", "webm", "mov", "avi"])
    private static let thumbnailExtensions = Set(["jpg", "jpeg", "webp", "png"])
    private static let subtitleExtensions = Set(["vtt", "srt", "ass", "ssa"])

    static func find(
        in root: URL,
        for item: VideoItem,
        preferredVideoPath: String? = nil
    ) -> DownloadedFileReferences {
        if let preferredVideoPath,
           FileManager.default.fileExists(atPath: preferredVideoPath) {
            return references(nearVideoPath: preferredVideoPath)
        }

        let files = filesUnder(root: root)
        let videoPath = bestVideoPath(for: item, files: files)
        guard let videoPath else {
            return DownloadedFileReferences(video: nil, thumbnail: nil, subtitles: [:], infoJSON: nil)
        }
        return references(nearVideoPath: videoPath, allFiles: files)
    }

    static func infoJSONFiles(in root: URL) -> [String] {
        filesUnder(root: root).filter {
            URL(fileURLWithPath: $0).lastPathComponent.hasSuffix(".info.json")
        }
    }

    static func references(nearInfoJSONPath infoJSONPath: String) -> DownloadedFileReferences {
        let files = siblingFiles(of: infoJSONPath)
        let infoURL = URL(fileURLWithPath: infoJSONPath)
        let directory = infoURL.deletingLastPathComponent().standardizedFileURL.path
        var baseName = infoURL.deletingPathExtension().lastPathComponent
        if baseName.hasSuffix(".info") {
            baseName.removeLast(".info".count)
        }

        guard let videoPath = files.first(where: { path in
            let url = URL(fileURLWithPath: path)
            return url.deletingLastPathComponent().standardizedFileURL.path == directory
                && videoExtensions.contains(url.pathExtension.lowercased())
                && url.deletingPathExtension().lastPathComponent == baseName
        }) else {
            return DownloadedFileReferences(
                video: nil,
                thumbnail: nil,
                subtitles: [:],
                infoJSON: infoJSONPath
            )
        }

        var references = references(nearVideoPath: videoPath, allFiles: files)
        if references.infoJSON == nil {
            references.infoJSON = infoJSONPath
        }
        return references
    }

    static func references(
        nearVideoPath videoPath: String,
        allFiles: [String]? = nil
    ) -> DownloadedFileReferences {
        let files = allFiles ?? siblingFiles(of: videoPath)
        let videoURL = URL(fileURLWithPath: videoPath)
        let videoDirectory = videoURL.deletingLastPathComponent().standardizedFileURL.path
        let baseName = videoURL.deletingPathExtension().lastPathComponent

        var thumbnail: String?
        var subtitles: [String: String] = [:]
        var infoJSON: String?

        for path in files {
            let url = URL(fileURLWithPath: path)
            guard url.deletingLastPathComponent().standardizedFileURL.path == videoDirectory else {
                continue
            }

            let fileName = url.lastPathComponent
            guard fileName.hasPrefix(baseName) else { continue }

            let ext = url.pathExtension.lowercased()
            if thumbnail == nil, thumbnailExtensions.contains(ext) {
                thumbnail = path
            } else if subtitleExtensions.contains(ext) {
                subtitles[subtitleLanguage(from: fileName, baseName: baseName)] = path
            } else if infoJSON == nil, fileName == "\(baseName).info.json" || ext == "json" {
                infoJSON = path
            }
        }

        return DownloadedFileReferences(
            video: videoPath,
            thumbnail: thumbnail,
            subtitles: subtitles,
            infoJSON: infoJSON
        )
    }

    private static func bestVideoPath(for item: VideoItem, files: [String]) -> String? {
        let videoFiles = files.filter { videoExtensions.contains(URL(fileURLWithPath: $0).pathExtension.lowercased()) }
        if videoFiles.isEmpty { return nil }

        if let byID = videoFiles.first(where: {
            URL(fileURLWithPath: $0).lastPathComponent.contains(item.ytdlpID)
        }) {
            return byID
        }

        let normalizedTitle = normalizedMatchText(item.title)
        if let byTitle = videoFiles.first(where: {
            normalizedMatchText(URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent)
                .contains(normalizedTitle)
        }) {
            return byTitle
        }

        let normalizedUploader = normalizedMatchText(item.uploader)
        if let byUploaderAndTitle = videoFiles.first(where: {
            let url = URL(fileURLWithPath: $0)
            return normalizedMatchText(url.deletingLastPathComponent().lastPathComponent).contains(normalizedUploader)
                && normalizedMatchText(url.deletingPathExtension().lastPathComponent).contains(normalizedTitle.prefix(24))
        }) {
            return byUploaderAndTitle
        }

        return videoFiles.count == 1 ? videoFiles[0] : nil
    }

    private static func filesUnder(root: URL) -> [String] {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var paths: [String] = []
        for case let url as URL in enumerator {
            if url.lastPathComponent == ".VideoLibrary" {
                enumerator.skipDescendants()
                continue
            }
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                continue
            }
            paths.append(url.standardizedFileURL.path)
        }
        return paths
    }

    private static func siblingFiles(of path: String) -> [String] {
        let directory = URL(fileURLWithPath: path).deletingLastPathComponent()
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey]
        ) else {
            return []
        }
        return urls
            .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
            .map { $0.standardizedFileURL.path }
    }

    private static func subtitleLanguage(from fileName: String, baseName: String) -> String {
        let suffix = fileName
            .dropFirst(baseName.count)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let parts = suffix.split(separator: ".").map(String.init)
        return parts.first ?? "und"
    }

    private static func normalizedMatchText(_ text: String) -> String {
        text
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
            .filter { $0.isLetter || $0.isNumber }
    }
}
