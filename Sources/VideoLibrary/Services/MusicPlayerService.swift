import AppKit
import AVFoundation
import MediaPlayer
import Observation

/// Plays songs: a queue with shuffle and repeat, plus the keyboard's media
/// keys and Control Center's Now Playing via MediaPlayer.
@Observable
@MainActor
final class MusicPlayerService {
    enum RepeatMode: String, CaseIterable {
        case off, all, one
        var symbol: String { self == .one ? "repeat.1" : "repeat" }
        var next: RepeatMode {
            switch self {
            case .off: .all
            case .all: .one
            case .one: .off
            }
        }
    }

    /// The order songs play in (already shuffled when shuffle is on).
    private(set) var queue: [Song] = []
    private(set) var currentIndex: Int?
    private(set) var isPlaying = false
    private(set) var currentTime: Double = 0
    private(set) var duration: Double = 0
    var isShuffled = false {
        didSet { if oldValue != isShuffled { reshuffle() } }
    }
    var repeatMode: RepeatMode = .off
    var volume: Float = 1 {
        didSet { player.volume = volume }
    }

    var current: Song? { currentIndex.map { queue[$0] } }
    var upNext: [Song] {
        guard let currentIndex else { return queue }
        return Array(queue.dropFirst(currentIndex + 1))
    }

    /// Called when a song starts (for play counts).
    @ObservationIgnored var onTrackStarted: ((Song) -> Void)?
    /// Resolves cover art for Now Playing.
    @ObservationIgnored var artworkURL: ((Song) -> URL?)?

    @ObservationIgnored private let player = AVPlayer()
    @ObservationIgnored private var originalOrder: [Song] = []
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var endObserver: NSObjectProtocol?
    @ObservationIgnored private var statusObservation: NSKeyValueObservation?
    @ObservationIgnored private var remoteCommandsInstalled = false
    @ObservationIgnored private var lastSavedTime: Double = 0
    /// The music collection (library ID or "app") the queue came from.
    @ObservationIgnored var collectionKey: String?

    init() {
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 4), queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, time.seconds.isFinite else { return }
                self.currentTime = time.seconds
                // Remember the position every ~5 s for "pick up where you left off".
                if abs(time.seconds - self.lastSavedTime) >= 5 { self.saveSession() }
                if let d = self.player.currentItem?.duration.seconds, d.isFinite { self.duration = d }
            }
        }
        statusObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            let playing = player.timeControlStatus != .paused
            Task { @MainActor in
                self?.isPlaying = playing
                self?.updateNowPlaying()
            }
        }
    }

    // MARK: - Starting playback

    /// Plays `tracks` as the queue, starting at `start` (or the first one).
    func play(_ tracks: [Song], startingAt start: Song? = nil, shuffled: Bool? = nil) {
        guard !tracks.isEmpty else { return }
        installRemoteCommands()
        if let shuffled { isShuffled = shuffled }
        originalOrder = tracks
        if isShuffled {
            var rest = tracks.shuffled()
            if let start, let index = rest.firstIndex(of: start) {
                rest.remove(at: index)
                rest.insert(start, at: 0)
            }
            queue = rest
            load(index: 0)
        } else {
            queue = tracks
            load(index: start.flatMap { tracks.firstIndex(of: $0) } ?? 0)
        }
    }

    func playNext(_ tracks: [Song]) {
        guard currentIndex != nil else { return play(tracks) }
        queue.insert(contentsOf: tracks, at: (currentIndex ?? -1) + 1)
        originalOrder += tracks
    }

    func addToQueue(_ tracks: [Song]) {
        guard currentIndex != nil else { return play(tracks) }
        queue += tracks
        originalOrder += tracks
    }

    func jump(to track: Song) {
        guard let index = queue.firstIndex(of: track) else { return }
        load(index: index)
    }

    /// Reorders Up Next (offsets are relative to `upNext`).
    func moveInQueue(from offsets: IndexSet, to destination: Int) {
        guard let currentIndex else { return }
        var upcoming = Array(queue[(currentIndex + 1)...])
        upcoming.move(fromOffsets: offsets, toOffset: destination)
        queue = Array(queue[...currentIndex]) + upcoming
        saveSession()
    }

    /// Empties Up Next; the current song keeps playing.
    func clearQueue() {
        guard let currentIndex else { return }
        queue = [queue[currentIndex]]
        originalOrder = queue
        self.currentIndex = 0
        saveSession()
    }

    /// Keeps the queue's copies current after a song's info changes
    /// (e.g. liked), without interrupting playback.
    func refresh(_ songs: [Song]) {
        let byID = Dictionary(songs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        queue = queue.map { byID[$0.id] ?? $0 }
        originalOrder = originalOrder.map { byID[$0.id] ?? $0 }
    }

    func removeFromQueue(at offsets: IndexSet) {
        guard let currentIndex else { return }
        // Offsets are relative to `upNext`.
        let absolute = IndexSet(offsets.map { $0 + currentIndex + 1 })
        queue.remove(atOffsets: absolute)
    }

    // MARK: - Transport

    func togglePlayPause() {
        if isPlaying { pause() } else { resume() }
    }

    func resume() {
        if player.currentItem == nil, !queue.isEmpty { load(index: currentIndex ?? 0); return }
        player.play()
    }

    func pause() {
        player.pause()
        saveSession()
    }

    func next() {
        guard let currentIndex else { return }
        if currentIndex + 1 < queue.count {
            load(index: currentIndex + 1)
        } else if repeatMode == .all, !queue.isEmpty {
            if isShuffled { queue = originalOrder.shuffled() }
            load(index: 0)
        } else {
            stop()
        }
    }

    /// Restarts the song if it's more than 3 s in, otherwise goes back one.
    func previous() {
        guard let currentIndex else { return }
        if currentTime > 3 || currentIndex == 0 {
            seek(to: 0)
        } else {
            load(index: currentIndex - 1)
        }
    }

    func seek(to seconds: Double) {
        currentTime = seconds
        player.seek(to: CMTime(seconds: max(0, seconds), preferredTimescale: 600))
        updateNowPlaying()
    }

    func stop() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        currentIndex = nil
        currentTime = 0
        duration = 0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        MPNowPlayingInfoCenter.default().playbackState = .stopped
    }

    // MARK: - Session (restored on relaunch, paused)

    private struct Session: Codable {
        var collection: String
        var songIDs: [UUID]
        var originalIDs: [UUID]
        var index: Int
        var time: Double
        var shuffled: Bool
        var repeatMode: String
    }

    private static let sessionKey = "musicSession"

    private func saveSession() {
        guard let collectionKey, let currentIndex else { return }
        lastSavedTime = currentTime
        let session = Session(collection: collectionKey, songIDs: queue.map(\.id), originalIDs: originalOrder.map(\.id),
                              index: currentIndex, time: currentTime, shuffled: isShuffled, repeatMode: repeatMode.rawValue)
        UserDefaults.standard.set(try? JSONEncoder().encode(session), forKey: Self.sessionKey)
    }

    /// Puts back the last queue for this collection, paused at the same spot.
    func restoreSession(from songs: [Song], collection: String) {
        guard current == nil,
              let data = UserDefaults.standard.data(forKey: Self.sessionKey),
              let session = try? JSONDecoder().decode(Session.self, from: data),
              session.collection == collection else { return }
        let byID = Dictionary(songs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let restored = session.songIDs.compactMap { byID[$0] }
        guard restored.count == session.songIDs.count, restored.indices.contains(session.index) else { return }
        installRemoteCommands()
        queue = restored
        originalOrder = session.originalIDs.compactMap { byID[$0] }
        isShuffled = session.shuffled   // no reshuffle: nothing is loaded yet
        repeatMode = RepeatMode(rawValue: session.repeatMode) ?? .off
        load(index: session.index, autoplay: false)
        seek(to: session.time)
    }

    // MARK: - Internals

    private func load(index: Int, autoplay: Bool = true) {
        guard queue.indices.contains(index) else { return }
        currentIndex = index
        let track = queue[index]
        let item = AVPlayerItem(url: track.url)
        player.replaceCurrentItem(with: item)
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.trackEnded() }
        }
        currentTime = 0
        duration = track.duration
        if autoplay { player.play() }
        if autoplay { onTrackStarted?(track) }
        updateNowPlaying()
        saveSession()
    }

    private func trackEnded() {
        if repeatMode == .one {
            seek(to: 0)
            player.play()
        } else {
            next()
        }
    }

    private func reshuffle() {
        guard let current else { return }
        if isShuffled {
            originalOrder = queue
            var rest = queue.filter { $0 != current }.shuffled()
            rest.insert(current, at: 0)
            queue = rest
            currentIndex = 0
        } else {
            queue = originalOrder
            currentIndex = queue.firstIndex(of: current)
        }
    }

    private func installRemoteCommands() {
        guard !remoteCommandsInstalled else { return }
        remoteCommandsInstalled = true
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.resume() }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.pause() }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.togglePlayPause() }
            return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.next() }
            return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.previous() }
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            MainActor.assumeIsolated { self?.seek(to: event.positionTime) }
            return .success
        }
    }

    private func updateNowPlaying() {
        guard let track = current else { return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.title,
            MPMediaItemPropertyArtist: track.artist,
            MPMediaItemPropertyAlbumTitle: track.album,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0
        ]
        if let url = artworkURL?(track), let image = NSImage(contentsOf: url) {
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = isPlaying ? .playing : .paused
    }
}
