// swift-tools-version:6.0
// SPDX-License-Identifier: Apache-2.0
import PackageDescription

let package = Package(
    name: "FernwickOpen",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "FernwickCore", targets: ["FernwickCore"]),
        .executable(name: "fernwick-hello", targets: ["FernwickHello"]),
    ],
    targets: [
        .target(name: "FernwickCore"),
        .executableTarget(name: "FernwickHello", dependencies: ["FernwickCore"]),
        .testTarget(name: "FernwickCoreTests", dependencies: ["FernwickCore"]),
    ]
)
