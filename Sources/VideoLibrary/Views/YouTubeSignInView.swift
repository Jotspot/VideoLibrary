import SwiftUI
import WebKit

/// Lets the user sign in to YouTube with their own Google account inside the
/// app, then captures the resulting cookies into the encrypted CookieCache.
///
/// Privacy: the web view uses a throwaway, non-persistent data store, so
/// nothing is left in WebKit's own storage. VideoLibrary never sees the
/// password — it only reads the session cookies after Google sets them.
struct YouTubeSignInView: View {
    static let windowID = "youtube-sign-in"

    @Environment(\.dismiss) private var dismiss
    @State private var model = YouTubeSignInModel()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "lock.fill").foregroundStyle(.green)
                Text(model.currentHost ?? "accounts.google.com")
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                if model.isLoading { ProgressView().controlSize(.small) }
                Button("Cancel") { finish(false) }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(12)

            Divider()

            ZStack {
                SignInWebView(model: model)
                if model.didCapture {
                    VStack(spacing: 12) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 44))
                            .foregroundStyle(.green)
                        Text("Signed in to YouTube")
                            .font(.title2.bold())
                        Text("Your sign-in was saved, encrypted. Downloads will now use it.")
                            .foregroundStyle(.secondary)
                        Button("Done") { finish(true) }
                            .buttonStyle(.borderedProminent)
                            .keyboardShortcut(.defaultAction)
                    }
                    .padding(32)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.regularMaterial)
                }
            }

            if let error = model.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()
            Text("Sign in with your Google account as usual. VideoLibrary never sees your password; it saves only YouTube's sign-in cookies, encrypted on this Mac.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: 520, height: 700)
        .onDisappear { model.tearDown() }
    }

    private func finish(_ success: Bool) {
        model.tearDown()
        dismiss()
    }
}

@Observable
@MainActor
final class YouTubeSignInModel: NSObject, WKNavigationDelegate {
    var isLoading = false
    var currentHost: String?
    var didCapture = false
    var errorMessage: String?

    @ObservationIgnored private weak var webView: WKWebView?
    /// One throwaway store per sign-in window, shared by any web view
    /// SwiftUI creates for it.
    @ObservationIgnored private let dataStore = WKWebsiteDataStore.nonPersistent()

    func makeWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = dataStore
        let view = WKWebView(frame: .zero, configuration: configuration)
        // Google refuses sign-in from browsers it identifies as embedded web
        // views; present as Safari, which is what WKWebView is.
        view.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15"
        view.navigationDelegate = self
        webView = view
        view.load(URLRequest(url: Self.startURL))
        return view
    }

    static let startURL = URL(string: "https://accounts.google.com/ServiceLogin?service=youtube&uilel=3&passive=true&continue=https%3A%2F%2Fwww.youtube.com%2Fsignin%3Faction_handle_signin%3Dtrue%26app%3Ddesktop%26next%3Dhttps%253A%252F%252Fwww.youtube.com%252F")!

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        isLoading = true
        currentHost = webView.url?.host
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        DebugLog.write("Sign-in page loaded: \(webView.url?.host ?? "?")", category: "sign-in")
        isLoading = false
        currentHost = webView.url?.host
        if let host = webView.url?.host, host.hasSuffix("youtube.com") {
            Task { await captureIfSignedIn() }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        isLoading = false
        errorMessage = error.localizedDescription
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        isLoading = false
        errorMessage = error.localizedDescription
    }

    /// Only follow https links to Google/YouTube sign-in pages; anything else
    /// opens in the user's real browser instead.
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction
    ) async -> WKNavigationActionPolicy {
        guard let url = navigationAction.request.url, let host = url.host?.lowercased() else { return .cancel }
        let allowed = ["google.com", "youtube.com", "gstatic.com", "googleusercontent.com", "googleapis.com", "google.co"]
        let isAllowedHost = allowed.contains { host == $0 || host.hasSuffix("." + $0) || host.hasPrefix("accounts.google.") }
        if url.scheme == "https", isAllowedHost { return .allow }
        if url.scheme == "about" || url.scheme == "blob" || url.scheme == "data" { return .allow }
        if navigationAction.targetFrame?.isMainFrame == true, url.scheme == "https" {
            NSWorkspace.shared.open(url)
        }
        return .cancel
    }

    private func captureIfSignedIn() async {
        guard !didCapture else { return }
        let cookies = await dataStore.httpCookieStore.allCookies()
        let relevant = cookies.filter { cookie in
            let domain = cookie.domain.lowercased()
            return domain.hasSuffix("youtube.com") || domain.hasSuffix("google.com")
        }
        let names = Set(relevant.map(\.name))
        guard names.contains("LOGIN_INFO") || names.contains("SAPISID") || names.contains("__Secure-3PSID") else { return }

        var lines = ["# Netscape HTTP Cookie File", "# Captured by VideoLibrary sign-in", ""]
        for cookie in relevant {
            let domain = cookie.domain
            lines.append([
                (cookie.isHTTPOnly ? "#HttpOnly_" : "") + domain,
                domain.hasPrefix(".") ? "TRUE" : "FALSE",
                cookie.path,
                cookie.isSecure ? "TRUE" : "FALSE",
                String(Int(cookie.expiresDate?.timeIntervalSince1970 ?? 0)),
                cookie.name,
                cookie.value
            ].joined(separator: "\t"))
        }
        do {
            try CookieCache.merge(netscapeText: lines.joined(separator: "\n") + "\n", replacingSites: ["youtube.com", "google.com"])
            UserDefaults.standard.set(true, forKey: AppPreference.rememberCookies)
            didCapture = true
            errorMessage = nil
            DebugLog.write("Captured \(relevant.count) YouTube cookies from in-app sign-in.", category: "security")
        } catch {
            errorMessage = "Signed in, but the cookies couldn't be saved securely: \(error.localizedDescription)"
        }
    }

    /// Wipes the throwaway browser session.
    func tearDown() {
        webView?.stopLoading()
        dataStore.removeData(
            ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
            modifiedSince: .distantPast
        ) {}
    }
}

private struct SignInWebView: NSViewRepresentable {
    let model: YouTubeSignInModel

    func makeNSView(context: Context) -> WKWebView {
        model.makeWebView()
    }

    func updateNSView(_ view: WKWebView, context: Context) {}
}
