import SwiftUI
import AppKit

/// Status + "Sign In to YouTube…" + "Import from Browser" + sign out.
/// Shared by Settings › Downloads and the Suggestions screen so there's one
/// way to give the app a YouTube sign-in.
struct YouTubeSignInControls: View {
    @Environment(\.openWindow) private var openWindow
    @State private var hasSavedCookies = CookieCache.hasYouTubeSignIn
    @State private var importMessage: (text: String, success: Bool)?
    var showsStatus = true

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if showsStatus {
                LabeledContent("Status") {
                    if hasSavedCookies {
                        Label("Signed in · stored encrypted", systemImage: "lock.fill")
                            .foregroundStyle(.green)
                    } else {
                        Text("Not signed in").foregroundStyle(.secondary)
                    }
                }
            }

            HStack {
                Button("Sign In to YouTube…", systemImage: "person.crop.circle.badge.checkmark") {
                    openWindow(id: YouTubeSignInView.windowID)
                }
                .buttonStyle(.borderedProminent)

                importMenu
            }

            if let importMessage {
                Label(importMessage.text, systemImage: importMessage.success ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(importMessage.success ? .green : .orange)
                    .fixedSize(horizontal: false, vertical: true)
                if !importMessage.success, importMessage.text.contains("Full Disk Access") {
                    Button("Open Full Disk Access Settings…") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
                    }
                }
            }

            if hasSavedCookies, showsStatus {
                Button("Sign Out (Forget Saved Sign-In)", role: .destructive) {
                    CookieCache.remove(sites: ["youtube.com", "google.com"])
                    importMessage = nil
                    refresh()
                }
            }
        }
        .onAppear(perform: refresh)
        .onReceive(NotificationCenter.default.publisher(for: CookieCache.didChangeNotification)) { _ in refresh() }
    }

    private var importMenu: some View {
        BrowserImportMenu(service: .youtube) { result in
            importMessage = result
            refresh()
        }
    }

    private func refresh() {
        hasSavedCookies = CookieCache.hasYouTubeSignIn
    }
}

/// "Import from Browser" for one service: lists the browsers on this Mac
/// (with profiles) and imports only that service's sign-in.
struct BrowserImportMenu: View {
    let service: BrowserCookieImporter.Service
    let onResult: ((text: String, success: Bool)) -> Void

    @State private var browsers: [BrowserCookieImporter.Installed] = []
    @State private var isImporting = false

    var body: some View {
        Menu {
            if browsers.isEmpty {
                Text("No supported browsers found")
            }
            ForEach(browsers) { installed in
                if installed.profiles.count > 1 {
                    Menu(installed.browser.name) {
                        ForEach(installed.profiles) { profile in
                            Button(profile.displayName) { importFrom(installed.browser, profile) }
                        }
                    }
                } else if let profile = installed.profiles.first {
                    Button(installed.browser.name) { importFrom(installed.browser, profile) }
                }
            }
        } label: {
            Label(isImporting ? "Importing…" : "Import from Browser", systemImage: "square.and.arrow.down")
        }
        .fixedSize()
        .disabled(isImporting)
        .help("Copy your \(service.rawValue) sign-in from a browser you're already signed in to")
        .onAppear { browsers = BrowserCookieImporter.installedBrowsers() }
    }

    private func importFrom(_ browser: BrowserCookieImporter.Browser, _ profile: BrowserCookieImporter.Profile) {
        let service = self.service
        isImporting = true
        Task.detached {
            let result: (text: String, success: Bool)
            do {
                _ = try BrowserCookieImporter.importCookies(service, from: browser, profile: profile)
                result = ("Imported your \(service.rawValue) sign-in from \(browser.name), stored encrypted.", true)
            } catch {
                result = (error.localizedDescription, false)
            }
            await MainActor.run {
                isImporting = false
                onResult(result)
            }
        }
    }
}
