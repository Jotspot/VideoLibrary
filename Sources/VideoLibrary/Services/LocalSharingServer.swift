import AppKit
import Darwin
import Foundation
import IOKit.ps
import Observation

struct SharedLibrarySnapshot: Sendable {
    let library: LibraryLocation
    let items: [VideoItem]
}

private struct ServerBatteryStatus: Sendable {
    let percent: Int
    let stateText: String
    let isCharging: Bool
    let isPluggedIn: Bool

    var displayText: String {
        isCharging ? "Charging" : stateText
    }

    var levelClass: String {
        if percent <= 10 {
            return "battery-critical"
        }
        if percent <= 20 {
            return "battery-low"
        }
        return ""
    }
}

@Observable
@MainActor
final class LocalSharingServer {
    private static let port: UInt = 8026
    private static let reusableTokenEnabledKey = "localSharingReusableTokenEnabled"
    /// Where older versions stored the sharing token in plaintext (migrated by SecurityCheck).
    nonisolated static let legacyReusableTokenKey = "localSharingReusableToken"

    var isRunning = false
    var displayURL: String?
    var errorMessage: String?
    var usesReusableToken = UserDefaults.standard.bool(forKey: reusableTokenEnabledKey)

    private var webServer: GCDWebServer?
    private var state: SharedState?

    func start(libraries: [SharedLibrarySnapshot], selectedLibraryID: UUID) {
        stop()

        let token = tokenForCurrentMode()
        let state = SharedState(
            libraries: Self.shareableLibraries(from: libraries),
            selectedLibraryID: selectedLibraryID,
            token: token
        )
        self.state = state

        let server = GCDWebServer()
        server.addDefaultHandler(forMethod: "GET", request: GCDWebServerRequest.self) { request in
            Self.response(for: request, state: state)
        }

        guard server.start(withPort: Self.port, bonjourName: nil) else {
            self.state = nil
            isRunning = false
            displayURL = nil
            errorMessage = "Could not start local sharing on port \(Self.port)."
            return
        }

        webServer = server
        isRunning = true
        errorMessage = nil
        displayURL = Self.localNetworkURL(token: token)
    }

    func stop() {
        webServer?.stop()
        webServer = nil
        state = nil
        isRunning = false
        displayURL = nil
    }

    func update(libraries: [SharedLibrarySnapshot], selectedLibraryID: UUID) {
        state?.update(
            libraries: Self.shareableLibraries(from: libraries),
            selectedLibraryID: selectedLibraryID
        )
    }

    func copyLink() {
        guard let displayURL else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(displayURL, forType: .string)
    }

    func setUsesReusableToken(
        _ enabled: Bool,
        libraries: [SharedLibrarySnapshot],
        selectedLibraryID: UUID
    ) {
        guard usesReusableToken != enabled else { return }
        usesReusableToken = enabled
        UserDefaults.standard.set(enabled, forKey: Self.reusableTokenEnabledKey)
        if enabled, Self.savedReusableToken() == nil {
            Self.saveReusableToken(Self.makeAccessToken())
        }
        if isRunning {
            start(libraries: libraries, selectedLibraryID: selectedLibraryID)
        }
    }

    func regenerateReusableToken(libraries: [SharedLibrarySnapshot], selectedLibraryID: UUID) {
        Self.saveReusableToken(Self.makeAccessToken())
        if isRunning {
            start(libraries: libraries, selectedLibraryID: selectedLibraryID)
        }
    }

    nonisolated private static func shareableLibraries(
        from libraries: [SharedLibrarySnapshot]
    ) -> [SharedLibrarySnapshot] {
        libraries.compactMap { snapshot in
            let items = snapshot.items.filter { item in
                guard item.status == .downloaded,
                      let path = item.videoFilePath else { return false }
                return FileManager.default.fileExists(atPath: path)
            }
            guard !items.isEmpty else { return nil }
            return SharedLibrarySnapshot(library: snapshot.library, items: items)
        }
    }

    private static func localNetworkURL(token: String) -> String {
        if let ipAddress = localIPv4Address() {
            return "http://\(ipAddress):\(port)/?token=\(token)"
        }
        let hostName = ProcessInfo.processInfo.hostName
        let host = hostName.isEmpty ? "localhost" : hostName
        return "http://\(host):\(port)/?token=\(token)"
    }

    private static func makeAccessToken() -> String {
        // 12 characters from 32 symbols ≈ 60 bits, from the system CSPRNG.
        let chars = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        var generator = SystemRandomNumberGenerator()
        return String((0..<12).map { _ in chars.randomElement(using: &generator)! })
    }

    private func tokenForCurrentMode() -> String {
        guard usesReusableToken else { return Self.makeAccessToken() }
        if let token = Self.savedReusableToken() {
            return token
        }
        let token = Self.makeAccessToken()
        Self.saveReusableToken(token)
        return token
    }

    private static func savedReusableToken() -> String? {
        let token = SecretVault.value(.sharingToken)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return token?.isEmpty == false ? token : nil
    }

    private static func saveReusableToken(_ token: String) {
        SecretVault.set(token, for: .sharingToken)
    }

    private static func localIPv4Address() -> String? {
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0, let firstInterface = interfaces else {
            return nil
        }
        defer { freeifaddrs(interfaces) }

        var candidates: [(name: String, address: String)] = []
        for pointer in sequence(first: firstInterface, next: { $0.pointee.ifa_next }) {
            let interface = pointer.pointee
            guard interface.ifa_addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            let flags = Int32(interface.ifa_flags)
            guard flags & IFF_UP != 0,
                  flags & IFF_RUNNING != 0,
                  flags & IFF_LOOPBACK == 0 else { continue }

            let name = String(cString: interface.ifa_name)
            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(
                interface.ifa_addr,
                socklen_t(interface.ifa_addr.pointee.sa_len),
                &hostname,
                socklen_t(hostname.count),
                nil,
                0,
                NI_NUMERICHOST
            )
            guard result == 0 else { continue }
            candidates.append((name, String(cString: hostname)))
        }

        return candidates.first(where: { $0.name == "en0" })?.address
            ?? candidates.first(where: { $0.name == "en1" })?.address
            ?? candidates.first?.address
    }

    nonisolated private static func response(
        for request: GCDWebServerRequest,
        state: SharedState
    ) -> GCDWebServerResponse {
        switch state.authorize(token: request.query?["token"], from: request.remoteAddressString) {
        case .allowed: break
        case .denied: return textResponse("Forbidden", statusCode: 403)
        case .throttled: return textResponse("Too many wrong links. Try again in a few minutes.", statusCode: 429)
        }

        let path = request.path.removingPercentEncoding ?? request.path
        if path == "/" {
            let libraryID = request.query?["library"]
            let channel = request.query?["channel"]
                ?? request.query?["category"]
                ?? request.query?["uploader"]
            return htmlResponse(libraryHTML(
                state: state,
                libraryID: libraryID,
                channel: channel
            ))
        }
        if path == "/battery" {
            return batteryResponse()
        }
        if path.hasPrefix("/watch/") {
            let id = String(path.dropFirst("/watch/".count))
            guard let item = state.item(id: id) else {
                return textResponse("Not Found", statusCode: 404)
            }
            return htmlResponse(watchHTML(
                item: item,
                token: state.token,
                libraryID: request.query?["library"]
            ))
        }
        if path.hasPrefix("/thumbnail/") {
            let id = String(path.dropFirst("/thumbnail/".count))
            guard let item = state.item(id: id),
                  let thumbnailPath = item.thumbnailPath,
                  FileManager.default.fileExists(atPath: thumbnailPath),
                  let response = GCDWebServerFileResponse(file: thumbnailPath, byteRange: request.byteRange) else {
                return textResponse("Not Found", statusCode: 404)
            }
            response.setValue("no-store", forAdditionalHeader: "Cache-Control")
            return response
        }
        if path.hasPrefix("/captions/") {
            let id = String(path.dropFirst("/captions/".count)).replacingOccurrences(of: ".vtt", with: "")
            guard let item = state.item(id: id), let vtt = webVTT(for: item) else {
                return textResponse("Not Found", statusCode: 404)
            }
            let response = GCDWebServerDataResponse(data: Data(vtt.utf8), contentType: "text/vtt; charset=utf-8")
            response.setValue("no-store", forAdditionalHeader: "Cache-Control")
            return response
        }
        if path.hasPrefix("/video/") {
            let id = String(path.dropFirst("/video/".count))
            guard let item = state.item(id: id),
                  let videoPath = item.videoFilePath,
                  FileManager.default.fileExists(atPath: videoPath),
                  let response = GCDWebServerFileResponse(file: videoPath, byteRange: request.byteRange) else {
                return textResponse("Not Found", statusCode: 404)
            }
            response.setValue("no-store", forAdditionalHeader: "Cache-Control")
            return response
        }

        return textResponse("Not Found", statusCode: 404)
    }

    nonisolated private static func htmlResponse(_ html: String) -> GCDWebServerResponse {
        let response = GCDWebServerDataResponse(
            data: Data(html.utf8),
            contentType: "text/html; charset=utf-8"
        )
        response.setValue("no-store", forAdditionalHeader: "Cache-Control")
        return response
    }

    nonisolated private static func jsonResponse(
        _ json: String,
        statusCode: Int = 200
    ) -> GCDWebServerResponse {
        let response = GCDWebServerDataResponse(
            data: Data(json.utf8),
            contentType: "application/json; charset=utf-8"
        )
        response.statusCode = statusCode
        response.setValue("no-store", forAdditionalHeader: "Cache-Control")
        return response
    }

    nonisolated private static func textResponse(
        _ text: String,
        statusCode: Int
    ) -> GCDWebServerResponse {
        let response = GCDWebServerDataResponse(
            data: Data(text.utf8),
            contentType: "text/plain; charset=utf-8"
        )
        response.statusCode = statusCode
        response.setValue("no-store", forAdditionalHeader: "Cache-Control")
        return response
    }

    nonisolated private static func libraryHTML(
        state: SharedState,
        libraryID: String?,
        channel: String?
    ) -> String {
        guard let selectedLibrary = state.library(id: libraryID) ?? state.selectedLibrary() else {
            return pageHTML(
                title: "VideoLibrary",
                body: """
                <header>
                  <div>
                    <p class="eyebrow">VideoLibrary</p>
                    <h1>No Shared Videos</h1>
                  </div>
                </header>
                <p class="empty">No downloaded videos are available in the selected library.</p>
                """
            )
        }

        let channels = Array(Set(selectedLibrary.items.map(\.uploader))).sorted()
        let selectedChannel = channel.flatMap { channel in
            channel.isEmpty || !channels.contains(channel) ? nil : channel
        }
        let allItems = selectedLibrary.items
        let items = selectedChannel.map { filter in
            allItems.filter { $0.uploader == filter }
        } ?? allItems

        let filters = filtersHTML(
            libraries: state.libraries(),
            selectedLibraryID: selectedLibrary.library.id,
            channels: channels,
            selectedChannel: selectedChannel,
            token: state.token
        )
        let cards = items.map { item in
            let id = escapeAttribute(item.id.uuidString)
            let title = escapeHTML(item.title)
            let uploader = escapeHTML(item.uploader)
            let duration = escapeHTML(item.formattedDuration())
            let thumbnail = "/thumbnail/\(id)?token=\(escapeAttribute(state.token))"
            let watch = "/watch/\(id)?token=\(escapeAttribute(state.token))&library=\(escapeAttribute(selectedLibrary.library.id.uuidString))"
            return """
            <a class="card" href="\(watch)">
              <img src="\(thumbnail)" alt="">
              <div class="meta">
                <h2>\(title)</h2>
                <p><span>\(uploader)</span><span>\(duration)</span></p>
              </div>
            </a>
            """
        }.joined(separator: "\n")

        let emptyState = items.isEmpty
            ? "<p class=\"empty\">No downloaded videos are available in the selected library.</p>"
            : ""
        let battery = batteryStatusHTML()

        return pageHTML(
            title: selectedLibrary.library.name,
            body: """
            <section class="content">
            \(battery)
            <header>
              <div>
                <p class="eyebrow">VideoLibrary</p>
                <h1>\(escapeHTML(selectedLibrary.library.name))</h1>
                \(filters)
              </div>
              <div class="header-status">
                <p class="count">\(items.count) videos</p>
              </div>
            </header>
            \(emptyState)
            <main class="grid">
              \(cards)
            </main>
            </section>
            """
        )
    }

    nonisolated private static func filtersHTML(
        libraries: [SharedLibrarySnapshot],
        selectedLibraryID: UUID,
        channels: [String],
        selectedChannel: String?,
        token: String
    ) -> String {
        let libraryOptions = libraries.map { snapshot in
            let id = snapshot.library.id.uuidString
            let selected = snapshot.library.id == selectedLibraryID ? " selected" : ""
            return """
            <option value="\(escapeAttribute(id))"\(selected)>\(escapeHTML(snapshot.library.name))</option>
            """
        }.joined(separator: "\n")

        let channelOptions = channels.map { channel in
            let selected = channel == selectedChannel ? " selected" : ""
            return """
            <option value="\(escapeAttribute(channel))"\(selected)>\(escapeHTML(channel))</option>
            """
        }.joined(separator: "\n")

        return """
        <form class="filters-form" method="get">
          <input type="hidden" name="token" value="\(escapeAttribute(token))">
          <div class="filter-control">
            <span class="filter-prefix">Library</span>
            <label class="visually-hidden" for="library">Library</label>
            <select id="library" name="library" onchange="this.form.submit()">
              \(libraryOptions)
            </select>
          </div>
          <div class="filter-control">
            <span class="filter-prefix">Channel</span>
            <label class="visually-hidden" for="channel">Channel</label>
            <select id="channel" name="channel" onchange="this.form.submit()">
              <option value="">All Channels</option>
              \(channelOptions)
            </select>
          </div>
        </form>
        """
    }

    // MARK: - Captions

    /// The caption file the app itself would show (English first).
    nonisolated private static func captionPath(for item: VideoItem) -> String? {
        let path = ["en", "en-orig", "en-US"].lazy.compactMap { item.subtitlePaths[$0] }.first
            ?? item.subtitlePaths.values.first
        return path.flatMap { FileManager.default.fileExists(atPath: $0) ? $0 : nil }
    }

    /// Clean WebVTT built with the same parser and caption behavior as the
    /// app (two lines at a time, one line, or rolling). With "show words as
    /// they're spoken", each word carries an inline timestamp, so browsers
    /// that support it reveal words as they're said (see `captionCSS`).
    nonisolated static func webVTT(for item: VideoItem) -> String? {
        guard let path = captionPath(for: item) else { return nil }
        let defaults = UserDefaults.standard
        let behavior = defaults.string(forKey: "captionBehavior").flatMap(CaptionBehavior.init(rawValue:)) ?? .pairs
        let revealWords = defaults.object(forKey: "captionRevealWords") as? Bool ?? true
        guard let cues = try? SubtitleParser.parse(fileURL: URL(fileURLWithPath: path), behavior: behavior),
              !cues.isEmpty else { return nil }

        func stamp(_ t: TimeInterval) -> String {
            let ms = Int((max(0, t) * 1000).rounded())
            return String(format: "%02d:%02d:%02d.%03d", ms / 3_600_000, (ms / 60_000) % 60, (ms / 1000) % 60, ms % 1000)
        }
        func clean(_ text: String) -> String {
            text.replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
        }

        var out = "WEBVTT\n\n"
        for cue in cues where cue.end > cue.start {
            let text: String
            if cue.hasWordTimings {
                text = cue.lines.map { words in
                    words.map { word in
                        let timed = revealWords && word.time > cue.start + 0.01 && word.time < cue.end
                        return (timed ? "<\(stamp(word.time))>" : "") + clean(word.text)
                    }.joined()
                }.joined(separator: "\n")
            } else {
                text = clean(cue.text)
            }
            out += "\(stamp(cue.start)) --> \(stamp(cue.end)) line:-2\n\(text)\n\n"
        }
        return out
    }

    /// Mirrors the app's caption style (color, weight, box opacity) in the
    /// browser; words not yet spoken stay hidden where ::cue(:future) works.
    nonisolated private static func captionCSS() -> String {
        let defaults = UserDefaults.standard
        let colors = ["white": "#ffffff", "yellow": "#ffe633", "cyan": "#66e6ff", "green": "#80ff80"]
        let color = colors[defaults.string(forKey: "captionColor") ?? "white"] ?? "#ffffff"
        let weights = ["regular": "400", "semibold": "600", "bold": "700"]
        let weight = weights[defaults.string(forKey: "captionWeight") ?? "semibold"] ?? "600"
        let background = defaults.string(forKey: "captionBackground") ?? "box"
        let opacity = defaults.object(forKey: "captionBackgroundOpacity") as? Double ?? 0.72
        let backdrop = (background == "box" || background == "lineBoxes")
            ? "rgba(0,0,0,\(String(format: "%.2f", opacity)))"
            : "transparent"
        let shadow = background == "outline"
            ? "text-shadow: 1px 1px 0 #000, -1px -1px 0 #000, 1px -1px 0 #000, -1px 1px 0 #000;"
            : ""
        return """
        video::cue { color: \(color); font-weight: \(weight); background-color: \(backdrop); \(shadow) font-family: -apple-system, system-ui, sans-serif; }
        video::cue(:future) { color: transparent; }
        """
    }

    nonisolated private static func watchHTML(
        item: VideoItem,
        token: String,
        libraryID: String?
    ) -> String {
        let id = escapeAttribute(item.id.uuidString)
        let title = escapeHTML(item.title)
        let uploader = escapeHTML(item.uploader)
        let video = "/video/\(id)?token=\(escapeAttribute(token))"
        let poster = "/thumbnail/\(id)?token=\(escapeAttribute(token))"
        let libraryQuery = libraryID.map { "&library=\(escapeAttribute($0))" } ?? ""
        let captionsOn = UserDefaults.standard.object(forKey: "captionsEnabled") as? Bool ?? true
        let track = captionPath(for: item) == nil ? "" : """
            <track kind="captions" srclang="en" label="English" src="/captions/\(id).vtt?token=\(escapeAttribute(token))"\(captionsOn ? " default" : "")>
            """

        return pageHTML(
            title: item.title,
            body: """
            <p><a class="back" href="/?token=\(escapeAttribute(token))\(libraryQuery)">Back to library</a></p>
            <section class="player">
              <video controls playsinline preload="metadata" poster="\(poster)" src="\(video)">\(track)</video>
            </section>
            <style>\(captionCSS())</style>
            <section class="details">
              <h1>\(title)</h1>
              <p>\(uploader) · \(escapeHTML(item.formattedDuration()))</p>
            </section>
            """
        )
    }

    nonisolated private static func pageHTML(title: String, body: String) -> String {
        """
        <!doctype html>
        <html>
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <title>\(escapeHTML(title))</title>
          <style>
            :root { color-scheme: dark; font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; }
            body { margin: 0; background: #151515; color: #f5f5f5; }
            header { display: flex; align-items: end; justify-content: space-between; gap: 24px; padding: 32px; }
            h1, h2, p { margin: 0; }
            .eyebrow, .count, .meta p, .details p, .empty { color: #aaa; }
            .eyebrow { font-size: 13px; font-weight: 700; letter-spacing: .08em; text-transform: uppercase; margin-bottom: 6px; }
            .grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(280px, 1fr)); gap: 22px; padding: 0 32px 40px; }
            .card { color: inherit; text-decoration: none; background: #222; border: 1px solid #333; border-radius: 18px; overflow: hidden; box-shadow: 0 10px 30px rgb(0 0 0 / .25); }
            .card:hover { border-color: #0a84ff; transform: translateY(-1px); }
            img { display: block; width: 100%; aspect-ratio: 16 / 9; object-fit: cover; background: #333; }
            .meta { padding: 16px; }
            .meta h2 { font-size: 18px; line-height: 1.2; margin-bottom: 8px; }
            .meta p { display: flex; justify-content: space-between; gap: 12px; font-size: 14px; }
            .empty { padding: 0 32px; }
            .back { display: inline-block; color: #8ec5ff; margin: 24px 32px; text-decoration: none; }
            .player { padding: 0 32px; }
            video { width: 100%; max-height: 72vh; background: #000; border-radius: 18px; }
            .details { padding: 24px 32px 40px; }
            .details h1 { margin-bottom: 8px; }
            .content { min-width: 0; }
            .header-status { display: grid; justify-items: end; gap: 10px; }
            .battery-status { position: fixed; top: 18px; right: 18px; z-index: 20; display: inline-flex; align-items: center; gap: 8px; color: #f5f5f5; font-size: 14px; white-space: nowrap; background: rgb(32 32 32 / .88); border: 1px solid #3a3a3a; border-radius: 999px; padding: 8px 11px; box-shadow: 0 8px 24px rgb(0 0 0 / .25); backdrop-filter: blur(14px); }
            .battery-label { color: #888; font-weight: 650; }
            .battery-icon { position: relative; width: 28px; height: 14px; border: 2px solid currentColor; border-radius: 4px; box-sizing: border-box; }
            .battery-icon::after { content: ""; position: absolute; right: -5px; top: 3px; width: 3px; height: 6px; border-radius: 0 2px 2px 0; background: currentColor; }
            .battery-fill { display: block; height: 100%; border-radius: 2px; background: currentColor; }
            .battery-plugged { color: #32d74b; }
            .filters-form { display: flex; flex-wrap: wrap; gap: 8px; margin-top: 14px; color: #aaa; max-width: min(720px, calc(100vw - 64px)); }
            .filter-control { display: inline-flex; align-items: center; gap: 7px; min-width: 0; max-width: 300px; background: #252525; border: 1px solid #383838; border-radius: 999px; padding: 5px 9px 5px 11px; }
            .filter-control:focus-within { border-color: #0a84ff; box-shadow: 0 0 0 3px rgb(10 132 255 / .18); }
            .filter-prefix { color: #8f8f8f; font-size: 12px; font-weight: 750; letter-spacing: .02em; text-transform: uppercase; }
            .filters-form select { min-width: 0; max-width: 185px; color: #f5f5f5; background: transparent; border: 0; font: inherit; font-size: 14px; font-weight: 650; outline: none; padding: 2px 18px 2px 0; text-overflow: ellipsis; }
            .visually-hidden { position: absolute; width: 1px; height: 1px; padding: 0; margin: -1px; overflow: hidden; clip: rect(0 0 0 0); white-space: nowrap; border: 0; }
            @media (max-width: 640px) {
              header { align-items: start; flex-direction: column; }
              .header-status { justify-items: start; }
              .battery-status { top: 10px; right: 10px; transform: scale(.92); transform-origin: top right; }
              .filters-form { max-width: calc(100vw - 64px); }
              .filter-control { max-width: 100%; }
              .filters-form select { max-width: 160px; }
            }
          </style>
        </head>
        <body>
        \(body)
        <script>
          (() => {
            const token = new URLSearchParams(window.location.search).get('token');
            if (!token) return;

            function applyBattery(data) {
              document.querySelectorAll('.battery-status').forEach((element) => {
                element.classList.toggle('battery-low', data.levelClass === 'battery-low');
                element.classList.toggle('battery-critical', data.levelClass === 'battery-critical');
                element.classList.toggle('battery-plugged', data.pluggedIn === true);
                element.title = `Mac server battery: ${data.percent}%, ${data.state}`;
                const fill = element.querySelector('.battery-fill');
                const percent = element.querySelector('.battery-percent');
                if (fill) fill.style.width = `${data.percent}%`;
                if (percent) percent.textContent = `${data.percent}%`;
              });
            }

            async function refreshBattery() {
              try {
                const response = await fetch(`/battery?token=${encodeURIComponent(token)}`, {
                  cache: 'no-store'
                });
                if (!response.ok) return;
                applyBattery(await response.json());
              } catch (_) {}
            }

            window.setInterval(refreshBattery, 30000);
            refreshBattery();
          })();
        </script>
        </body>
        </html>
        """
    }

    nonisolated private static func escapeHTML(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    nonisolated private static func escapeAttribute(_ value: String) -> String {
        escapeHTML(value)
    }

    nonisolated private static func batteryStatusHTML() -> String {
        guard let status = currentBatteryStatus() else { return "" }
        let levelClass = status.levelClass.isEmpty ? "" : " \(status.levelClass)"
        let pluggedClass = status.isPluggedIn ? " battery-plugged" : ""

        return """
        <div class="battery-status\(levelClass)\(pluggedClass)" title="Mac server battery: \(escapeAttribute(status.percent.description))%, \(escapeAttribute(status.displayText))">
          <span class="battery-label">Server battery</span>
          <span class="battery-icon" aria-hidden="true"><span class="battery-fill" style="width: \(status.percent)%"></span></span>
          <span class="battery-percent">\(status.percent)%</span>
        </div>
        """
    }

    nonisolated private static func batteryResponse() -> GCDWebServerResponse {
        guard let status = currentBatteryStatus() else {
            return jsonResponse("{\"available\":false}", statusCode: 404)
        }

        return jsonResponse("""
        {"available":true,"percent":\(status.percent),"state":"\(escapeJSONString(status.displayText))","levelClass":"\(escapeJSONString(status.levelClass))","charging":\(status.isCharging),"pluggedIn":\(status.isPluggedIn)}
        """)
    }

    nonisolated private static func currentBatteryStatus() -> ServerBatteryStatus? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else {
            return nil
        }

        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(info, source)?
                .takeUnretainedValue() as? [String: Any],
                (description[kIOPSIsPresentKey] as? Bool) != false,
                let current = description[kIOPSCurrentCapacityKey] as? Int,
                let maximum = description[kIOPSMaxCapacityKey] as? Int,
                maximum > 0 else {
                continue
            }

            let percent = Int((Double(current) / Double(maximum) * 100).rounded())
            let isCharging = description[kIOPSIsChargingKey] as? Bool ?? false
            let fullyCharged = description[kIOPSIsChargedKey] as? Bool ?? false
            let powerState = description[kIOPSPowerSourceStateKey] as? String
            let isPluggedIn = isCharging || fullyCharged || powerState == kIOPSACPowerValue
            let stateText: String
            if fullyCharged {
                stateText = "Charged"
            } else if powerState == kIOPSACPowerValue {
                stateText = "Plugged in"
            } else {
                stateText = "On battery"
            }

            return ServerBatteryStatus(
                percent: max(0, min(100, percent)),
                stateText: stateText,
                isCharging: isCharging,
                isPluggedIn: isPluggedIn
            )
        }

        return nil
    }

    nonisolated private static func escapeJSONString(_ value: String) -> String {
        var escaped = ""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"":
                escaped += "\\\""
            case "\\":
                escaped += "\\\\"
            case "\n":
                escaped += "\\n"
            case "\r":
                escaped += "\\r"
            case "\t":
                escaped += "\\t"
            default:
                if scalar.value < 0x20 {
                    escaped += String(format: "\\u%04x", scalar.value)
                } else {
                    escaped.unicodeScalars.append(scalar)
                }
            }
        }
        return escaped
    }

}

private final class SharedState: @unchecked Sendable {
    private let lock = NSLock()
    private var storedLibraries: [SharedLibrarySnapshot]
    private var storedSelectedLibraryID: UUID
    let token: String

    init(libraries: [SharedLibrarySnapshot], selectedLibraryID: UUID, token: String) {
        self.storedLibraries = libraries
        self.storedSelectedLibraryID = selectedLibraryID
        self.token = token
    }

    func libraries() -> [SharedLibrarySnapshot] {
        lock.lock()
        defer { lock.unlock() }
        return storedLibraries
    }

    func selectedLibrary() -> SharedLibrarySnapshot? {
        lock.lock()
        defer { lock.unlock() }
        return storedLibraries.first { $0.library.id == storedSelectedLibraryID }
            ?? storedLibraries.first
    }

    func library(id: String?) -> SharedLibrarySnapshot? {
        guard let id, let uuid = UUID(uuidString: id) else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return storedLibraries.first { $0.library.id == uuid }
    }

    func item(id: String) -> VideoItem? {
        lock.lock()
        defer { lock.unlock() }
        return storedLibraries
            .lazy
            .flatMap(\.items)
            .first { $0.id.uuidString == id }
    }

    enum Authorization { case allowed, denied, throttled }

    private var failures: [String: (count: Int, since: Date)] = [:]

    /// Constant-time token check, with a lockout after repeated wrong
    /// tokens from one device so the link can't be brute-forced.
    func authorize(token: String?, from address: String) -> Authorization {
        let host = address.split(separator: ":").dropLast().joined(separator: ":")
        let key = host.isEmpty ? address : host
        lock.lock()
        defer { lock.unlock() }
        if let entry = failures[key], Date().timeIntervalSince(entry.since) > 600 {
            failures[key] = nil
        }
        if let entry = failures[key], entry.count >= 20 { return .throttled }

        let expected = Array(self.token.utf8)
        let given = Array((token ?? "").utf8)
        var difference = UInt8(expected.count == given.count ? 0 : 1)
        for index in expected.indices {
            difference |= expected[index] ^ (index < given.count ? given[index] : 0)
        }
        guard difference == 0 else {
            let entry = failures[key] ?? (0, Date())
            failures[key] = (entry.count + 1, entry.since)
            return .denied
        }
        return .allowed
    }

    func update(libraries: [SharedLibrarySnapshot], selectedLibraryID: UUID) {
        lock.lock()
        storedLibraries = libraries
        storedSelectedLibraryID = selectedLibraryID
        lock.unlock()
    }
}
