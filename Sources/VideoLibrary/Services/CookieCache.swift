import Foundation

/// Saved YouTube cookies, encrypted at rest via SecureStore.
///
/// yt-dlp can only read cookies from a plain Netscape cookies.txt file, so
/// each download opens a `Session`: the cookies are decrypted into a private
/// temp folder (owner-only), yt-dlp reads and updates that file, and when the
/// download ends the file is re-encrypted and the plaintext destroyed.
enum CookieCache {
    static var encryptedURL: URL {
        SecureStore.directory.appendingPathComponent("youtube-cookies.enc")
    }

    /// Where older versions kept cookies as plaintext (migrated by SecurityCheck).
    static var legacyPlaintextURL: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VideoLibrary/cookies/youtube-cookies.txt")
    }

    static var temporaryRoot: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("VideoLibrary-cookies", isDirectory: true)
    }

    static var hasSavedCookies: Bool {
        FileManager.default.fileExists(atPath: encryptedURL.path)
    }

    /// A saved YouTube/Google sign-in (as opposed to e.g. only Nebula).
    static var hasYouTubeSignIn: Bool {
        ["SAPISID", "LOGIN_INFO", "__Secure-3PSID"].contains { name in
            value(named: name, site: "youtube.com") != nil || value(named: name, site: "google.com") != nil
        }
    }

    /// Posted (on the main queue) when saved cookies are added or removed.
    static let didChangeNotification = Notification.Name("CookieCacheDidChange")

    /// Saves Netscape-format cookies (from the sign-in window or Arc import).
    static func save(netscapeText: String) throws {
        try SecureStore.write(Data(netscapeText.utf8), to: encryptedURL)
        postChange()
    }

    /// Replaces the cookies for the given sites (e.g. ["youtube.com",
    /// "google.com"]) and keeps everything else, so signing in to one site
    /// doesn't sign you out of another.
    static func merge(netscapeText: String, replacingSites sites: Set<String>) throws {
        func site(of line: Substring) -> String {
            var domain = line.split(separator: "\t", maxSplits: 1).first.map(String.init) ?? ""
            if domain.hasPrefix("#HttpOnly_") { domain.removeFirst("#HttpOnly_".count) }
            return domain.hasPrefix(".") ? String(domain.dropFirst()) : domain
        }
        func belongs(_ line: Substring) -> Bool {
            let domain = site(of: line)
            return sites.contains { domain == $0 || domain.hasSuffix("." + $0) }
        }
        func isCookie(_ line: Substring) -> Bool {
            line.contains("\t") && (!line.hasPrefix("#") || line.hasPrefix("#HttpOnly_"))
        }

        let existing = ((try? SecureStore.read(encryptedURL)) ?? nil).map { String(decoding: $0, as: UTF8.self) } ?? ""
        let kept = existing.split(separator: "\n").filter { isCookie($0) && !belongs($0) }
        let added = netscapeText.split(separator: "\n").filter(isCookie)
        let lines = ["# Netscape HTTP Cookie File", "# Managed by VideoLibrary", ""] + (kept + added).map(String.init)
        try save(netscapeText: lines.joined(separator: "\n") + "\n")
    }

    /// Removes the saved cookies for the given sites only.
    static func remove(sites: Set<String>) {
        try? merge(netscapeText: "", replacingSites: sites)
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: didChangeNotification, object: nil)
        }
    }

    /// Reads one saved cookie's value (e.g. to show whether Nebula is set up).
    static func value(named name: String, site: String) -> String? {
        guard let data = (try? SecureStore.read(encryptedURL)) ?? nil else { return nil }
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count >= 7, fields[5] == name else { continue }
            let domain = fields[0].replacingOccurrences(of: "#HttpOnly_", with: "")
            if domain.hasSuffix(site) { return String(fields[6]) }
        }
        return nil
    }

    static func clear() {
        try? FileManager.default.removeItem(at: encryptedURL)
        postChange()
    }

    private static func postChange() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: didChangeNotification, object: nil)
        }
    }

    /// Plaintext cookies for the length of one yt-dlp run.
    final class Session: @unchecked Sendable {
        let fileURL: URL
        private let directory: URL
        private let lock = NSLock()
        private var finished = false

        fileprivate init(directory: URL, fileURL: URL) {
            self.directory = directory
            self.fileURL = fileURL
        }

        /// Re-encrypts whatever yt-dlp left in the file (it refreshes
        /// cookies as it goes), then destroys the plaintext.
        func finish(keepUpdates: Bool) {
            lock.lock()
            defer { lock.unlock() }
            guard !finished else { return }
            finished = true
            if keepUpdates,
               let text = try? String(contentsOf: fileURL, encoding: .utf8),
               text.contains("\t") {
                do {
                    try CookieCache.save(netscapeText: text)
                } catch {
                    DebugLog.write("Could not re-encrypt cookies: \(error.localizedDescription)", category: "security")
                }
            }
            SecureStore.destroyFile(at: fileURL)
            try? FileManager.default.removeItem(at: directory)
        }

        deinit { finish(keepUpdates: false) }
    }

    static func beginSession() throws -> Session {
        let fm = FileManager.default
        try fm.createDirectory(at: temporaryRoot, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let directory = temporaryRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let fileURL = directory.appendingPathComponent("cookies.txt")
        let plaintext = (try SecureStore.read(encryptedURL)) ?? Data()
        guard fm.createFile(atPath: fileURL.path, contents: plaintext, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return Session(directory: directory, fileURL: fileURL)
    }

    /// Removes plaintext left behind if the app quit mid-download.
    static func removeStaleSessions() -> Int {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: temporaryRoot, includingPropertiesForKeys: nil) else { return 0 }
        for entry in entries {
            SecureStore.destroyFile(at: entry.appendingPathComponent("cookies.txt"))
            try? fm.removeItem(at: entry)
        }
        return entries.count
    }
}
