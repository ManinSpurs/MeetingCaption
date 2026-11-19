// swift-tools-version: 6.0
import PackageDescription

// MeetingCaption builds only its own core and app. The legacy MacCaption and MPVBridge
// targets stay in the tree as reference but are not part of this manifest, so no playback
// library or bundled framework is required to build or launch the meeting app.
let package = Package(
    name: "MeetingCaption",
    platforms: [.macOS("26.0")],
    products: [.executable(name: "MeetingCaption", targets: ["MeetingCaption"])],
    dependencies: [
        // Auto-update (EdDSA-signed appcast served from GitHub Releases).
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.1")
    ],
    targets: [
        .target(name: "CaptionCore"),
        .target(name: "AudioCaptureBridge"),
        .executableTarget(
            name: "MeetingCaption",
            dependencies: [
                "CaptionCore",
                "AudioCaptureBridge",
                .product(name: "Sparkle", package: "Sparkle")
            ],
            // build-meeting.sh embeds Sparkle.framework in Contents/Frameworks.
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        .testTarget(name: "CaptionCoreTests", dependencies: ["CaptionCore"]),
        .target(name: "AudioCaptureTestSupport", path: "Tests/AudioCaptureTestSupport"),
        .testTarget(name: "MeetingCaptionTests", dependencies: ["MeetingCaption", "CaptionCore", "AudioCaptureBridge", "AudioCaptureTestSupport"])
    ],
    swiftLanguageModes: [.v5]
)

