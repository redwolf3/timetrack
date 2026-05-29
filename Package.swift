// swift-tools-version: 5.9
import PackageDescription

// Three targets, one repo, versioned together (see DESIGN.md "How many repos").
//   TimeTrackKit  — pure-logic core. NO AppKit/SwiftUI/Combine. Builds & tests on
//                   Linux (cloud sessions). Idle is injected via IdleSource.
//   TimeTrackApp  — the macOS menu-bar app. AppKit/SwiftUI. macOS-only; cannot
//                   build in a Linux cloud session.
//   timetrack-cli — thin command-line client over TimeTrackKit. Mostly portable.
let package = Package(
    name: "timetrack",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "TimeTrackKit", targets: ["TimeTrackKit"]),
        .executable(name: "TimeTrackApp", targets: ["TimeTrackApp"]),
        .executable(name: "timetrack", targets: ["timetrack-cli"])
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "6.29.0"),
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.1.0"),
        .package(url: "https://github.com/soffes/HotKey.git", from: "0.2.1")
    ],
    targets: [
        .target(
            name: "TimeTrackKit",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "Yams", package: "Yams")
            ]),
        .executableTarget(
            name: "TimeTrackApp",
            dependencies: [
                "TimeTrackKit",
                .product(name: "HotKey", package: "HotKey")
            ]),
        .executableTarget(
            name: "timetrack-cli",
            dependencies: ["TimeTrackKit"]),
        .testTarget(
            name: "TimeTrackKitTests",
            dependencies: ["TimeTrackKit"])
    ]
)
