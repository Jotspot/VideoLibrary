import AppKit

@MainActor
enum VideoSharingService {
    static func sendViaAirDrop(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path),
              let service = NSSharingService(named: .sendViaAirDrop),
              service.canPerform(withItems: [url]) else {
            let alert = NSAlert()
            alert.messageText = "AirDrop is unavailable"
            alert.informativeText = "The video file could not be shared with AirDrop."
            alert.runModal()
            return
        }
        service.perform(withItems: [url])
    }
}
