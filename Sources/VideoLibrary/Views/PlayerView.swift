import SwiftUI
import AppKit

/// Full-window player. The video fills the window edge to edge; the top bar,
/// transport controls and window buttons only appear while the pointer is
/// over the window (or the video is paused). Captions sit in the same layout
/// stack as the controls, directly above them, so the two never overlap.
///
/// Keyboard: Space/K play-pause · ←/→ 5s · J/L 10s · ,/. one frame · ↑/↓ volume · M mute ·
/// F fullscreen · C captions · I picture in picture · Esc exits fullscreen, then closes.
struct PlayerView: View {
    @Environment(LibraryStore.self) private var store
    @AppStorage("playerOpensFullScreen") private var opensFullScreen = false
    @AppStorage(AppPreference.fitWindowToVideo) private var fitsWindowToVideo = true
    @AppStorage(CaptionPreference.behavior) private var captionBehavior = CaptionBehavior.pairs
    @AppStorage(CaptionPreference.size) private var captionSize = CaptionSize.medium
    @AppStorage(CaptionPreference.font) private var captionFont = CaptionFont.system
    @AppStorage(CaptionPreference.weight) private var captionWeight = CaptionWeight.semibold
    @AppStorage(CaptionPreference.color) private var captionColor = CaptionColor.white
    @AppStorage(CaptionPreference.background) private var captionBackground = CaptionBackground.box
    @AppStorage(CaptionPreference.backgroundOpacity) private var captionBackgroundOpacity = 0.72
    @AppStorage(CaptionPreference.position) private var captionPosition = CaptionPosition.bottom
    @AppStorage(CaptionPreference.revealWords) private var captionRevealWords = true
    @AppStorage(CaptionPreference.animated) private var captionAnimated = false
    @AppStorage(CaptionPreference.holdThroughPauses) private var captionHoldsThroughPauses = true

    let item: VideoItem
    let player: NativePlayerService
    @Binding var captionsEnabled: Bool
    let close: () -> Void

    @State private var chrome = PlayerChromeModel()
    @State private var subtitles: [SubtitleCue] = []
    @State private var currentCue: SubtitleCue? = nil
    @State private var loadError: String? = nil
    @State private var lastStoredProgress: TimeInterval = 0
    @State private var activeItemID: UUID?
    @State private var scrubTime: Double?

    var body: some View {
        ZStack {
            Color.black

            if let error = loadError {
                ContentUnavailableView {
                    Label("Can't Play This Video", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error)
                } actions: {
                    Button("Back to Library", action: leave)
                        .buttonStyle(.borderedProminent)
                }
            } else {
                AVKitPlayerView(service: player)
            }

            // Click to play/pause, double-click for fullscreen.
            Color.clear
                .contentShape(.rect)
                .gesture(
                    TapGesture(count: 2)
                        .onEnded { chrome.toggleFullScreen() }
                        .exclusively(before: TapGesture().onEnded {
                            player.togglePlayPause()
                            chrome.revealControls()
                        })
                )

            VStack(spacing: 0) {
                // Keeps the toolbar's title readable over bright video.
                LinearGradient(colors: [.black.opacity(0.6), .clear], startPoint: .top, endPoint: .bottom)
                    .frame(height: 110)
                    .opacity(chrome.controlsVisible ? 1 : 0)
                    .allowsHitTesting(false)
                Spacer(minLength: 0)
            }

            // In full screen the system toolbar sits in an opaque gray strip
            // above the video, so it's hidden there and these controls float
            // over the video on a soft blur instead.
            if chrome.isFullScreen, chrome.controlsVisible, loadError == nil {
                VStack(spacing: 0) {
                    fullScreenTopBar
                    Spacer(minLength: 0)
                }
                .transition(.opacity)
            }

            VStack(spacing: 0) {
                if captionPosition == .top {
                    subtitleView
                        .padding(.top, chrome.controlsVisible ? 64 : 40)
                        .animation(captionAnimated ? .easeOut(duration: 0.2) : nil, value: currentCue == nil)
                }
                Spacer(minLength: 0)
                if captionPosition == .bottom {
                    subtitleView
                        .padding(.bottom, chrome.controlsVisible ? 10 : 40)
                        .animation(captionAnimated ? .easeOut(duration: 0.2) : nil, value: currentCue == nil)
                }
                if chrome.controlsVisible, loadError == nil {
                    transportBar.transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.22), value: chrome.controlsVisible)
        }
        .ignoresSafeArea()
        .environment(\.colorScheme, .dark)
        .toolbar { playerToolbar }
        .toolbar((chrome.controlsVisible || loadError != nil) && !chrome.isFullScreen ? .visible : .hidden,
                 for: .windowToolbar)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .animation(.easeInOut(duration: 0.22), value: chrome.controlsVisible)
        .onContinuousHover { phase in
            switch phase {
            case .active: chrome.pointerMoved()
            case .ended: chrome.pointerLeft()
            }
        }
        .background(WindowAccessor { window in
            chrome.attach(to: window, enterFullScreen: opensFullScreen)
            if fitsWindowToVideo, !opensFullScreen, player.videoSize != .zero {
                chrome.fitWindow(to: player.videoSize)   // e.g. returning from the miniplayer
            }
        })
        .onChange(of: player.videoSize) { _, size in
            if fitsWindowToVideo, !opensFullScreen, size != .zero { chrome.fitWindow(to: size) }
        }
        .onAppear {
            chrome.isPlaying = { player.isPlaying }
            chrome.onKey = handleKey
            loadVideo()
        }
        .onDisappear {
            saveWatchProgress(at: player.currentPlaybackTime, force: true)
            if player.isHandingOff {
                player.isHandingOff = false   // the miniplayer keeps it going
            } else {
                player.stop()
            }
            chrome.detach()
        }
        .onChange(of: item.id) { _, _ in loadVideo() }
        .onChange(of: captionHoldsThroughPauses) { _, _ in updateCue(at: player.currentPlaybackTime) }
        .onChange(of: captionBehavior) { _, _ in
            loadSubtitles()
            updateCue(at: player.currentPlaybackTime)
        }
        .onChange(of: player.currentPlaybackTime) { _, t in
            updateCue(at: t)
            saveWatchProgress(at: t)
        }
        .onChange(of: player.isPlaying) { _, _ in chrome.revealControls() }
    }

    /// Back to the library: snap the window to its pre-video size first, so
    /// the library appears at the right size instead of resizing after.
    private func leave() {
        chrome.restoreWindowFrame(animated: false)
        close()
    }

    // MARK: - Toolbar

    /// Lives in the window toolbar, so the controls are regular size and
    /// line up with the close/minimize/zoom buttons.
    @ToolbarContentBuilder
    private var playerToolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button(action: leave) {
                Label("Library", systemImage: "chevron.left")
                    .labelStyle(.titleAndIcon)
            }
            .help("Back to Library (Esc)")
        }

        ToolbarItem(placement: .navigation) {
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .font(.headline)
                    .lineLimit(1)
                Text(playerSubtitle)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1)
            }
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.5), radius: 3)
            .padding(.leading, 6)
            .frame(maxWidth: 520, alignment: .leading)
        }
        .sharedBackgroundVisibility(.hidden)

        // Push Picture in Picture and Share to the trailing edge.
        ToolbarSpacer(.flexible)

        ToolbarItemGroup(placement: .primaryAction) {
            if player.canUsePictureInPicture {
                Button {
                    player.togglePictureInPicture()
                } label: {
                    Label("Picture in Picture",
                          systemImage: player.isPictureInPictureActive ? "pip.exit" : "pip.enter")
                }
                .help("Picture in Picture (I)")
            }

            if let url = item.videoURL {
                Button {
                    VideoSharingService.sendViaAirDrop(url)
                } label: {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
                .help("Share via AirDrop")
            }
        }
    }

    private var fullScreenTopBar: some View {
        HStack(spacing: 14) {
            Button(action: leave) {
                Label("Library", systemImage: "chevron.left")
                    .labelStyle(.titleAndIcon)
                    .padding(.horizontal, 4)
            }
            .buttonStyle(.glass)
            .controlSize(.large)
            .help("Back to Library (Esc)")

            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).font(.headline).lineLimit(1)
                Text(playerSubtitle)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1)
            }
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.5), radius: 3)

            Spacer(minLength: 20)

            if player.canUsePictureInPicture {
                Button {
                    player.togglePictureInPicture()
                } label: {
                    Image(systemName: player.isPictureInPictureActive ? "pip.exit" : "pip.enter")
                }
                .buttonStyle(.glass)
                .controlSize(.large)
                .help("Picture in Picture (I)")
            }
            if let url = item.videoURL {
                Button {
                    VideoSharingService.sendViaAirDrop(url)
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .buttonStyle(.glass)
                .controlSize(.large)
                .help("Share via AirDrop")
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 18)
        .padding(.bottom, 36)
        .background {
            // Blur that fades out downward instead of a hard-edged bar.
            Rectangle()
                .fill(.ultraThinMaterial)
                .mask(LinearGradient(colors: [.black, .black.opacity(0.7), .clear],
                                     startPoint: .top, endPoint: .bottom))
                .ignoresSafeArea()
        }
        .onHover { chrome.isHoveringControls = $0 }
    }

    /// "Uploader · Oct 3, 2026 · 1080p"
    private var playerSubtitle: String {
        var parts = [item.uploader]
        if let uploaded = item.uploadDate {
            parts.append(uploaded.formatted(date: .abbreviated, time: .omitted))
        }
        if let resolution = store.resolutionLabels[item.id] { parts.append(resolution) }
        return parts.joined(separator: " · ")
    }

    // MARK: - Transport bar

    private var transportBar: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Text(formatTime(scrubTime ?? player.currentPlaybackTime))
                    .frame(minWidth: 44, alignment: .trailing)
                Slider(
                    value: Binding(
                        get: { scrubTime ?? player.currentPlaybackTime },
                        set: { scrubTime = $0; player.seek(to: $0) }
                    ),
                    in: 0...max(player.duration, 1),
                    onEditingChanged: { editing in
                        if !editing { scrubTime = nil }
                    }
                )
                .controlSize(.small)
                .disabled(player.duration <= 0)
                Text("-" + formatTime(max(0, player.duration - (scrubTime ?? player.currentPlaybackTime))))
                    .frame(minWidth: 50, alignment: .leading)
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.white.opacity(0.85))

            HStack(spacing: 6) {
                controlButton("gobackward.10", help: "Back 10 seconds (J)") { player.seek(by: -10) }
                controlButton(player.isPlaying ? "pause.fill" : "play.fill",
                              help: player.isPlaying ? "Pause (Space)" : "Play (Space)",
                              size: .title2) { player.togglePlayPause() }
                controlButton("goforward.10", help: "Forward 10 seconds (L)") { player.seek(by: 10) }

                volumeControl
                    .padding(.leading, 8)

                Spacer(minLength: 8)

                speedMenu

                if !subtitles.isEmpty {
                    controlButton(captionsEnabled ? "captions.bubble.fill" : "captions.bubble",
                                  help: captionsEnabled ? "Hide Captions (C)" : "Show Captions (C)") {
                        captionsEnabled.toggle()
                    }
                }

                controlButton(chrome.isFullScreen
                                ? "arrow.down.right.and.arrow.up.left"
                                : "arrow.up.left.and.arrow.down.right",
                              help: chrome.isFullScreen ? "Exit Full Screen (F)" : "Full Screen (F)") {
                    chrome.toggleFullScreen()
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
        .frame(maxWidth: 960)
        .padding(.horizontal, 20)
        .padding(.bottom, 18)
        .onHover { chrome.isHoveringControls = $0 }
    }

    private var volumeControl: some View {
        HStack(spacing: 6) {
            controlButton(volumeSymbol, help: player.isMuted ? "Unmute (M)" : "Mute (M)") {
                player.toggleMute()
            }
            Slider(
                value: Binding(
                    get: { Double(player.isMuted ? 0 : player.volume) },
                    set: { player.volume = Float($0) }
                ),
                in: 0...1
            )
            .controlSize(.mini)
            .frame(width: 90)
        }
    }

    private var volumeSymbol: String {
        if player.isMuted || player.volume == 0 { return "speaker.slash.fill" }
        return player.volume < 0.5 ? "speaker.wave.1.fill" : "speaker.wave.3.fill"
    }

    private var speedMenu: some View {
        Menu {
            Picker("Playback Speed", selection: Binding(get: { player.rate }, set: { player.rate = $0 })) {
                ForEach([Float(0.5), 0.75, 1, 1.25, 1.5, 1.75, 2], id: \.self) { rate in
                    Text(rate == 1 ? "Normal" : "\(rate.formatted())×").tag(rate)
                }
            }
            .pickerStyle(.inline)
        } label: {
            Text("\(player.rate.formatted())×")
                .font(.callout.monospacedDigit().weight(.semibold))
                .foregroundStyle(.white)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .padding(.horizontal, 8)
        .help("Playback Speed")
    }

    private func controlButton(
        _ systemImage: String,
        help: String,
        size: Font = .title3,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(size)
                .foregroundStyle(.white)
                .frame(width: 34, height: 30)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(help)
    }

    // MARK: - Captions

    @ViewBuilder
    private var subtitleView: some View {
        if captionsEnabled, let cue = currentCue, !cue.text.isEmpty {
            CaptionText(
                cue: cue,
                time: player.currentPlaybackTime,
                revealWords: captionRevealWords,
                style: captionStyle,
                scale: chrome.isFullScreen ? 1.35 : 1
            )
            .transition(captionAnimated ? .opacity : .identity)
                .frame(maxWidth: 900)
                .padding(.horizontal, 24)
                .allowsHitTesting(false)
        }
    }

    private var captionStyle: CaptionStyle {
        CaptionStyle(
            behavior: captionBehavior,
            size: captionSize,
            font: captionFont,
            weight: captionWeight,
            color: captionColor,
            background: captionBackground,
            backgroundOpacity: captionBackgroundOpacity,
            position: captionPosition,
            animated: captionAnimated
        )
    }

    // MARK: - Keyboard

    private func handleKey(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 53:                                               // Esc
            chrome.isFullScreen ? chrome.toggleFullScreen() : leave()
            return true
        case 49: player.togglePlayPause(); return true         // Space
        case 123: player.seek(by: -5); return true             // ←
        case 124: player.seek(by: 5); return true              // →
        case 126: player.adjustVolume(by: 0.1); return true    // ↑
        case 125: player.adjustVolume(by: -0.1); return true   // ↓
        default: break
        }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "k": player.togglePlayPause()
        case "i" where player.canUsePictureInPicture: player.togglePictureInPicture()
        case "j": player.seek(by: -10)
        case "l": player.seek(by: 10)
        case ",": player.step(frames: -1)
        case ".": player.step(frames: 1)
        case "m": player.toggleMute()
        case "f": chrome.toggleFullScreen()
        case "c" where !subtitles.isEmpty: captionsEnabled.toggle()
        default: return false
        }
        return true
    }

    // MARK: - Loading

    private func loadVideo() {
        if let activeItemID, activeItemID != item.id {
            saveWatchProgress(for: activeItemID, at: player.currentPlaybackTime, force: true)
        }

        loadError = nil
        currentCue = nil
        loadSubtitles()

        guard let url = item.videoURL else {
            loadError = "This library entry has no video file attached. Try downloading it again."
            return
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            loadError = url.path.hasPrefix("/Volumes/")
                ? "The video is on a drive that isn't connected. Connect the drive and try again."
                : "The video file was moved or deleted:\n\(url.path)"
            return
        }
        activeItemID = item.id
        lastStoredProgress = item.watchProgress
        player.load(url: url, startAt: resumeTime)
        player.play()
        updateCue(at: player.currentPlaybackTime)
    }

    private func loadSubtitles() {
        subtitles = []
        let path = ["en", "en-orig", "en-US"].lazy.compactMap { item.subtitlePaths[$0] }.first
            ?? item.subtitlePaths.values.first
        guard let path else { return }
        subtitles = (try? SubtitleParser.parse(fileURL: URL(fileURLWithPath: path), behavior: captionBehavior)) ?? []
    }

    private func updateCue(at time: Double) {
        var cue = subtitles.first { $0.start <= time && $0.end > time }
        // Bridge short silences: keep the last caption up (up to 1.5 s)
        // until the next one starts, so the box doesn't blink off and on.
        if cue == nil, captionHoldsThroughPauses,
           let last = subtitles.last(where: { $0.start <= time }),
           time - last.end < 1.5 {
            cue = last
        }
        if cue?.id != currentCue?.id { currentCue = cue }
    }

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "0:00" }
        let total = Int(seconds.rounded(.down))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    private var resumeTime: TimeInterval {
        guard item.watchProgress > 0 else { return 0 }
        guard item.duration <= 0 || item.watchProgress < item.duration - 10 else { return 0 }
        return item.watchProgress
    }

    private func saveWatchProgress(at seconds: TimeInterval, force: Bool = false) {
        guard let activeItemID else { return }
        saveWatchProgress(for: activeItemID, at: seconds, force: force)
    }

    private func saveWatchProgress(
        for itemID: UUID,
        at seconds: TimeInterval,
        force: Bool = false
    ) {
        guard seconds.isFinite, seconds >= 0 else { return }
        guard force || abs(seconds - lastStoredProgress) >= 5 else { return }
        lastStoredProgress = seconds
        store.updateWatchProgress(for: itemID, seconds: seconds)
    }
}

/// Window-level state for the player: fullscreen, hover-driven control
/// visibility, the window's traffic-light buttons, and the keyboard monitor.
/// Kept out of the view struct so the NSEvent monitor has a stable owner.
@Observable
@MainActor
final class PlayerChromeModel {
    private(set) var isFullScreen = false
    private(set) var controlsVisible = true {
        didSet { setWindowButtonsVisible(controlsVisible) }
    }
    var isHoveringControls = false {
        didSet { if isHoveringControls { revealControls() } else { scheduleHide() } }
    }

    @ObservationIgnored var onKey: ((NSEvent) -> Bool)?
    @ObservationIgnored var isPlaying: () -> Bool = { true }

    @ObservationIgnored private weak var window: NSWindow?
    /// The window's frame before it was fitted to the video, restored on exit.
    @ObservationIgnored private var frameBeforeFitting: NSRect?
    @ObservationIgnored private var wasFullScreenBeforePlayer = false
    @ObservationIgnored private var pointerInside = true
    @ObservationIgnored private var keyMonitor: Any?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var hideTask: Task<Void, Never>?

    func attach(to window: NSWindow, enterFullScreen: Bool) {
        guard self.window == nil else { return }
        self.window = window
        wasFullScreenBeforePlayer = window.styleMask.contains(.fullScreen)
        isFullScreen = wasFullScreenBeforePlayer

        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: NSWindow.willEnterFullScreenNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.isFullScreen = true }
            },
            center.addObserver(forName: NSWindow.willExitFullScreenNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.isFullScreen = false }
            }
        ]

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let consumed = MainActor.assumeIsolated { self?.consumesKeyDown(event) ?? false }
            return consumed ? nil : event
        }

        if enterFullScreen, !wasFullScreenBeforePlayer {
            window.toggleFullScreen(nil)
        }
        revealControls()
    }

    func detach() {
        hideTask?.cancel()
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        NSCursor.setHiddenUntilMouseMoves(false)
        setWindowButtonsVisible(true)
        restoreWindowFrame()
        // Put the window back the way the player found it.
        if let window, window.styleMask.contains(.fullScreen), !wasFullScreenBeforePlayer {
            DispatchQueue.main.async { window.toggleFullScreen(nil) }
        }
        window = nil
    }

    func toggleFullScreen() {
        window?.toggleFullScreen(nil)
    }

    /// Resizes the window to the video's shape (keeping its width and centre
    /// where possible), remembering the old frame for `restoreWindowFrame`.
    func fitWindow(to videoSize: CGSize) {
        guard let window, videoSize.width > 0, videoSize.height > 0,
              !window.styleMask.contains(.fullScreen),
              let screen = window.screen?.visibleFrame else { return }
        let aspect = videoSize.width / videoSize.height
        let current = window.frame
        if frameBeforeFitting == nil { frameBeforeFitting = current }

        var width = current.width
        var height = width / aspect
        let maxHeight = screen.height * 0.92
        if height > maxHeight {
            height = maxHeight
            width = height * aspect
        }
        width = min(max(width, 480), screen.width)
        height = width / aspect

        var frame = NSRect(x: current.midX - width / 2, y: current.maxY - height, width: width, height: height)
        frame.origin.x = min(max(frame.minX, screen.minX), screen.maxX - frame.width)
        frame.origin.y = min(max(frame.minY, screen.minY), screen.maxY - frame.height)
        guard abs(frame.width - current.width) > 2 || abs(frame.height - current.height) > 2 else { return }
        window.setFrame(frame, display: true, animate: true)
    }

    func restoreWindowFrame(animated: Bool = true) {
        guard let window, let frame = frameBeforeFitting else { return }
        frameBeforeFitting = nil
        guard !window.styleMask.contains(.fullScreen) else { return }
        if animated {
            DispatchQueue.main.async { window.setFrame(frame, display: true, animate: true) }
        } else {
            window.setFrame(frame, display: true, animate: false)
        }
    }

    func pointerMoved() {
        pointerInside = true
        revealControls()
    }

    func pointerLeft() {
        // Moving onto the toolbar leaves the SwiftUI content but not the
        // window; treat that as still hovering.
        if isPointerOverToolbar {
            revealControls()
            return
        }
        pointerInside = false
        scheduleHide(after: .milliseconds(400))
    }

    /// Pointer within the window's top toolbar band.
    private var isPointerOverToolbar: Bool {
        guard let window else { return false }
        let mouse = NSEvent.mouseLocation
        let frame = window.frame
        return frame.contains(mouse) && mouse.y > frame.maxY - 64
    }

    func revealControls() {
        if !controlsVisible { controlsVisible = true }
        scheduleHide()
    }

    private func scheduleHide(after delay: Duration = .seconds(2.5)) {
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self, !self.isHoveringControls, !self.isPointerOverToolbar else { return }
            // Paused with the pointer over the video: keep controls up.
            guard self.isPlaying() || !self.pointerInside else { return }
            self.controlsVisible = false
            if self.pointerInside { NSCursor.setHiddenUntilMouseMoves(true) }
        }
    }

    private func setWindowButtonsVisible(_ visible: Bool) {
        guard let window, !window.styleMask.contains(.fullScreen) else { return }
        for kind: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(kind)?.animator().alphaValue = visible ? 1 : 0
        }
    }

    private func consumesKeyDown(_ event: NSEvent) -> Bool {
        guard event.window === window,
              event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
              !(window?.firstResponder is NSText) else { return false }
        revealControls()
        return onKey?(event) == true
    }
}
