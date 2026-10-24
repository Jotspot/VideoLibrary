#!/usr/bin/env bash
set -euo pipefail

APP_NAME="VideoLibrary"
BUNDLE="$APP_NAME.app"
CONTENTS="$BUNDLE/Contents"
BUILD_DIR=".build"

SDK="$(xcrun --sdk macosx --show-sdk-path)"
TARGET="arm64-apple-macosx26.0"

echo "==> Compiling $APP_NAME..."
mkdir -p "$BUILD_DIR"

GCD_OBJ_DIR="$BUILD_DIR/gcdwebserver"
mkdir -p "$GCD_OBJ_DIR"

GCD_INCLUDES=(
  -I "Vendor/GCDWebServer/Core"
  -I "Vendor/GCDWebServer/Requests"
  -I "Vendor/GCDWebServer/Responses"
)

GCD_SOURCES=(
  Vendor/GCDWebServer/Core/GCDWebServer.m
  Vendor/GCDWebServer/Core/GCDWebServerConnection.m
  Vendor/GCDWebServer/Core/GCDWebServerFunctions.m
  Vendor/GCDWebServer/Core/GCDWebServerRequest.m
  Vendor/GCDWebServer/Core/GCDWebServerResponse.m
  Vendor/GCDWebServer/Requests/GCDWebServerDataRequest.m
  Vendor/GCDWebServer/Requests/GCDWebServerFileRequest.m
  Vendor/GCDWebServer/Requests/GCDWebServerMultiPartFormRequest.m
  Vendor/GCDWebServer/Requests/GCDWebServerURLEncodedFormRequest.m
  Vendor/GCDWebServer/Responses/GCDWebServerDataResponse.m
  Vendor/GCDWebServer/Responses/GCDWebServerErrorResponse.m
  Vendor/GCDWebServer/Responses/GCDWebServerFileResponse.m
  Vendor/GCDWebServer/Responses/GCDWebServerStreamedResponse.m
)

GCD_OBJECTS=()
for source in "${GCD_SOURCES[@]}"; do
  object="$GCD_OBJ_DIR/$(basename "${source%.m}").o"
  clang \
    -target "$TARGET" \
    -isysroot "$SDK" \
    -fobjc-arc \
    -fblocks \
    "${GCD_INCLUDES[@]}" \
    -Wno-deprecated-declarations \
    -Wno-shorten-64-to-32 \
    -c "$source" \
    -o "$object"
  GCD_OBJECTS+=("$object")
done

# Compile all Swift sources directly — bypasses SPM manifest linking entirely.
# The CLT's libPackageDescription.dylib has a SwiftVersion/SwiftLanguageMode ABI
# mismatch that breaks "swift build" on this toolchain; swiftc is unaffected.
swiftc \
  -target "$TARGET" \
  -sdk "$SDK" \
  -module-name "$APP_NAME" \
  -import-objc-header Sources/VideoLibrary/VideoLibrary-Bridging-Header.h \
  -Xcc -IVendor/GCDWebServer/Core \
  -Xcc -IVendor/GCDWebServer/Requests \
  -Xcc -IVendor/GCDWebServer/Responses \
  -parse-as-library \
  -O \
  Sources/VideoLibrary/Models/VideoItem.swift \
  Sources/VideoLibrary/Models/DownloadTask.swift \
  Sources/VideoLibrary/Models/SubtitleCue.swift \
  Sources/VideoLibrary/Models/SuggestedVideo.swift \
  Sources/VideoLibrary/Models/DownloadFailure.swift \
  Sources/VideoLibrary/Models/MusicModels.swift \
  Sources/VideoLibrary/Services/LibraryStore.swift \
  Sources/VideoLibrary/Services/VideoImporter.swift \
  Sources/VideoLibrary/Services/SABRAddon.swift \
  Sources/VideoLibrary/Services/DebugLog.swift \
  Sources/VideoLibrary/Services/KeychainStore.swift \
  Sources/VideoLibrary/Services/SecureStore.swift \
  Sources/VideoLibrary/Services/SecurityCheck.swift \
  Sources/VideoLibrary/Services/BrowserCookieImporter.swift \
  Sources/VideoLibrary/Services/YouTubeFeedService.swift \
  Sources/VideoLibrary/Services/NebulaAccount.swift \
  Sources/VideoLibrary/Services/MusicScanner.swift \
  Sources/VideoLibrary/Services/MusicLibraryStore.swift \
  Sources/VideoLibrary/Services/MusicPlayerService.swift \
  Sources/VideoLibrary/Services/CookieCache.swift \
  Sources/VideoLibrary/Services/DownloadedFileLocator.swift \
  Sources/VideoLibrary/Services/YtDlpService.swift \
  Sources/VideoLibrary/Services/YouTubeOAuthService.swift \
  Sources/VideoLibrary/Services/YouTubeSuggestionsStore.swift \
  Sources/VideoLibrary/Services/LocalSharingServer.swift \
  Sources/VideoLibrary/Services/NativePlayerService.swift \
  Sources/VideoLibrary/Services/VideoSharingService.swift \
  Sources/VideoLibrary/Services/SubtitleParser.swift \
  Sources/VideoLibrary/Services/ToolsService.swift \
  Sources/VideoLibrary/Views/RootView.swift \
  Sources/VideoLibrary/Views/SidebarView.swift \
  Sources/VideoLibrary/Views/LibraryGridView.swift \
  Sources/VideoLibrary/Views/VideoCardView.swift \
  Sources/VideoLibrary/Views/AVKitPlayerView.swift \
  Sources/VideoLibrary/Views/CaptionStyle.swift \
  Sources/VideoLibrary/Views/PlayerView.swift \
  Sources/VideoLibrary/Views/MiniPlayerView.swift \
  Sources/VideoLibrary/Views/MusicView.swift \
  Sources/VideoLibrary/Views/NowPlayingBar.swift \
  Sources/VideoLibrary/Views/DownloadPanelView.swift \
  Sources/VideoLibrary/Views/AddVideoSheet.swift \
  Sources/VideoLibrary/Views/QRCodeView.swift \
  Sources/VideoLibrary/Views/LocalSharingPanelView.swift \
  Sources/VideoLibrary/Views/SuggestionsView.swift \
  Sources/VideoLibrary/Views/ToolbarContent.swift \
  Sources/VideoLibrary/Views/SettingsView.swift \
  Sources/VideoLibrary/Views/YouTubeSignInView.swift \
  Sources/VideoLibrary/Views/YouTubeSignInControls.swift \
  Sources/VideoLibrary/VideoLibraryApp.swift \
  "${GCD_OBJECTS[@]}" \
  -framework SwiftUI \
  -framework AVFoundation \
  -framework AVKit \
  -framework MediaPlayer \
  -framework WebKit \
  -framework CoreImage \
  -framework CryptoKit \
  -framework CoreServices \
  -framework IOKit \
  -framework Security \
  -framework SystemConfiguration \
  -lz \
  -lsqlite3 \
  -o "$BUILD_DIR/$APP_NAME"

echo "==> Assembling .app bundle..."
rm -rf "$BUNDLE"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"

cp "$BUILD_DIR/$APP_NAME" "$CONTENTS/MacOS/$APP_NAME"
chmod +x "$CONTENTS/MacOS/$APP_NAME"
cp "Info.plist" "$CONTENTS/"
if [[ -f "Sources/VideoLibrary/Resources/AppIcon.icns" ]]; then
  cp "Sources/VideoLibrary/Resources/AppIcon.icns" "$CONTENTS/Resources/"
else
  echo "   Note: Sources/VideoLibrary/Resources/AppIcon.icns not found; using default app icon."
fi

# yt-dlp, ffmpeg and Deno are not bundled — the app uses the system copies so
# they can be updated independently (brew upgrade yt-dlp ffmpeg deno).
for tool in yt-dlp ffmpeg deno; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "   Warning: $tool not found. Install with: brew install $tool"
  fi
done

echo ""
echo "✓  Built: $BUNDLE"
echo ""
echo "   open $BUNDLE"
