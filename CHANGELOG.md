# Changelog

VideoLibrary versions are `YY.MM.N`: the year, the month, and the release number within that month.

## 26.10.4 — 2026-10-29

### New
- **Delete several videos at once.** Click **Select** above the library (or ⌘-click a video) to pick videos; ⇧-click picks everything between two videos. Then delete them together with **Delete** (⌘⌫). **Select All** picks every video shown.
- **Delete a whole channel.** Right-click an uploader in the sidebar, or any of their videos, and choose **Delete All Videos by…**. While you're viewing one uploader, a **Delete Channel…** button does the same.

### Improved
- **Uploader folders are cleaned up.** When deleting leaves an uploader's folder empty, the folder is deleted from Finder too.
- **Your sort order is remembered.** The library keeps the sort you picked (and its direction) after you quit.

### Fixed
- **The Library button is easy to reach in full screen.** The full-screen player's top controls sat where the menu bar slides down, so it covered them when you moved the pointer up. They're now just below it.
- **Library takes you out of full screen.** Going back to the library from a full-screen video now exits full screen, even if the app was full screen before you opened the video. Turn this off in Settings › General › **Going back to the library exits full screen**.

## 26.10.3 — 2026-10-24

### New
- **SABR fallback for YouTube.** Some accounts and networks only get YouTube's newer SABR streams, which left downloads stuck at 360p. VideoLibrary now spots this as soon as yt-dlp picks a format, before anything downloads, and tries other YouTube clients (Safari's, then the TV app's) that often still get HD. Signed-in YouTube downloads now start with Safari's client, so they usually get HD on the first try; if another client works better, it's remembered for a few hours.
- **Optional SABR add-on.** If those don't get HD either, the downloads panel offers an experimental SABR add-on (a preview build of yt-dlp) and retries with it. You can also install it from Settings › Tools › Experimental, after several confirmations. It's checked against its published checksum, kept in Application Support, and never replaces your Homebrew yt-dlp.
- **Disk image download.** VideoLibrary now comes as **VideoLibrary.dmg**, with a window that shows where to drag the app and how to open it the first time. The zip is still available.
- **User manual.** A full manual is on the website, linked from Settings › Help and the Help menu (⌘?), along with What's New and Report a Problem.

### Improved
- **Faster "Contacting YouTube".** The app now asks yt-dlp only for the details it uses (about 4 KB instead of up to 12 MB per video), and after YouTube's bot check turns away a signed-out download it uses your sign-in straight away for the next 30 minutes.
- **Accurate download sizes for streamed videos.** The size no longer keeps growing during HLS downloads (it could show over 1 GB for a 200 MB video), and yt-dlp's up-front guess for these streams (often two or three times too big) isn't shown; the size appears once the download's own estimate has settled.
- **Clean progress between attempts.** When a download retries or switches to another YouTube client, the progress bar, size and speed start fresh instead of showing the last attempt's numbers.
- Settings › Tools: **Update All** is now above the Experimental section.

### Fixed
- **Saved sign-ins could be lost after an update.** If macOS's Keychain prompt was denied or closed after updating, the app replaced its encryption key, making saved sign-ins unreadable. It now waits and asks again instead.
- **Folders inside an added music folder now become playlists too.** Adding a folder of album or playlist folders used to give one big playlist; now each folder with songs is its own playlist under **Folder Playlists**, and you can collapse them.

## 26.10.2 — 2026-10-23

### New
- **Drag videos out of the library.** Drag any downloaded video's card to the desktop or a Finder folder to get a copy of the file. The library's own file is never moved.
- **Full Share menu.** Share now opens the standard macOS share menu (Messages, Mail, AirDrop, Notes and any other share extensions) instead of only AirDrop. It's in the video's right-click menu, the player's toolbar and the full-screen player.
- **Save to Downloads.** A new right-click option copies the video into your Downloads folder (without overwriting anything already there) and shows it in Finder.
- **Download straight to your Downloads folder.** Add Video's "Save to" menu has a new **Downloads Folder** choice: the video is saved to ~/Downloads as "Title.mp4" and isn't added to any library.

## 26.10.1 — 2026-10-19

The first public release.

### Highlights
- Download from YouTube, Nebula and the 1,000+ other sites yt-dlp supports, in the quality you choose, with plain-language errors and one-click fixes.
- Several libraries, including external drives, plus importing your own video files.
- An edge-to-edge player with hover controls, Picture in Picture, a miniplayer, frame stepping and resume.
- YouTube's auto-captions shown word by word, fully restyleable.
- Suggestions from your real YouTube feed, with Hide Shorts.
- Watch your library on your phone over Wi-Fi.
- An optional music player with playlists, Liked Songs, a queue and a floating Liquid Glass bar.
- Sign-ins and cookies encrypted at rest with a Keychain key.

### Fixed
- The playing song's title in the music list was unreadable when its row was selected.
