import SwiftUI
import AppKit

struct AddVideoSheet: View {
    @Environment(LibraryStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openSettings) private var openSettings

    @State private var urlText = ""
    @State private var downloadPlaylist = false
    @State private var libraryID: UUID?
    @State private var tools = ToolsService.shared
    @AppStorage(AppPreference.resolution) private var resolutionRaw = DownloadResolution.p1080.rawValue
    @AppStorage(AppPreference.quality) private var qualityRaw = DownloadQuality.balanced.rawValue
    @AppStorage(AppPreference.browserCookies) private var browserCookiesRaw = BrowserCookieSource.none.rawValue
    @AppStorage(AppPreference.rememberCookies) private var rememberCookies = false

    init(initialURL: String = "") {
        _urlText = State(initialValue: initialURL)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Label("Add Video", systemImage: "arrow.down.to.line.circle.fill")
                    .font(.title2.bold())
                Spacer()
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    TextField("Paste a YouTube link", text: $urlText)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                        .onSubmit(startDownload)
                    Button("Paste") {
                        if let text = NSPasteboard.general.string(forType: .string) {
                            urlText = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        }
                    }
                }
                if let problem = urlProblem {
                    Text(problem).font(.caption).foregroundStyle(.orange)
                }
                if looksLikePlaylist {
                    Toggle("Download the whole playlist", isOn: $downloadPlaylist)
                        .toggleStyle(.checkbox)
                    Text(downloadPlaylist
                         ? "Every video in the playlist becomes its own library card."
                         : "Only the video in this link will be downloaded.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Form {
                Picker("Save to", selection: libraryBinding) {
                    ForEach(store.sortedLibraries) { library in
                        Text(library.isAvailable ? library.name : "\(library.name) (unavailable)")
                            .tag(library.id)
                    }
                    Divider()
                    Text("Downloads Folder").tag(Self.downloadsFolderTag)
                }
                if savesToDownloads {
                    Text("Saves just the video file to your Downloads folder. It won't be added to a library.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Picker("Resolution", selection: $resolutionRaw) {
                    ForEach(DownloadResolution.allCases) { Text($0.label).tag($0.rawValue) }
                }
                Picker("Quality", selection: $qualityRaw) {
                    ForEach(DownloadQuality.allCases) { Text($0.label).tag($0.rawValue) }
                }
                LabeledContent("YouTube sign-in") {
                    HStack(spacing: 6) {
                        Text(cookieSummary).foregroundStyle(.secondary)
                        Button("Change…") { openSettings(tab: .downloads) }
                            .buttonStyle(.link)
                    }
                }
            }
            .formStyle(.columns)

            if !tools.missingTools.isEmpty, tools.lastChecked != nil {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Missing: \(tools.missingTools.map(\.name).joined(separator: ", "))")
                            .font(.callout.weight(.semibold))
                        Text("Downloads need these free tools. Install them with one click.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button(tools.isUpdating ? "Installing…" : "Install Tools") {
                            Task { await tools.updateAll() }
                        }
                        .disabled(tools.isUpdating)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.orange.opacity(0.1), in: .rect(cornerRadius: 10))
            }

            HStack {
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Download", systemImage: "arrow.down.circle", action: startDownload)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmedURL.isEmpty || urlProblem != nil || !(savesToDownloads || selectedLibrary.isAvailable))
            }
        }
        .padding(24)
        .frame(width: 520)
        .task {
            if urlText.isEmpty,
               let clip = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
               URL(string: clip)?.host != nil {
                urlText = clip
            }
            await tools.refresh()
        }
    }

    private var trimmedURL: String {
        urlText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var urlProblem: String? {
        guard !trimmedURL.isEmpty else { return nil }
        guard let url = URL(string: trimmedURL), let scheme = url.scheme, ["http", "https"].contains(scheme),
              url.host != nil else {
            return "That doesn't look like a web link. Copy the address from your browser and paste it here."
        }
        return nil
    }

    private var looksLikePlaylist: Bool {
        trimmedURL.contains("list=") || trimmedURL.contains("/playlist")
    }

    private var selectedLibrary: LibraryLocation {
        store.libraries.first { $0.id == libraryID } ?? store.selectedLibrary
    }

    /// Picker tag for "Downloads Folder" (not a library).
    private static let downloadsFolderTag = UUID(uuidString: "00000000-0000-0000-0000-00000000D0D0")!

    private var savesToDownloads: Bool { libraryID == Self.downloadsFolderTag }

    private var libraryBinding: Binding<UUID> {
        Binding(get: { savesToDownloads ? Self.downloadsFolderTag : selectedLibrary.id },
                set: { libraryID = $0 })
    }

    private var cookieSummary: String {
        let source = BrowserCookieSource(rawValue: browserCookiesRaw) ?? .none
        if CookieCache.hasSavedCookies, rememberCookies { return "Saved cookies" }
        return source == .none ? "Not signed in" : source.label
    }

    private func startDownload() {
        guard !trimmedURL.isEmpty, urlProblem == nil, savesToDownloads || selectedLibrary.isAvailable else { return }
        store.startDownload(
            url: trimmedURL,
            libraryID: selectedLibrary.id,
            cookiesFromBrowser: BrowserCookieSource(rawValue: browserCookiesRaw) ?? .none,
            rememberCookies: rememberCookies,
            allowsPlaylist: looksLikePlaylist && downloadPlaylist,
            resolution: DownloadResolution(rawValue: resolutionRaw) ?? .p1080,
            quality: DownloadQuality(rawValue: qualityRaw) ?? .balanced,
            toDownloadsFolder: savesToDownloads
        )
        dismiss()
    }
}
