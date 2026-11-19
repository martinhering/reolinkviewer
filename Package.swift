// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ReolinkViewer",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "Baichuan", targets: ["Baichuan"]),
        .executable(name: "bctool", targets: ["bctool"]),
        .executable(name: "ReolinkViewer", targets: ["ReolinkViewer"]),
    ],
    targets: [
        // Pure-Swift implementation of Reolink's Baichuan ("BC") protocol, TCP port 9000.
        .target(name: "Baichuan"),
        // CoreMedia glue shared by the app and bctool: sample buffers from the camera's
        // frames, and the MP4 segment recorder.
        .target(name: "CameraMedia", dependencies: ["Baichuan"]),
        // Command-line test harness: login, stream dump, PTZ, motion events, recording.
        .executableTarget(name: "bctool", dependencies: ["Baichuan", "CameraMedia"]),
        // SwiftUI viewer app.
        .executableTarget(name: "ReolinkViewer", dependencies: ["Baichuan", "CameraMedia"], exclude: ["Info.plist"]),
        .testTarget(name: "BaichuanTests", dependencies: ["Baichuan"]),
        .testTarget(name: "CameraMediaTests", dependencies: ["CameraMedia"]),
    ]
)
