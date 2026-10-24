import CryptoKit
import Foundation
import Observation

/// Optional, experimental support for YouTube's SABR streaming.
///
/// Some YouTube accounts (and networks) only get SABR streams, which stable
/// yt-dlp can't download, so downloads fall back to the 360p MP4. yt-dlp's
/// SABR downloader is still a pre-release (yt-dlp PR #13515, published as
/// bashonly/yt-dlp's `sabr` build). It is never bundled or installed up
/// front: the app offers it only after a download detected SABR and the
/// other YouTube clients also failed to get HD. It lives in Application
/// Support, separate from the Homebrew yt-dlp used for everything else.
@Observable
@MainActor
final class SABRAddon {
    static let shared = SABRAddon()

    nonisolated private static let release = "https://github.com/bashonly/yt-dlp/releases/download/sabr/"
    nonisolated private static let binaryName = "yt-dlp_macos"

    nonisolated static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VideoLibrary/tools", isDirectory: true)
    }

    nonisolated static var executableURL: URL {
        directory.appendingPathComponent("yt-dlp-sabr")
    }

    nonisolated static var isInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: executableURL.path)
    }

    private(set) var isInstalling = false
    private(set) var version: String?
    private(set) var lastError: String?

    var installed: Bool { version != nil || Self.isInstalled }

    func refresh() async {
        guard Self.isInstalled else { version = nil; return }
        version = await Task.detached { Self.readVersion() }.value
    }

    /// Downloads the macOS build, checks it against the release's SHA-256
    /// list, and makes it executable. Also used to update.
    @discardableResult
    func install() async -> Bool {
        guard !isInstalling else { return false }
        isInstalling = true
        lastError = nil
        defer { isInstalling = false }
        do {
            try await Task.detached(priority: .userInitiated) { try await Self.downloadAndVerify() }.value
            DebugLog.write("SABR add-on installed.", category: "sabr")
            await refresh()
            return true
        } catch {
            lastError = error.localizedDescription
            DebugLog.write("SABR add-on install failed: \(error.localizedDescription)", category: "sabr")
            return false
        }
    }

    func remove() {
        try? FileManager.default.removeItem(at: Self.executableURL)
        version = nil
    }

    // MARK: - Internals

    private nonisolated static func downloadAndVerify() async throws {
        let session = URLSession(configuration: .ephemeral)
        let (sums, sumsResponse) = try await session.data(from: URL(string: release + "SHA2-256SUMS")!)
        guard (sumsResponse as? HTTPURLResponse)?.statusCode == 200,
              let text = String(data: sums, encoding: .utf8),
              let expected = text.split(separator: "\n")
                .first(where: { $0.hasSuffix(" \(binaryName)") })?
                .split(separator: " ").first.map(String.init)?.lowercased() else {
            throw AddonError("Couldn't read the SABR build's checksums from GitHub.")
        }

        let (downloaded, response) = try await session.download(from: URL(string: release + binaryName)!)
        defer { try? FileManager.default.removeItem(at: downloaded) }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw AddonError("GitHub didn't return the SABR build. Try again later.")
        }
        let digest = SHA256.hash(data: try Data(contentsOf: downloaded, options: .mappedIfSafe))
        let actual = digest.map { String(format: "%02x", $0) }.joined()
        guard actual == expected else {
            throw AddonError("The downloaded SABR build didn't match its published checksum, so it wasn't installed.")
        }

        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = executableURL
        if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
        try fm.moveItem(at: downloaded, to: destination)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destination.path)
        // Downloaded by the app itself, so Gatekeeper's quarantine prompt
        // would only block yt-dlp from running in the background.
        removexattr(destination.path, "com.apple.quarantine", 0)
    }

    private nonisolated static func readVersion() -> String? {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = ["--version"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do { try process.run() } catch { return nil }
        process.waitUntilExit()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return process.terminationStatus == 0 ? output : nil
    }

    struct AddonError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}
