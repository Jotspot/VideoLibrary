import AppKit
import CoreTransferable
import UniformTypeIdentifiers

@MainActor
enum VideoSharingService {
    /// Copies the video into ~/Downloads (never overwriting a file already
    /// there) and selects the copy in Finder.
    static func saveToDownloads(_ item: VideoItem) {
        guard let source = item.videoURL, FileManager.default.fileExists(atPath: source.path) else {
            showError("The video file couldn't be found. It may be on a drive that isn't connected.")
            return
        }
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        let destination = uniqueURL(for: source.lastPathComponent, in: downloads)
        // Copy off the main thread: videos can be several gigabytes.
        Task.detached(priority: .userInitiated) {
            do {
                try FileManager.default.copyItem(at: source, to: destination)
                await MainActor.run { NSWorkspace.shared.activateFileViewerSelecting([destination]) }
            } catch {
                await MainActor.run { showError(error.localizedDescription) }
            }
        }
    }

    nonisolated static func uniqueURL(for name: String, in folder: URL) -> URL {
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

    private static func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Couldn't save the video"
        alert.informativeText = message
        alert.runModal()
    }
}

/// A video file dragged out of the library. The receiver (Finder, the
/// desktop, another app) gets its own copy; the library's file never moves.
struct VideoFileDrag: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .movie) { drag in
            SentTransferredFile(drag.url, allowAccessingOriginalFile: false)
        }
        // Without this Finder names the copy "movie", with no extension.
        .suggestedFileName { $0.url.lastPathComponent }
    }
}
