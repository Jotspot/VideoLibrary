import Foundation

/// Nebula (nebula.tv) sign-in for downloads. yt-dlp authenticates with the
/// `nebula_auth.apiToken` cookie, so the token is stored like any other
/// cookie: encrypted in CookieCache, never in plaintext.
enum NebulaAccount {
    private static let cookieName = "nebula_auth.apiToken"

    static var isConnected: Bool {
        CookieCache.value(named: cookieName, site: "nebula.tv")?.isEmpty == false
    }

    enum TokenError: LocalizedError {
        case rejected
        case unreachable(String)

        var errorDescription: String? {
            switch self {
            case .rejected:
                "Nebula didn't accept that token. Copy it again (no spaces) and try once more."
            case .unreachable(let detail):
                "Couldn't reach Nebula to check the token: \(detail)"
            }
        }
    }

    /// Checks the token with Nebula (the same call yt-dlp makes), then saves it.
    static func connect(token raw: String) async throws {
        let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        guard !token.isEmpty, let url = URL(string: "https://users.api.nebula.app/api/v1/authorization/") else {
            throw TokenError.rejected
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("Token \(token)", forHTTPHeaderField: "Authorization")
        let response: URLResponse
        do {
            (_, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw TokenError.unreachable(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw TokenError.rejected
        }

        let expires = Int(Date().addingTimeInterval(365 * 24 * 3600).timeIntervalSince1970)
        let line = [".nebula.tv", "TRUE", "/", "TRUE", String(expires), cookieName, token].joined(separator: "\t")
        try CookieCache.merge(netscapeText: line, replacingSites: ["nebula.tv"])
        DebugLog.write("Nebula token saved (encrypted).", category: "security")
    }

    static func disconnect() {
        CookieCache.remove(sites: ["nebula.tv"])
    }
}
