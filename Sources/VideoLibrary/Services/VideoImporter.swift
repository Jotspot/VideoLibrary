import AVFoundation
import AppKit
import Foundation

/// Adds video files that weren't downloaded with yt-dlp (your own recordings,
/// files from elsewhere) to a library. Title = file name, thumbnail = an
/// early frame, resolution and length read from the file.
enum VideoImporter {
    struct Result: Sendable {
        var items: [VideoItem] = []
        /// Files macOS can't play (e.g. MKV, WebM) and were skipped.
        var unplayable: [String] = []
        var failed: [String] = []
    }

    /// - copy: true puts a copy in `{library}/Imported/`; false leaves the file where it is.
    static func importFiles(
        _ urls: [URL],
        into libraryRoot: URL,
        copy: Bool,
        progress: @escaping @Sendable (Int, Int) -> Void
    ) async -> Result {
        let fm = FileManager.default
        let dataDirectory = libraryRoot.appendingPathComponent(".VideoLibrary/imported", isDirectory: true)
        try? fm.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
        let importFolder = libraryRoot.appendingPathComponent("Imported", isDirectory: true)

        var result = Result()
        for (index, source) in urls.enumerated() {
            progress(index + 1, urls.count)
            let asset = AVURLAsset(url: source)
            guard (try? await asset.load(.isPlayable)) == true else {
                result.unplayable.append(source.lastPathComponent)
                continue
            }

            var videoURL = source
            if copy {
                do {
                    try fm.createDirectory(at: importFolder, withIntermediateDirectories: true)
                    videoURL = uniqueURL(for: source.lastPathComponent, in: importFolder)
                    try fm.copyItem(at: source, to: videoURL)
                } catch {
                    result.failed.append(source.lastPathComponent)
                    continue
                }
            }

            let id = UUID()
            let playable = AVURLAsset(url: videoURL)
            let duration = (try? await playable.load(.duration)).map(\.seconds) ?? 0
            var size = CGSize.zero
            if let track = try? await playable.loadTracks(withMediaType: .video).first,
               let natural = try? await track.load(.naturalSize),
               let transform = try? await track.load(.preferredTransform) {
                let rotated = natural.applying(transform)
                size = CGSize(width: abs(rotated.width), height: abs(rotated.height))
            }

            // Thumbnail: a frame about a second in (the very first frame is
            // often black), or the start for very short clips.
            let thumbnailURL = dataDirectory.appendingPathComponent("\(id.uuidString).jpg")
            let generator = AVAssetImageGenerator(asset: playable)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 1280, height: 1280)
            let frameTime = CMTime(seconds: min(1, max(0, duration * 0.1)), preferredTimescale: 600)
            if let (image, _) = try? await generator.image(at: frameTime) {
                let rep = NSBitmapImageRep(cgImage: image)
                try? rep.representation(using: .jpeg, properties: [.compressionFactor: 0.8])?
                    .write(to: thumbnailURL, options: .atomic)
            }

            // Small info file so the library shows a quality badge (not .info.json,
            // so it's never mistaken for a yt-dlp download).
            let infoURL = dataDirectory.appendingPathComponent("\(id.uuidString).json")
            let info: [String: Any] = ["width": Int(size.width), "height": Int(size.height), "format_id": "local"]
            try? JSONSerialization.data(withJSONObject: info).write(to: infoURL, options: .atomic)

            let values = try? videoURL.resourceValues(forKeys: [.creationDateKey, .fileSizeKey])
            result.items.append(VideoItem(
                id: id,
                ytdlpID: "local-\(id.uuidString)",
                title: source.deletingPathExtension().lastPathComponent,
                uploader: "Imported",
                uploaderID: "imported",
                uploadDate: values?.creationDate,
                duration: duration.isFinite ? duration : 0,
                videoFilePath: videoURL.path,
                thumbnailPath: fm.fileExists(atPath: thumbnailURL.path) ? thumbnailURL.path : nil,
                infoJSONPath: infoURL.path,
                status: .downloaded,
                videoFileSize: values?.fileSize.map(Int64.init)
            ))
        }
        return result
    }

    private static func uniqueURL(for name: String, in folder: URL) -> URL {
        var candidate = folder.appendingPathComponent(name)
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(base) \(counter)" + (ext.isEmpty ? "" : ".\(ext)"))
            counter += 1
        }
        return candidate
    }
}
