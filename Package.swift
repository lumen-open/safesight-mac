// swift-tools-version:6.0
// SPDX-License-Identifier: Apache-2.0
import Foundation
import PackageDescription

// Lab builds: `SAFESIGHTMAC_LAB=1 swift build` (the detector's own `KESTREL_LAB=1` works too).
// Only lab builds contain the stand-in target, its hook and any test switch. Release builds
// (no variable) contain none of them.
let env = ProcessInfo.processInfo.environment
let lab = env["SAFESIGHTMAC_LAB"] == "1" || env["KESTREL_LAB"] == "1"
let labSettings: [SwiftSetting] = lab ? [.define("SAFESIGHTMAC_LAB"), .define("KESTREL_LAB")] : []
// The vendored detector keeps Swift 5 language mode, as it was built and tested.
let detectorSettings: [SwiftSetting] = labSettings + [.swiftLanguageMode(.v5)]

var targets: [Target] = [
    .target(name: "SafeSightMacCore", swiftSettings: labSettings),
    .executableTarget(name: "SafeSightMacHello", dependencies: ["SafeSightMacCore"]),
    .testTarget(name: "SafeSightMacCoreTests", dependencies: ["SafeSightMacCore"], swiftSettings: labSettings),

    // The detector (vendored kestrel lab build).
    .target(name: "Preprocess", swiftSettings: [.swiftLanguageMode(.v5)]),
    .target(name: "RegionFinder", dependencies: ["Preprocess"], swiftSettings: [.swiftLanguageMode(.v5)]),
    .target(name: "DetectorCore", dependencies: ["Preprocess", "RegionFinder"], swiftSettings: detectorSettings),
    .testTarget(name: "PreprocessTests", dependencies: ["Preprocess"], swiftSettings: [.swiftLanguageMode(.v5)]),
    .testTarget(name: "DetectorCoreTests", dependencies: ["DetectorCore", "RegionFinder"] + (lab ? ["LabStandIn"] : []),
                swiftSettings: detectorSettings),

    // The watcher. SafeSightMacWatcher is the pure cover layer (no AppKit, no capture); SafeSightMacCapture holds
    // the ScreenCaptureKit streams. Neither has any networking code.
    .target(name: "SafeSightMacWatcher", dependencies: ["SafeSightMacCore", "DetectorCore", "Preprocess", "RegionFinder"],
            swiftSettings: detectorSettings),
    .target(name: "SafeSightMacCapture", dependencies: ["SafeSightMacWatcher", "Preprocess"], swiftSettings: detectorSettings),
    .target(name: "SafeSightMacCover", dependencies: ["SafeSightMacWatcher"], swiftSettings: detectorSettings),
    // The cover-only menu-bar app.
    .executableTarget(name: "SafeSightMacApp", dependencies: ["SafeSightMacCore", "SafeSightMacWatcher", "SafeSightMacCapture", "SafeSightMacCover", "DetectorCore"],
                      swiftSettings: detectorSettings),
    // The lab harness: frames from files or synthetic scenes through the pipeline, never the screen.
    .executableTarget(name: "SafeSightMacHarness", dependencies: ["SafeSightMacWatcher", "DetectorCore", "Preprocess"] + (lab ? ["LabStandIn"] : []),
                      swiftSettings: detectorSettings),
    .testTarget(name: "SafeSightMacWatcherTests", dependencies: ["SafeSightMacWatcher", "DetectorCore", "Preprocess", "RegionFinder"] + (lab ? ["LabStandIn"] : []),
                swiftSettings: detectorSettings),
]
if lab {
    targets.append(.target(name: "LabStandIn", dependencies: ["DetectorCore", "Preprocess"], swiftSettings: detectorSettings))
}

let package = Package(
    name: "SafeSightMac",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "SafeSightMacCore", targets: ["SafeSightMacCore"]),
        .library(name: "DetectorCore", targets: ["DetectorCore"]),
        .executable(name: "safesightmac-hello", targets: ["SafeSightMacHello"]),
        .executable(name: "safesight-mac", targets: ["SafeSightMacApp"]),
        .executable(name: "safesightmac-harness", targets: ["SafeSightMacHarness"]),
    ],
    targets: targets
)
