// swift-tools-version: 5.9
//
// XueniKit — the part of the iPhone app with logic worth testing, kept apart
// from the app the way desktop/src-tauri/transcode is kept apart from the
// Tauri shell: plain Foundation, no UI, no SwiftData, so `swift test` runs on
// Linux CI as well as on a Mac. The app in ../Xueni is a SwiftUI shell around
// this package.

import PackageDescription

let package = Package(
    name: "XueniKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "XueniKit", targets: ["XueniKit"]),
    ],
    targets: [
        .target(
            name: "XueniKit",
            path: "Sources/XueniKit"
        ),
        .testTarget(
            name: "XueniKitTests",
            dependencies: ["XueniKit"],
            path: "Tests/XueniKitTests",
            resources: [.copy("Resources")]
        ),
    ],
    swiftLanguageVersions: [.v5]
)
