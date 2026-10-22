### Install

1. Download **VideoLibrary.zip** below and unzip it.
2. Move **VideoLibrary.app** to Applications.
3. The app isn't notarized, so the first time you open it macOS will block it. Open **System Settings › Privacy & Security**, scroll down and click **Open Anyway**. (Or run `xattr -dr com.apple.quarantine /Applications/VideoLibrary.app`.)
4. Install the download tools: `brew install yt-dlp ffmpeg deno` (Settings › Tools can do this for you).

Requires macOS 26 (Tahoe) or later on Apple silicon.
