// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "FTX1Core",
    platforms: [
        .macOS(.v14),
        .iOS(.v17)
    ],
    products: [
        // The shared logic layer consumed by both the Mac (server/hub) app
        // and the iOS/iPadOS (client) apps.
        .library(
            name: "FTX1Core",
            targets: ["FTX1Core"]
        ),
    ],
    dependencies: [
        // No external deps yet. If a WebSocket client/server abstraction
        // beyond URLSessionWebSocketTask is needed later (e.g. for the Mac
        // server side), consider swift-nio-based options here.
    ],
    targets: [
        .target(
            name: "FTX1Core",
            dependencies: []
        ),
        .testTarget(
            name: "FTX1CoreTests",
            dependencies: ["FTX1Core"]
        ),
        // Mac hub app. SwiftUI-as-executable, run/debugged directly from
        // Xcode via this package — no separate .xcodeproj. macOS-only
        // (AppKit), so it's only ever built for the macOS destination.
        .executableTarget(
            name: "FTX1RemoteMac",
            dependencies: ["FTX1Core"],
            path: "Apps/Mac/FTX1RemoteMac"
        ),
    ]
)
