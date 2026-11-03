// swift-tools-version:5.9
// SPDX-License-Identifier: GPL-3.0-or-later

import PackageDescription

let package = Package(
    name: "GlieseCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "GlieseCore", targets: ["GlieseCore"])
    ],
    targets: [
        .target(name: "GlieseCore", path: "Sources/GlieseCore"),
        .testTarget(name: "GlieseCoreTests", dependencies: ["GlieseCore"], path: "Tests/GlieseCoreTests")
    ]
)
