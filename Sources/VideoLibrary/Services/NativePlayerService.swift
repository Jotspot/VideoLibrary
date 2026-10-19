import AVFoundation
import AVKit
import CoreMedia
import Observation

@Observable
@MainActor
final class NativePlayerService {
    let player = AVPlayer()
    private(set) var currentPlaybackTime: Double = 0
    private(set) var duration: Double = 0
    private(set) var isPlaying = false
    private(set) var isPictureInPictureActive = false
    /// The video's display size (for fitting the window to its shape).
    private(set) var videoSize: CGSize = .zero
    /// Called when the user clicks "return to app" in the PiP window.
    @ObservationIgnored var onPictureInPictureRestore: (() -> Void)?
    var volume: Float = 1 { didSet { player.volume = volume; if volume > 0 { isMuted = false } } }
    var isMuted = false { didSet { player.isMuted = isMuted } }
    var rate: Float = 1 {
        didSet {
            player.defaultRate = rate
            if isPlaying { player.rate = rate }
        }
    }

    /// Set when the full player hands playback to the miniplayer, so it
    /// doesn't stop the video as it goes away.
    @ObservationIgnored var isHandingOff = false
    @ObservationIgnored private var timeObserverToken: Any?
    @ObservationIgnored private var frameRate: Double = 30
    @ObservationIgnored private var stepTarget: Double?
    @ObservationIgnored private var statusObservation: NSKeyValueObservation?
    @ObservationIgnored private var pipObservation: NSKeyValueObservation?
    @ObservationIgnored private var pipController: AVPictureInPictureController?
    @ObservationIgnored private var loadedURL: URL?
    @ObservationIgnored private var sizeObservation: NSKeyValueObservation?
    @ObservationIgnored private var pipDelegate: PictureInPictureDelegate?
    /// A layer that appeared while PiP was running on an older one; it takes
    /// over once PiP ends.
    @ObservationIgnored private weak var pendingLayer: AVPlayerLayer?

    // deinit is nonisolated in Swift 6. AVPlayer releases its observers when it
    // is deallocated, so explicit removal is only needed when loading a new item.

    init() {
        statusObservation = player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] player, _ in
            let playing = player.timeControlStatus != .paused
            Task { @MainActor in self?.isPlaying = playing }
        }
    }

    var canUsePictureInPicture: Bool {
        AVPictureInPictureController.isPictureInPictureSupported()
    }

    func attach(playerLayer: AVPlayerLayer) {
        guard canUsePictureInPicture, pipController?.playerLayer !== playerLayer else { return }
        // Don't tear down a PiP window that's showing; switch layers after.
        if pipController?.isPictureInPictureActive == true {
            pendingLayer = playerLayer
            return
        }
        let controller = AVPictureInPictureController(playerLayer: playerLayer)
        let delegate = PictureInPictureDelegate(
            restore: { [weak self] in self?.onPictureInPictureRestore?() },
            didStop: { [weak self] in
                guard let self, let layer = self.pendingLayer else { return }
                self.pendingLayer = nil
                self.attach(playerLayer: layer)
            }
        )
        controller?.delegate = delegate
        pipDelegate = delegate
        pipObservation = controller?.observe(\.isPictureInPictureActive, options: [.new]) { [weak self] controller, _ in
            let active = controller.isPictureInPictureActive
            Task { @MainActor in self?.isPictureInPictureActive = active }
        }
        pipController = controller
    }

    func togglePictureInPicture() {
        guard let pipController else { return }
        if pipController.isPictureInPictureActive {
            pipController.stopPictureInPicture()
        } else {
            pipController.startPictureInPicture()
        }
    }

    func load(url: URL, startAt seconds: TimeInterval = 0) {
        guard loadedURL != url else { return }

        player.pause()
        let item = AVPlayerItem(url: url)
        player.replaceCurrentItem(with: item)
        loadFrameRate(for: item)
        stepTarget = nil
        videoSize = .zero
        sizeObservation = item.observe(\.presentationSize, options: [.new]) { [weak self] item, _ in
            let size = item.presentationSize
            Task { @MainActor in if size.width > 0, size.height > 0 { self?.videoSize = size } }
        }
        loadedURL = url
        currentPlaybackTime = seconds
        duration = 0

        if let token = timeObserverToken {
            player.removeTimeObserver(token)
        }
        timeObserverToken = player.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 10),
            queue: .main
        ) { [weak self] time in
            let seconds = time.seconds
            guard seconds.isFinite else { return }
            MainActor.assumeIsolated {
                guard let self else { return }
                self.currentPlaybackTime = seconds
                if let itemDuration = self.player.currentItem?.duration.seconds,
                   itemDuration.isFinite, itemDuration != self.duration {
                    self.duration = itemDuration
                }
            }
        }

        if seconds > 0 {
            player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600))
        }
    }

    private func loadFrameRate(for item: AVPlayerItem) {
        frameRate = 30
        Task { [weak self] in
            guard let track = try? await item.asset.loadTracks(withMediaType: .video).first,
                  let fps = try? await track.load(.nominalFrameRate), fps > 0 else { return }
            self?.frameRate = Double(fps)
        }
    }

    func play() {
        stepTarget = nil
        // Restart from the top when play is pressed at the very end.
        if duration > 0, currentPlaybackTime >= duration - 0.5 {
            seek(to: 0)
        }
        player.playImmediately(atRate: rate)
    }

    func pause() {
        player.pause()
    }

    func togglePlayPause() {
        isPlaying ? pause() : play()
    }

    func seek(to seconds: TimeInterval) {
        stepTarget = nil
        var target = max(0, seconds)
        if duration > 0 { target = min(target, max(0, duration - 0.5)) }
        currentPlaybackTime = target
        player.seek(
            to: CMTime(seconds: target, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
    }

    func seek(by delta: TimeInterval) {
        let current = player.currentTime().seconds
        guard current.isFinite else { return }
        seek(to: current + delta)
    }

    /// Pauses and moves exactly `frames` frames forward/back. Uses exact
    /// seeks of one frame's duration from the last step's target, so quick
    /// repeated presses add up precisely (AVPlayerItem.step can jump by more
    /// than a frame).
    func step(frames: Int) {
        guard player.currentItem != nil else { return }
        pause()
        let base = stepTarget ?? player.currentTime().seconds
        guard base.isFinite else { return }
        var target = max(0, base + Double(frames) / frameRate)
        if duration > 0 { target = min(target, duration) }
        stepTarget = target
        currentPlaybackTime = target
        player.seek(
            to: CMTime(seconds: target, preferredTimescale: 600_000),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
    }

    func adjustVolume(by delta: Float) {
        volume = min(1, max(0, volume + delta))
    }

    func toggleMute() {
        isMuted.toggle()
    }

    /// Releases the current item (and its decoder) when the player closes.
    func stop() {
        player.pause()
        if pipController?.isPictureInPictureActive == true {
            pipController?.stopPictureInPicture()
        }
        if let token = timeObserverToken {
            player.removeTimeObserver(token)
            timeObserverToken = nil
        }
        player.replaceCurrentItem(with: nil)
        sizeObservation = nil
        videoSize = .zero
        loadedURL = nil
        duration = 0
    }
}

/// Forwards PiP "return to app" and "stopped" events to the service.
private final class PictureInPictureDelegate: NSObject, AVPictureInPictureControllerDelegate {
    let restore: @MainActor () -> Void
    let didStop: @MainActor () -> Void

    init(restore: @escaping @MainActor () -> Void, didStop: @escaping @MainActor () -> Void) {
        self.restore = restore
        self.didStop = didStop
    }

    func pictureInPictureController(
        _ controller: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
    ) {
        Task { @MainActor in
            restore()
            completionHandler(true)
        }
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
        Task { @MainActor in didStop() }
    }
}
