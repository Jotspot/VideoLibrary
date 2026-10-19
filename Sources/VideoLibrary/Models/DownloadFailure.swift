import Foundation

/// A download error translated into plain language: what happened, what to
/// do about it, and which one-click fix (if any) applies. The raw yt-dlp
/// output is kept in `details` for the "Show Details" disclosure.
struct DownloadFailure: Sendable, Equatable {
    enum Fix: Sendable, Equatable {
        case updateTools
        case installTools
        case chooseBrowserCookies
        case pickDifferentQuality
        case reconnectLibrary
        case none
    }

    var title: String
    var explanation: String
    var fix: Fix = .none
    var canRetry = true
    var details: String = ""
    /// YouTube refused without a sign-in (bot check, age, members, private).
    /// Only these are retried with the sign-in; rate limits and 403s aren't,
    /// since signed-in downloads can be limited to 360p.
    var needsSignIn = false

    /// The same failure worded for another site (e.g. Nebula): YouTube
    /// wording becomes that site's name, and sign-in fixes point at its
    /// section in Settings › Downloads.
    func forSite(_ name: String) -> DownloadFailure {
        guard name != "YouTube" else { return self }
        var copy = self
        copy.title = title.replacingOccurrences(of: "YouTube", with: name)
        copy.explanation = explanation
            .replacingOccurrences(of: "is asking to confirm you're not a bot", with: "needs you to be signed in")
            .replacingOccurrences(of: "choose the browser you're signed in to YouTube with", with: "connect your \(name) account")
            .replacingOccurrences(of: "YouTube", with: name)
        return copy
    }

    static func from(_ error: Error) -> DownloadFailure {
        switch error {
        case YtDlpError.binaryNotFound:
            return DownloadFailure(
                title: "yt-dlp isn't installed",
                explanation: "VideoLibrary uses the free yt-dlp tool to download videos. Install it from Settings › Tools with one click.",
                fix: .installTools, canRetry: false
            )
        case YtDlpError.ffmpegNotFound:
            return DownloadFailure(
                title: "ffmpeg isn't installed",
                explanation: "ffmpeg joins the video and audio into one file. Install it from Settings › Tools with one click.",
                fix: .installTools, canRetry: false
            )
        case YtDlpError.outputDirectoryUnavailable(let path):
            return DownloadFailure(
                title: "Can't save to this library",
                explanation: "The library folder isn't available or can't be written to. If it's on an external drive, connect the drive and try again.",
                fix: .reconnectLibrary, details: path
            )
        case YtDlpError.cookieCacheUnavailable(let path):
            return DownloadFailure(
                title: "Couldn't save YouTube cookies",
                explanation: "The cookie file couldn't be created. Turn off “Remember YouTube Cookies” in Settings › Downloads, or check disk permissions.",
                fix: .chooseBrowserCookies, details: path
            )
        case YtDlpError.youtubeAuthenticationRequired:
            return DownloadFailure(
                title: "YouTube wants you to sign in",
                explanation: "YouTube is asking to confirm you're not a bot. In Settings › Downloads, choose the browser you're signed in to YouTube with, then retry.",
                fix: .chooseBrowserCookies, needsSignIn: true
            )
        case YtDlpError.invalidOutput:
            return DownloadFailure(
                title: "Download finished, but no video file was found",
                explanation: "yt-dlp exited without producing a playable video. This is often fixed by updating the download tools.",
                fix: .updateTools
            )
        case YtDlpError.nonZeroExit(let code, let output):
            var failure = fromOutput(output)
            failure.details = "yt-dlp exited with code \(code).\n\n\(output.trimmingCharacters(in: .whitespacesAndNewlines))"
            return failure
        default:
            return DownloadFailure(
                title: "Download failed",
                explanation: error.localizedDescription,
                details: String(describing: error)
            )
        }
    }

    /// Matches yt-dlp's error text against known causes.
    static func fromOutput(_ output: String) -> DownloadFailure {
        // Judge by the fatal ERROR lines when there are any; warnings (like a
        // rate-limited caption fetch) shouldn't decide what went wrong.
        let errorLines = output.split(separator: "\n").filter { $0.hasPrefix("ERROR:") }
        let text = (errorLines.isEmpty ? output : errorLines.joined(separator: "\n")).lowercased()
        func has(_ needles: String...) -> Bool { needles.contains { text.contains($0.lowercased()) } }

        if has("sign in to confirm you’re not a bot", "sign in to confirm you're not a bot", "not a bot") {
            return DownloadFailure(
                title: "YouTube wants you to sign in",
                explanation: "YouTube is asking to confirm you're not a bot. In Settings › Downloads, choose the browser you're signed in to YouTube with, then retry.",
                fix: .chooseBrowserCookies, needsSignIn: true
            )
        }
        if has("confirm your age", "age-restricted", "inappropriate for some users") {
            return DownloadFailure(
                title: "This video is age-restricted",
                explanation: "YouTube only shows it to signed-in adults. Choose the browser you're signed in with in Settings › Downloads, then retry.",
                fix: .chooseBrowserCookies, needsSignIn: true
            )
        }
        if has("members-only", "join this channel", "available to this channel's members") {
            return DownloadFailure(
                title: "Members-only video",
                explanation: "This video is only for channel members. If you're a member, choose the browser you're signed in with in Settings › Downloads.",
                fix: .chooseBrowserCookies, needsSignIn: true
            )
        }
        if has("private video") {
            return DownloadFailure(
                title: "This video is private",
                explanation: "The uploader has made it private, so it can't be downloaded unless your signed-in account has access.",
                fix: .chooseBrowserCookies, canRetry: false, needsSignIn: true
            )
        }
        if has("video unavailable", "has been removed", "no longer available", "account associated with this video has been terminated") {
            return DownloadFailure(
                title: "Video unavailable",
                explanation: "YouTube says this video doesn't exist anymore, or isn't available in your country.",
                canRetry: false
            )
        }
        if has("premieres in", "live event will begin", "this live event") {
            return DownloadFailure(
                title: "Not out yet",
                explanation: "This is a premiere or live stream that hasn't started. Try again once it has finished airing."
            )
        }
        if has("http error 429", "too many requests") {
            return DownloadFailure(
                title: "YouTube is rate-limiting downloads",
                explanation: "Too many requests came from this Mac in a short time. Wait a few minutes and retry. Choosing your browser's cookies in Settings › Downloads also helps.",
                fix: .chooseBrowserCookies
            )
        }
        if has("requested format is not available", "no video formats found") {
            return DownloadFailure(
                title: "No compatible video format",
                explanation: "This video isn't offered in an H.264 MP4 format at the selected resolution. Try “Best Available” resolution, or update the download tools.",
                fix: .pickDifferentQuality
            )
        }
        if has("unsupported url") {
            return DownloadFailure(
                title: "That link isn't supported",
                explanation: "Paste a link straight to a video or playlist page (for example a youtube.com/watch link).",
                canRetry: false
            )
        }
        if has("no space left on device") {
            return DownloadFailure(
                title: "The disk is full",
                explanation: "There isn't enough free space in the library folder. Free up space or download to another library."
            )
        }
        if has("nsig extraction failed", "signature extraction failed", "http error 403", "precondition check failed",
               "unable to extract", "some formats may be missing", "please report this issue", "update to the latest version",
               "no supported javascript runtime", "js runtime") {
            return DownloadFailure(
                title: "The download tools need an update",
                explanation: "YouTube changes often and yt-dlp has to keep up. Update the tools with one click, then retry.",
                fix: .updateTools
            )
        }
        if has("unable to download webpage", "getaddrinfo", "nodename nor servname", "timed out", "network is unreachable",
               "connection reset", "temporary failure in name resolution", "urlopen error") {
            return DownloadFailure(
                title: "Couldn't reach the website",
                explanation: "Check your internet connection (and VPN, if you use one), then retry."
            )
        }

        let firstError = output
            .split(separator: "\n")
            .first { $0.hasPrefix("ERROR:") }
            .map { $0.dropFirst("ERROR:".count).trimmingCharacters(in: .whitespaces) }
        return DownloadFailure(
            title: "Download failed",
            explanation: (firstError.map { "yt-dlp reported: \($0)" } ?? "yt-dlp stopped with an unexpected error.")
                + " Updating the download tools fixes most problems like this.",
            fix: .updateTools
        )
    }
}
