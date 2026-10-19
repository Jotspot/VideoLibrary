// swift-tools-version: 6.0
import PackageDescription

// Note: No .platforms entry — the Swift 6.3.1 CLT defaults to arm64-apple-macosx26.0,
// giving full access to macOS 26 APIs without requiring the enum which is
// conditionally available only when the manifest itself targets macOS 26+.
// Swift 6 language mode is implicit for swift-tools-version 6.0.
let package = Package(
    name: "VideoLibrary",
    products: [
        .executable(name: "VideoLibrary", targets: ["VideoLibrary"])
    ],
    targets: [
        .executableTarget(
            name: "VideoLibrary",
            path: "Sources/VideoLibrary",
            exclude: ["Resources/AppIcon.icns"]
        ),
        .testTarget(
            name: "VideoLibraryTests",
            dependencies: ["VideoLibrary"],
            path: "Tests/VideoLibraryTests"
        )
    ]
)
