import SwiftUI
import AVKit
import AppKit

// Bare video surface: an AVPlayerLayer with no built-in controls. PlayerView
// draws its own controls so captions and the transport bar share one layout
// (and never overlap), and so there is exactly one fullscreen mode.
struct AVKitPlayerView: NSViewRepresentable {
    let service: NativePlayerService

    func makeNSView(context: Context) -> PlayerLayerView {
        let view = PlayerLayerView()
        view.playerLayer.player = service.player
        view.playerLayer.videoGravity = .resizeAspect
        service.attach(playerLayer: view.playerLayer)
        return view
    }

    func updateNSView(_ view: PlayerLayerView, context: Context) {
        if view.playerLayer.player !== service.player {
            view.playerLayer.player = service.player
        }
    }

    final class PlayerLayerView: NSView {
        let playerLayer = AVPlayerLayer()

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            layer = playerLayer
            playerLayer.backgroundColor = NSColor.black.cgColor
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }
    }
}

/// Hands the hosting NSWindow to SwiftUI once the view is installed.
struct WindowAccessor: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> WindowReportingView {
        let view = WindowReportingView()
        view.onWindow = onWindow
        return view
    }

    func updateNSView(_ view: WindowReportingView, context: Context) {}

    final class WindowReportingView: NSView {
        var onWindow: ((NSWindow) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            // Defer out of the current layout pass before touching the window.
            DispatchQueue.main.async { [weak self] in
                self?.onWindow?(window)
            }
        }
    }
}
