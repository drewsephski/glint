// swift-tools-version: 6.2
import PackageDescription

let core: [SwiftSetting] = [.swiftLanguageMode(.v6)]
// Media/app layers talk to AVFoundation/ScreenCaptureKit callback APIs that are not yet fully Sendable-annotated.
let media: [SwiftSetting] = [.swiftLanguageMode(.v5)]

let package = Package(
    name: "Glint",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "glint", targets: ["glint"]),
        .executable(name: "GlintApp", targets: ["GlintApp"]),
        .library(name: "GlintCore", targets: ["GlintCore"]),
        .library(name: "GlintAgent", targets: ["GlintAgent"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
    ],
    targets: [
        // Pure Swift: project document, operations engine, history, proposals, approvals, timeline maths,
        // motion (springs, cursor smoothing, camera path) and planners. No AppKit/AVFoundation.
        .target(name: "GlintCore", swiftSettings: core),
        // ScreenCaptureKit recording, input/cursor tracking.
        .target(name: "GlintCapture", dependencies: ["GlintCore"], swiftSettings: media),
        // Core Image/Metal compositor, AVFoundation composition, preview + export, frames, GIF.
        .target(name: "GlintRender", dependencies: ["GlintCore"], swiftSettings: media),
        // Transcription, audio analysis, render inspection / quality metrics.
        .target(name: "GlintAnalysis", dependencies: ["GlintCore", "GlintRender"], swiftSettings: media),
        // The shared service layer used by the UI, the CLI and the MCP server (tool registry, approvals).
        .target(name: "GlintAgent", dependencies: ["GlintCore", "GlintCapture", "GlintRender", "GlintAnalysis"], swiftSettings: media),
        .executableTarget(
            name: "glint",
            dependencies: ["GlintAgent", .product(name: "ArgumentParser", package: "swift-argument-parser")],
            swiftSettings: media
        ),
        .executableTarget(name: "GlintApp", dependencies: ["GlintAgent"], swiftSettings: media),
        .testTarget(name: "GlintCoreTests", dependencies: ["GlintCore"], swiftSettings: core),
        .testTarget(name: "GlintMediaTests", dependencies: ["GlintAgent"], swiftSettings: media),
        .testTarget(name: "GlintAgentTests", dependencies: ["GlintAgent"], swiftSettings: media),
        .testTarget(name: "GlintAppTests", dependencies: ["GlintApp"], swiftSettings: media),
    ]
)
