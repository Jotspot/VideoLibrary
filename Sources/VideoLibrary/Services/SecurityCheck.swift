import Foundation
import Observation

/// Finds sensitive data that older versions stored in plaintext, moves it
/// into the encrypted SecretVault / cookie store, and destroys the original.
/// Runs automatically at launch and on demand from Settings › Privacy.
@Observable
@MainActor
final class SecurityCheck {
    static let shared = SecurityCheck()

    struct Finding: Identifiable, Sendable {
        let id = UUID()
        let title: String
        let detail: String
        let fixed: Bool
    }

    private(set) var findings: [Finding] = []
    private(set) var lastRun: Date?
    private(set) var isRunning = false

    /// Fast part (no library scan), run synchronously at launch before the
    /// YouTube store loads its token, so migration is invisible to the user.
    func migrateAtLaunch() {
        findings = Self.scan(libraryFolders: [])
        lastRun = Date()
    }

    func run(libraryFolders: [URL] = []) async {
        guard !isRunning else { return }
        isRunning = true
        let results = await Task.detached(priority: .utility) {
            Self.scan(libraryFolders: libraryFolders)
        }.value
        // Keep what launch migration already fixed so the report shows it.
        findings = (findings + results)
        lastRun = Date()
        isRunning = false
        let fixed = results.filter(\.fixed).count
        if fixed > 0 {
            DebugLog.write("Security check secured \(fixed) item(s).", category: "security")
        }
    }

    nonisolated private static func scan(libraryFolders: [URL]) -> [Finding] {
        var findings: [Finding] = []
        let fm = FileManager.default
        let defaults = UserDefaults.standard

        // 1. Plaintext cookies.txt from older versions.
        let legacyCookies = CookieCache.legacyPlaintextURL
        if fm.fileExists(atPath: legacyCookies.path) {
            var safeToDelete = CookieCache.hasSavedCookies
            if !safeToDelete, let text = try? String(contentsOf: legacyCookies, encoding: .utf8) {
                safeToDelete = !text.contains("\t")   // empty/invalid: nothing to keep
                    || (try? CookieCache.save(netscapeText: text)) != nil
            }
            // Only destroy the plaintext once an encrypted copy is confirmed.
            if safeToDelete {
                SecureStore.destroyFile(at: legacyCookies)
                try? fm.removeItem(at: legacyCookies.deletingLastPathComponent())
            }
            findings.append(Finding(
                title: "YouTube cookies were stored unencrypted",
                detail: safeToDelete ? "Moved into encrypted storage and deleted the plaintext file."
                                     : "Couldn't create encrypted storage (Keychain unavailable?), so the file was left in place. Run the check again.",
                fixed: safeToDelete
            ))
        }

        // 2. Plaintext OAuth token file.
        let legacyToken = YouTubeOAuthService.legacyTokenURL
        if fm.fileExists(atPath: legacyToken.path) {
            var safeToDelete = SecretVault.value(.youtubeOAuthToken) != nil
            if !safeToDelete, let data = try? Data(contentsOf: legacyToken) {
                safeToDelete = (try? JSONDecoder().decode(YouTubeOAuthToken.self, from: data)) == nil
                    || SecretVault.set(String(decoding: data, as: UTF8.self), for: .youtubeOAuthToken)
            }
            if safeToDelete { SecureStore.destroyFile(at: legacyToken) }
            findings.append(Finding(
                title: "YouTube sign-in token was stored unencrypted",
                detail: safeToDelete ? "Moved into encrypted storage and deleted the plaintext file. You stay signed in."
                                     : "Couldn't create encrypted storage, so the file was left in place. Run the check again.",
                fixed: safeToDelete
            ))
        }

        // 3. Secrets in UserDefaults (a plaintext preferences plist).
        let legacyDefaults: [(key: String, vault: SecretVault.Name, label: String)] = [
            (YouTubeSuggestionsStore.legacyClientSecretKey, .youtubeClientSecret, "Google OAuth client secret"),
            (LocalSharingServer.legacyReusableTokenKey, .sharingToken, "Local sharing access code")
        ]
        for entry in legacyDefaults {
            guard let value = defaults.string(forKey: entry.key) else { continue }
            let saved = value.isEmpty || SecretVault.value(entry.vault) != nil
                || SecretVault.set(value, for: entry.vault)
            if saved { defaults.removeObject(forKey: entry.key) }
            findings.append(Finding(
                title: "\(entry.label) was stored in plaintext preferences",
                detail: saved ? "Moved into encrypted storage and removed from preferences."
                              : "Couldn't create encrypted storage, so it was left in place. Run the check again.",
                fixed: saved
            ))
        }

        // 4. Plaintext cookie copies left behind by an interrupted download.
        let stale = CookieCache.removeStaleSessions()
        if stale > 0 {
            findings.append(Finding(
                title: "Leftover temporary cookie files",
                detail: "Removed \(stale) temporary copy(ies) left after the app quit mid-download.",
                fixed: true
            ))
        }

        // 5. Secrets in old debug logs (written before redaction existed).
        let logs = [DebugLog.fileURL, DebugLog.fileURL.deletingLastPathComponent().appendingPathComponent("debug.old.log")]
        for log in logs {
            guard let text = try? String(contentsOf: log, encoding: .utf8) else { continue }
            let scrubbed = DebugLog.redact(text)
                .replacingOccurrences(
                    of: #"output: video-library-info:\{.*"#,
                    with: "output: video-library-info:<removed>",
                    options: .regularExpression
                )
            if scrubbed != text {
                try? scrubbed.write(to: log, atomically: true, encoding: .utf8)
                findings.append(Finding(
                    title: "\(log.lastPathComponent) contained secrets",
                    detail: "Redacted tokens, cookies and signed media URLs from the log.",
                    fixed: true
                ))
            }
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: log.path)
        }

        // 6. yt-dlp .info.json files that embed cookies.
        var cleanedInfoFiles = 0
        for folder in libraryFolders where fm.fileExists(atPath: folder.path) {
            guard let enumerator = fm.enumerator(at: folder, includingPropertiesForKeys: nil,
                                                 options: [.skipsPackageDescendants]) else { continue }
            for case let url as URL in enumerator where url.lastPathComponent.hasSuffix(".info.json") {
                guard let data = try? Data(contentsOf: url),
                      data.range(of: Data(#""cookies""#.utf8)) != nil,
                      var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                json = stripCookies(json)
                if let cleaned = try? JSONSerialization.data(withJSONObject: json) {
                    try? cleaned.write(to: url, options: .atomic)
                    cleanedInfoFiles += 1
                }
            }
        }
        if cleanedInfoFiles > 0 {
            findings.append(Finding(
                title: "Video info files contained cookies",
                detail: "Removed cookies from \(cleanedInfoFiles) .info.json file(s) in your libraries.",
                fixed: true
            ))
        }

        // 7. Tighten folder permissions.
        let appSupport = SecureStore.directory.deletingLastPathComponent()
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: appSupport.path)

        return findings
    }

    nonisolated private static func stripCookies(_ value: [String: Any]) -> [String: Any] {
        var result = value
        result["cookies"] = nil
        for (key, child) in result {
            if let dict = child as? [String: Any] {
                result[key] = stripCookies(dict)
            } else if let array = child as? [Any] {
                result[key] = array.map { ($0 as? [String: Any]).map(stripCookies) ?? $0 }
            }
        }
        return result
    }
}
