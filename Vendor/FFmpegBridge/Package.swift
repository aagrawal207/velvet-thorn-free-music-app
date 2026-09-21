// swift-tools-version: 6.0
// SPDX-License-Identifier: LGPL-2.1-or-later

import PackageDescription

let package = Package(
    name: "FFmpegBridge",
    platforms: [.iOS(.v18)],
    products: [
        .library(name: "FFmpegBridge", targets: ["FFmpegBridge"])
    ],
    targets: [
        .binaryTarget(name: "FFmpegBridge", path: "FFmpegBridge.xcframework")
    ]
)
