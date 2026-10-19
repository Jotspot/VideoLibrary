import Foundation

enum DebugLog {
    static let fileURL: URL = {
        let directory = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0].appendingPathComponent("VideoLibrary", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("debug.log")
    }()

    private static let queue = DispatchQueue(label: "video-library.debug-log")
    private static let maxLogBytes: UInt64 = 5 * 1024 * 1024

    static func write(
        _ message: String,
        category: String = "app",
        file: StaticString = #fileID,
        line: UInt = #line
    ) {
        queue.async {
            rotateIfNeeded()
            let timestamp = ISO8601DateFormatter().string(from: Date())
            let entry = "[\(timestamp)] [\(category)] \(redact(message)) (\(file):\(line))\n"
            guard let data = entry.data(using: .utf8) else { return }

            if FileManager.default.fileExists(atPath: fileURL.path),
               let handle = try? FileHandle(forWritingTo: fileURL) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                _ = try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: fileURL, options: .atomic)
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            }
        }
    }

    private static let secretPatterns: [(pattern: String, template: String)] = [
        (#"ya29\.[A-Za-z0-9._\-]+"#, "ya29.<redacted>"),                                   // Google access token
        (#"1//[A-Za-z0-9._\-]{20,}"#, "1//<redacted>"),                                      // Google refresh token
        (#"GOCSPX-[A-Za-z0-9_\-]+"#, "GOCSPX-<redacted>"),                                   // OAuth client secret
        (#"("(?:access_token|refresh_token|id_token|client_secret|accessToken|refreshToken)"\s*:\s*)"[^"]*""#, "$1\"<redacted>\""),
        (#"("cookies"\s*:\s*)"[^"]*""#, "$1\"<redacted>\""),
        (#"((?:^|[?&\s])(?:token|client_secret|code|access_token|refresh_token)=)[^&\s"]+"#, "$1<redacted>"),
        (#"(?i)(cookie:\s*)[^\n"]+"#, "$1<redacted>"),
        (#"((?:__Secure-[0-9A-Za-z\-]+|SAPISID|APISID|HSID|SSID|SID|SIDCC|LOGIN_INFO|VISITOR_INFO1_LIVE)=)[^;\s"]+"#, "$1<redacted>")
    ]

    /// Strips tokens, cookies and secrets from text before it reaches disk.
    static func redact(_ text: String) -> String {
        secretPatterns.reduce(text) { result, rule in
            result.replacingOccurrences(of: rule.pattern, with: rule.template, options: .regularExpression)
        }
    }

    static func clear() {
        queue.async {
            try? Data().write(to: fileURL, options: .atomic)
        }
    }

    private static func rotateIfNeeded() {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let size = attributes[.size] as? NSNumber,
              size.uint64Value > maxLogBytes else { return }

        let oldURL = fileURL.deletingLastPathComponent().appendingPathComponent("debug.old.log")
        try? FileManager.default.removeItem(at: oldURL)
        try? FileManager.default.moveItem(at: fileURL, to: oldURL)
    }
}
