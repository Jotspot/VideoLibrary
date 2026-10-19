The first public release of **VideoLibrary**, a native macOS 26 app for downloading, organizing and watching videos offline, with an optional music player.

### Install

1. Download **VideoLibrary.zip** below and unzip it.
2. Move **VideoLibrary.app** to Applications.
3. The app isn't notarized, so the first time you open it macOS will block it. Open **System Settings › Privacy & Security**, scroll down and click **Open Anyway**. (Or run `xattr -dr com.apple.quarantine /Applications/VideoLibrary.app`.)
4. Install the download tools: `brew install yt-dlp ffmpeg deno` (Settings › Tools can do this for you).

Requires macOS 26 (Tahoe) or later on Apple silicon.

### Highlights

- Download from YouTube, Nebula and the 1,000+ other sites yt-dlp supports, in the quality you choose
- Plain-language download errors with one-click fixes
- Several libraries, including external drives, plus importing your own video files
- An edge-to-edge player with hover controls, Picture in Picture, a miniplayer, frame stepping and resume
- YouTube's auto-captions word by word, fully restyleable
- Suggestions from your real YouTube feed, with Hide Shorts
- Watch your library on your phone over Wi-Fi via a QR code
- An optional music player with playlists, Liked Songs, a queue and a floating Liquid Glass bar
- Sign-ins and cookies encrypted at rest with a Keychain key

See the [README](https://github.com/Jotspot/VideoLibrary#readme) for everything.
