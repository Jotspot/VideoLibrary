import AppKit
import CryptoKit
import Foundation
import Security

enum YouTubeOAuthError: Error, LocalizedError {
    case missingClientID
    case invalidAuthorizationURL
    case callbackServerUnavailable
    case callbackTimedOut
    case authorizationFailed(String)
    case invalidState
    case missingAuthorizationCode
    case tokenUnavailable

    var errorDescription: String? {
        switch self {
        case .missingClientID:
            "Paste a Google OAuth desktop client ID before connecting YouTube."
        case .invalidAuthorizationURL:
            "Could not build the Google authorization URL."
        case .callbackServerUnavailable:
            "Could not start the local OAuth callback server."
        case .callbackTimedOut:
            "YouTube sign-in timed out."
        case .authorizationFailed(let message):
            "YouTube sign-in failed: \(message)"
        case .invalidState:
            "The OAuth response did not match this sign-in attempt."
        case .missingAuthorizationCode:
            "Google did not return an authorization code."
        case .tokenUnavailable:
            "Google did not return an access token."
        }
    }
}

struct YouTubeOAuthToken: Codable, Sendable {
    var accessToken: String
    var refreshToken: String?
    var expirationDate: Date

    var hasFreshAccessToken: Bool {
        expirationDate.timeIntervalSinceNow > 60
    }
}

final class YouTubeOAuthService: @unchecked Sendable {
    private static let scope = "https://www.googleapis.com/auth/youtube.readonly"
    /// Where older versions kept the token as plaintext JSON (migrated by SecurityCheck).
    static var legacyTokenURL: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VideoLibrary/youtube-oauth-token.json")
    }
    private static var cachedToken: YouTubeOAuthToken?
    private static var didLoadToken = false

    // Tokens live encrypted in SecretVault, never in a plaintext file.
    func storedToken() -> YouTubeOAuthToken? {
        if Self.didLoadToken {
            return Self.cachedToken
        }
        Self.didLoadToken = true
        guard let json = SecretVault.value(.youtubeOAuthToken) else { return nil }
        Self.cachedToken = try? JSONDecoder().decode(YouTubeOAuthToken.self, from: Data(json.utf8))
        return Self.cachedToken
    }

    func saveToken(_ token: YouTubeOAuthToken) throws {
        let data = try JSONEncoder().encode(token)
        SecretVault.set(String(decoding: data, as: UTF8.self), for: .youtubeOAuthToken)
        Self.cachedToken = token
        Self.didLoadToken = true
    }

    func clearToken() {
        SecretVault.set(nil, for: .youtubeOAuthToken)
        Self.cachedToken = nil
        Self.didLoadToken = true
    }

    func signIn(clientID: String, clientSecret: String?) async throws -> YouTubeOAuthToken {
        let trimmedClientID = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedClientID.isEmpty else { throw YouTubeOAuthError.missingClientID }
        let trimmedClientSecret = clientSecret?.trimmingCharacters(in: .whitespacesAndNewlines)

        DebugLog.write(
            "Starting OAuth sign-in. hasClientSecret=\(trimmedClientSecret?.isEmpty == false)",
            category: "oauth"
        )
        let verifier = Self.makeCodeVerifier()
        let challenge = Self.codeChallenge(for: verifier)
        let state = Self.randomBase64URL(byteCount: 24)
        let callbackServer = OAuthCallbackServer(expectedState: state)
        let redirectURI = try callbackServer.start()
        DebugLog.write("OAuth callback server started. redirectURI=\(redirectURI)", category: "oauth")
        defer { callbackServer.stop() }

        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")
        components?.queryItems = [
            URLQueryItem(name: "client_id", value: trimmedClientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: Self.scope),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state)
        ]
        guard let authorizationURL = components?.url else {
            throw YouTubeOAuthError.invalidAuthorizationURL
        }

        await MainActor.run {
            _ = NSWorkspace.shared.open(authorizationURL)
        }

        let code = try await callbackServer.waitForCode(timeout: 180)
        DebugLog.write("OAuth authorization code received; exchanging for token.", category: "oauth")
        let token = try await exchangeAuthorizationCode(
            code,
            clientID: trimmedClientID,
            clientSecret: trimmedClientSecret,
            redirectURI: redirectURI,
            verifier: verifier
        )
        try saveToken(token)
        DebugLog.write("OAuth sign-in complete. hasRefreshToken=\(token.refreshToken != nil)", category: "oauth")
        return token
    }

    func validAccessToken(clientID: String, clientSecret: String?) async throws -> String {
        guard var token = storedToken() else { throw YouTubeOAuthError.tokenUnavailable }
        if token.hasFreshAccessToken {
            return token.accessToken
        }
        guard let refreshToken = token.refreshToken else {
            throw YouTubeOAuthError.tokenUnavailable
        }
        DebugLog.write("Refreshing OAuth access token.", category: "oauth")
        token = try await refreshAccessToken(
            refreshToken,
            clientID: clientID.trimmingCharacters(in: .whitespacesAndNewlines),
            clientSecret: clientSecret?.trimmingCharacters(in: .whitespacesAndNewlines),
            existingToken: token
        )
        try saveToken(token)
        DebugLog.write("OAuth access token refreshed.", category: "oauth")
        return token.accessToken
    }

    private func exchangeAuthorizationCode(
        _ code: String,
        clientID: String,
        clientSecret: String?,
        redirectURI: String,
        verifier: String
    ) async throws -> YouTubeOAuthToken {
        var parameters = [
            "client_id": clientID,
            "code": code,
            "code_verifier": verifier,
            "grant_type": "authorization_code",
            "redirect_uri": redirectURI
        ]
        if let clientSecret, !clientSecret.isEmpty {
            parameters["client_secret"] = clientSecret
        }
        return try await tokenRequest(parameters: parameters, existingToken: nil)
    }

    private func refreshAccessToken(
        _ refreshToken: String,
        clientID: String,
        clientSecret: String?,
        existingToken: YouTubeOAuthToken
    ) async throws -> YouTubeOAuthToken {
        var parameters = [
            "client_id": clientID,
            "grant_type": "refresh_token",
            "refresh_token": refreshToken
        ]
        if let clientSecret, !clientSecret.isEmpty {
            parameters["client_secret"] = clientSecret
        }
        return try await tokenRequest(parameters: parameters, existingToken: existingToken)
    }

    private func tokenRequest(
        parameters: [String: String],
        existingToken: YouTubeOAuthToken?
    ) async throws -> YouTubeOAuthToken {
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.formEncoded(parameters).data(using: .utf8)

        DebugLog.write(
            "OAuth token request. grantType=\(parameters["grant_type"] ?? "unknown"), hasClientSecret=\(parameters["client_secret"] != nil)",
            category: "oauth"
        )
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "HTTP error"
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            DebugLog.write(
                "OAuth token request failed. status=\(status), body=\(String(message.prefix(1000)))",
                category: "oauth"
            )
            throw YouTubeOAuthError.authorizationFailed(message)
        }

        let raw = try JSONDecoder().decode(TokenResponse.self, from: data)
        guard let accessToken = raw.access_token else { throw YouTubeOAuthError.tokenUnavailable }
        DebugLog.write(
            "OAuth token request succeeded. hasRefreshToken=\(raw.refresh_token != nil), expiresIn=\(raw.expires_in ?? -1)",
            category: "oauth"
        )
        return YouTubeOAuthToken(
            accessToken: accessToken,
            refreshToken: raw.refresh_token ?? existingToken?.refreshToken,
            expirationDate: Date().addingTimeInterval(TimeInterval(raw.expires_in ?? 3600))
        )
    }

    private static func makeCodeVerifier() -> String {
        randomBase64URL(byteCount: 48)
    }

    private static func codeChallenge(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return base64URL(Data(digest))
    }

    private static func randomBase64URL(byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return base64URL(Data(bytes))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func formEncoded(_ parameters: [String: String]) -> String {
        parameters
            .map { key, value in
                "\(escapeFormValue(key))=\(escapeFormValue(value))"
            }
            .joined(separator: "&")
    }

    private static func escapeFormValue(_ value: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private struct TokenResponse: Decodable {
        let access_token: String?
        let refresh_token: String?
        let expires_in: Int?
    }
}

private final class OAuthCallbackServer: @unchecked Sendable {
    private let expectedState: String
    private let server = GCDWebServer()
    private let lock = NSLock()
    private var continuation: CheckedContinuation<String, Error>?
    private var result: Result<String, Error>?

    init(expectedState: String) {
        self.expectedState = expectedState
    }

    func start() throws -> String {
        server.addDefaultHandler(forMethod: "GET", request: GCDWebServerRequest.self) { [weak self] request in
            guard let self else { return GCDWebServerResponse(statusCode: 500) }
            guard request.path == "/oauth2callback" else {
                return GCDWebServerResponse(statusCode: 404)
            }

            // Check state first: a request without the right state (e.g. a
            // malicious page hitting the port) is ignored instead of being
            // allowed to cancel or complete the sign-in.
            guard request.query?["state"] == self.expectedState else {
                DebugLog.write("OAuth callback with wrong state ignored.", category: "oauth")
                return Self.htmlResponse("This sign-in link is no longer valid. Return to VideoLibrary and try again.")
            }
            if let error = request.query?["error"] {
                DebugLog.write("OAuth callback returned error=\(error)", category: "oauth")
                self.complete(.failure(YouTubeOAuthError.authorizationFailed(error)))
                return Self.htmlResponse("You can close this window and return to VideoLibrary.")
            }
            guard let code = request.query?["code"], !code.isEmpty else {
                DebugLog.write("OAuth callback missing authorization code.", category: "oauth")
                self.complete(.failure(YouTubeOAuthError.missingAuthorizationCode))
                return Self.htmlResponse("Google did not return an authorization code. Return to VideoLibrary and try again.")
            }

            DebugLog.write("OAuth callback received authorization code.", category: "oauth")
            self.complete(.success(code))
            return Self.htmlResponse("YouTube is connected. You can close this window and return to VideoLibrary.")
        }

        // Loopback only: the redirect is to 127.0.0.1, so nothing on the
        // network should be able to reach this server.
        let options: [String: Any] = [
            GCDWebServerOption_Port: 0,
            GCDWebServerOption_BindToLocalhost: true
        ]
        guard (try? server.start(options: options)) != nil, server.port > 0 else {
            throw YouTubeOAuthError.callbackServerUnavailable
        }
        return "http://127.0.0.1:\(server.port)/oauth2callback"
    }

    func stop() {
        server.stop()
    }

    func waitForCode(timeout: TimeInterval) async throws -> String {
        let timeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            self?.complete(.failure(YouTubeOAuthError.callbackTimedOut))
        }
        defer { timeoutTask.cancel() }

        return try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if let result {
                lock.unlock()
                continuation.resume(with: result)
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }
    }

    private func complete(_ result: Result<String, Error>) {
        lock.lock()
        guard self.result == nil else {
            lock.unlock()
            return
        }
        self.result = result
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()

        continuation?.resume(with: result)
    }

    private static func htmlResponse(_ message: String) -> GCDWebServerResponse {
        GCDWebServerDataResponse(
            data: Data("""
            <!doctype html>
            <html><body style="font-family:-apple-system;padding:32px">
            <h1>VideoLibrary</h1>
            <p>\(message)</p>
            </body></html>
            """.utf8),
            contentType: "text/html; charset=utf-8"
        )
    }
}
