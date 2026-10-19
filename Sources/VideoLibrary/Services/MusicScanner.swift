import AVFoundation
import CryptoKit
import Foundation

/// Reads song files: finds audio in a folder, pulls tags and embedded cover
/// art through AVFoundation (ID3 for MP3, iTunes atoms for M4A/AAC/ALAC),
/// and falls back to "Artist - Title" file names when tags are missing.
enum MusicScanner {
    static let audioExtensions: Set<String> = ["mp3", "m4a", "aac", "alac", "wav", "aif", "aiff", "caf", "flac"]

    struct ScannedTrack: Sendable {
        let path: String
        let title: String
        let artist: String
        let album: String
        let albumArtist: String
        let trackNumber: Int?
        let discNumber: Int?
        let genre: String
        let year: Int?
        let duration: TimeInterval
        let artworkFile: String?
        let fileModified: Date?
    }

    /// Every audio file under `folder` (recursively), sorted by path.
    static func audioFiles(in folder: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }
        var files: [URL] = []
        for case let url as URL in enumerator where audioExtensions.contains(url.pathExtension.lowercased()) {
            files.append(url)
        }
        return files.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    /// Reads several files concurrently (8 at a time).
    static func scan(_ files: [URL], artworkDirectory: URL) async -> [ScannedTrack] {
        try? FileManager.default.createDirectory(at: artworkDirectory, withIntermediateDirectories: true)
        var results: [ScannedTrack] = []
        for start in stride(from: 0, to: files.count, by: 8) {
            let chunk = files[start..<min(start + 8, files.count)]
            await withTaskGroup(of: ScannedTrack?.self) { group in
                for file in chunk {
                    group.addTask { await scan(file, artworkDirectory: artworkDirectory) }
                }
                for await track in group {
                    if let track { results.append(track) }
                }
            }
        }
        return results
    }

    static func scan(_ url: URL, artworkDirectory: URL) async -> ScannedTrack? {
        let asset = AVURLAsset(url: url)
        let metadata = (try? await asset.load(.metadata)) ?? []
        let duration = (try? await asset.load(.duration)).map(\.seconds) ?? 0

        func string(_ identifiers: AVMetadataIdentifier...) async -> String? {
            for identifier in identifiers {
                for item in AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: identifier) {
                    if let value = try? await item.load(.stringValue)?.trimmingCharacters(in: .whitespacesAndNewlines),
                       !value.isEmpty {
                        return value
                    }
                }
            }
            return nil
        }
        func number(_ identifiers: AVMetadataIdentifier...) async -> Int? {
            for identifier in identifiers {
                for item in AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: identifier) {
                    // ID3 text like "3" or "3/12".
                    if let text = try? await item.load(.stringValue),
                       let value = Int(text.split(separator: "/").first.map(String.init) ?? text) {
                        return value
                    }
                    // iTunes "trkn"/"disk": [0, 0, number(2 bytes), total(2 bytes), …].
                    if let data = try? await item.load(.dataValue), data.count >= 4 {
                        let value = Int(data[data.startIndex + 2]) << 8 | Int(data[data.startIndex + 3])
                        if value > 0 { return value }
                    }
                    if let value = try? await item.load(.numberValue)?.intValue, value > 0 {
                        return value
                    }
                }
            }
            return nil
        }

        // File name fallback: "Artist - Title.mp3".
        let baseName = url.deletingPathExtension().lastPathComponent
        let nameParts = baseName.components(separatedBy: " - ")
        let fallbackArtist = nameParts.count >= 2 ? nameParts[0] : ""
        let fallbackTitle = nameParts.count >= 2 ? nameParts.dropFirst().joined(separator: " - ") : baseName

        let title = await string(.commonIdentifierTitle, .id3MetadataTitleDescription, .iTunesMetadataSongName) ?? fallbackTitle
        let artist = await string(.commonIdentifierArtist, .id3MetadataLeadPerformer, .iTunesMetadataArtist) ?? fallbackArtist
        let album = await string(.commonIdentifierAlbumName, .id3MetadataAlbumTitle, .iTunesMetadataAlbum) ?? ""
        let albumArtist = await string(.id3MetadataBand, .iTunesMetadataAlbumArtist) ?? ""
        let genre = await string(.id3MetadataContentType, .iTunesMetadataUserGenre, .quickTimeMetadataGenre) ?? ""
        let dateText = await string(.id3MetadataRecordingTime, .id3MetadataYear, .iTunesMetadataReleaseDate,
                                    .commonIdentifierCreationDate)
        let year = dateText.flatMap { Int($0.prefix(4)) }
        let trackNumber = await number(.id3MetadataTrackNumber, .iTunesMetadataTrackNumber)
        let discNumber = await number(.id3MetadataPartOfASet, .iTunesMetadataDiscNumber)

        // Cache embedded cover art once per album (or per file without one).
        var artworkFile: String?
        let artworkItems = AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: .commonIdentifierArtwork)
        if let item = artworkItems.first, let data = try? await item.load(.dataValue), !data.isEmpty {
            let key = album.isEmpty ? url.path : "\(albumArtist.isEmpty ? artist : albumArtist)|\(album)".lowercased()
            let name = SHA256.hash(data: Data(key.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined() + ".jpg"
            let destination = artworkDirectory.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: destination.path) {
                try? data.write(to: destination, options: .atomic)
            }
            artworkFile = name
        }

        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        return ScannedTrack(
            path: url.path,
            title: title,
            artist: artist,
            album: album,
            albumArtist: albumArtist,
            trackNumber: trackNumber,
            discNumber: discNumber,
            genre: genre,
            year: year,
            duration: duration.isFinite ? duration : 0,
            artworkFile: artworkFile,
            fileModified: modified
        )
    }
}
