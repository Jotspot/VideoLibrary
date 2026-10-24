import Foundation

/// One song file in a library's music collection.
struct Song: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    /// Absolute path, like VideoItem's paths.
    var path: String
    /// The added folder this file was found in.
    var sourceID: UUID
    var title: String
    var artist: String
    var album: String
    var albumArtist: String
    var trackNumber: Int?
    var discNumber: Int?
    var genre: String
    var year: Int?
    var duration: TimeInterval
    /// File name (in the artwork cache) of the embedded cover, if any.
    var artworkFile: String?
    var dateAdded: Date
    var fileModified: Date?
    var playCount: Int = 0
    var lastPlayed: Date?
    /// Optional so music.json files from before Liked Songs still decode.
    var isLiked: Bool? = nil

    var liked: Bool { isLiked == true }

    var url: URL { URL(fileURLWithPath: path) }

    /// Album artist when tagged, otherwise the track artist.
    var displayAlbumArtist: String { albumArtist.isEmpty ? artist : albumArtist }

    /// Groups tracks into albums.
    var albumKey: String { "\(displayAlbumArtist.lowercased())|\(album.lowercased())" }

    var formattedDuration: String {
        guard duration.isFinite, duration > 0 else { return "--:--" }
        let total = Int(duration)
        return total >= 3600
            ? String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
            : String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// A folder the user added with the + button. Its name doubles as a playlist.
struct MusicSource: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var name: String
    var path: String
}

/// A subfolder (at any depth) of an added folder that holds songs. Each one
/// is a playlist of the songs in it and below it, so a "Music" folder of
/// album or playlist folders becomes one playlist per folder.
struct FolderPlaylist: Identifiable, Hashable, Sendable {
    let sourceID: UUID
    /// Path inside the added folder, e.g. "Rock/Favourites".
    let relativePath: String

    var id: String { "\(sourceID.uuidString)/\(relativePath)" }
    var name: String { (relativePath as NSString).lastPathComponent }
    var depth: Int { relativePath.split(separator: "/").count }
}

/// A playlist the user made in the app.
struct MusicPlaylist: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var name: String
    var trackIDs: [UUID]
    var dateCreated: Date
}

/// Everything persisted for one library: `.VideoLibrary/music.json`.
struct MusicLibraryFile: Codable, Sendable {
    var sources: [MusicSource] = []
    var tracks: [Song] = []
    var playlists: [MusicPlaylist] = []
}

/// An album built from tracks (not stored).
struct MusicAlbum: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let artist: String
    let year: Int?
    let artworkFile: String?
    let tracks: [Song]
}
