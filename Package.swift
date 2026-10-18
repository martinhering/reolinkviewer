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
        // Command-line test harness: login, stream dump, PTZ.
        .executableTarget(name: "bctool", dependencies: ["Baichuan"]),
        // SwiftUI viewer app.
        .executableTarget(name: "ReolinkViewer", dependencies: ["Baichuan"], exclude: ["Info.plist"]),
        .testTarget(name: "BaichuanTests", dependencies: ["Baichuan"]),
    ]
)
