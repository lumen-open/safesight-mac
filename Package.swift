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

// The Testing edition, for volunteer helpers (docs/TESTING-EDITION.md):
// `SAFESIGHTMAC_TESTING=1 swift build -c release --scratch-path .build-testing`. It has no lock and nothing that
// could add one: no keeper check, no installer, no login item, nothing that asks for an administrator. The flag is
// independent of the lab flag: a lab Testing build (both set) adds the stand-in, for the harness only.
let testing = env["SAFESIGHTMAC_TESTING"] == "1"
let editionSettings: [SwiftSetting] = testing ? [.define("SAFESIGHTMAC_TESTING")] : []
let coreSettings: [SwiftSetting] = labSettings + editionSettings
let appSettings: [SwiftSetting] = detectorSettings + editionSettings

var targets: [Target] = [
    .target(name: "SafeSightMacCore", swiftSettings: coreSettings),
    .executableTarget(name: "SafeSightMacHello", dependencies: ["SafeSightMacCore"]),
    .testTarget(name: "SafeSightMacCoreTests", dependencies: ["SafeSightMacCore"], swiftSettings: coreSettings),

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
            swiftSettings: appSettings),
    .target(name: "SafeSightMacCapture", dependencies: ["SafeSightMacWatcher", "Preprocess"], swiftSettings: appSettings),
    .target(name: "SafeSightMacCover", dependencies: ["SafeSightMacWatcher", "SafeSightMacCore"], swiftSettings: appSettings),
    // What only the Testing edition does: the emergency quit (⌃⌥⌘Q), the sandbox check, one copy at a time, the
    // main-thread watchdog and the one-click removal of its own data. Built and tested in every flavour; linked
    // into the app only in the Testing edition.
    .target(name: "SafeSightMacTestingEdition", dependencies: ["SafeSightMacCore"], swiftSettings: appSettings),
    .testTarget(name: "SafeSightMacTestingEditionTests", dependencies: ["SafeSightMacTestingEdition", "SafeSightMacCore"],
                swiftSettings: appSettings),
    // The cover-only menu-bar app.
    .executableTarget(name: "SafeSightMacApp",
                      dependencies: ["SafeSightMacCore", "SafeSightMacWatcher", "SafeSightMacCapture", "SafeSightMacCover", "DetectorCore"]
                          + (testing ? ["SafeSightMacTestingEdition"] : []) + (lab ? ["LabStandIn"] : []),
                      swiftSettings: appSettings),
    // The lab harness: frames from files or synthetic scenes through the pipeline, never the screen.
    .executableTarget(name: "SafeSightMacHarness", dependencies: ["SafeSightMacCore", "SafeSightMacWatcher", "SafeSightMacCover", "DetectorCore", "Preprocess"] + (lab ? ["LabStandIn"] : []),
                      swiftSettings: appSettings),
    // The drawing of covers: way-out lines, colours, click-through panels. Builds layers and panels; shows nothing.
    .testTarget(name: "SafeSightMacCoverTests", dependencies: ["SafeSightMacCover", "SafeSightMacWatcher", "SafeSightMacCore"],
                swiftSettings: appSettings),
    .testTarget(name: "SafeSightMacWatcherTests", dependencies: ["SafeSightMacWatcher", "DetectorCore", "Preprocess", "RegionFinder"] + (lab ? ["LabStandIn"] : []),
                swiftSettings: appSettings),
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
