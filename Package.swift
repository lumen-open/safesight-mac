// swift-tools-version:6.0
// SPDX-License-Identifier: Apache-2.0
import Foundation
import PackageDescription

// Lab builds: `FERNWICK_LAB=1 swift build` (the detector's own `KESTREL_LAB=1` works too).
// Only lab builds contain the stand-in target, its hook and any test switch. Release builds
// (no variable) contain none of them.
let env = ProcessInfo.processInfo.environment
let lab = env["FERNWICK_LAB"] == "1" || env["KESTREL_LAB"] == "1"
let labSettings: [SwiftSetting] = lab ? [.define("FERNWICK_LAB"), .define("KESTREL_LAB")] : []
// The vendored detector keeps Swift 5 language mode, as it was built and tested.
let detectorSettings: [SwiftSetting] = labSettings + [.swiftLanguageMode(.v5)]

var targets: [Target] = [
    .target(name: "FernwickCore", swiftSettings: labSettings),
    .executableTarget(name: "FernwickHello", dependencies: ["FernwickCore"]),
    .testTarget(name: "FernwickCoreTests", dependencies: ["FernwickCore"], swiftSettings: labSettings),

    // The detector (vendored kestrel lab build).
    .target(name: "Preprocess", swiftSettings: [.swiftLanguageMode(.v5)]),
    .target(name: "RegionFinder", dependencies: ["Preprocess"], swiftSettings: [.swiftLanguageMode(.v5)]),
    .target(name: "DetectorCore", dependencies: ["Preprocess", "RegionFinder"], swiftSettings: detectorSettings),
    .testTarget(name: "PreprocessTests", dependencies: ["Preprocess"], swiftSettings: [.swiftLanguageMode(.v5)]),
    .testTarget(name: "DetectorCoreTests", dependencies: ["DetectorCore", "RegionFinder"] + (lab ? ["LabStandIn"] : []),
                swiftSettings: detectorSettings),

    // The watcher. FernwickWatcher is the pure cover layer (no AppKit, no capture); FernwickCapture holds
    // the ScreenCaptureKit streams. Neither has any networking code.
    .target(name: "FernwickWatcher", dependencies: ["FernwickCore", "DetectorCore", "Preprocess", "RegionFinder"],
            swiftSettings: detectorSettings),
    .target(name: "FernwickCapture", dependencies: ["FernwickWatcher", "Preprocess"], swiftSettings: detectorSettings),
    .target(name: "FernwickCover", dependencies: ["FernwickWatcher"], swiftSettings: detectorSettings),
    // The cover-only menu-bar app.
    .executableTarget(name: "FernwickApp", dependencies: ["FernwickCore", "FernwickWatcher", "FernwickCapture", "FernwickCover", "DetectorCore"],
                      swiftSettings: detectorSettings),
    .testTarget(name: "FernwickWatcherTests", dependencies: ["FernwickWatcher", "DetectorCore", "Preprocess", "RegionFinder"],
                swiftSettings: detectorSettings),
]
if lab {
    targets.append(.target(name: "LabStandIn", dependencies: ["DetectorCore", "Preprocess"], swiftSettings: detectorSettings))
}

let package = Package(
    name: "FernwickOpen",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "FernwickCore", targets: ["FernwickCore"]),
        .library(name: "DetectorCore", targets: ["DetectorCore"]),
        .executable(name: "fernwick-hello", targets: ["FernwickHello"]),
        .executable(name: "fernwick-open", targets: ["FernwickApp"]),
    ],
    targets: targets
)
