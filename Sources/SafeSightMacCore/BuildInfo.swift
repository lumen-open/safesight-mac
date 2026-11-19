// SPDX-License-Identifier: Apache-2.0

/// Which app a build is. The Testing edition (`SAFESIGHTMAC_TESTING=1`, docs/TESTING-EDITION.md) is the one
/// volunteer helpers may install: no lock, quit any time, sandboxed. Everything that differs between the two is
/// chosen from this value, so tests can draw and word either edition in any build.
public enum Edition: String, Sendable, CaseIterable {
    case standard, testing
}

/// Facts about this build that every part can report. Step 0 holds only the
/// version and the build flavour; later steps add the lock-core version record.
public enum BuildInfo {
    /// Semantic version of this release.
    public static let version = "0.0.1"

    /// "release" or "lab". Lab builds may contain test switches; release builds never do.
    #if SAFESIGHTMAC_LAB
    public static let flavour = "lab"
    #else
    public static let flavour = "release"
    #endif

    /// The edition this build is. Fixed when it is compiled; nothing at run time can change it.
    #if SAFESIGHTMAC_TESTING
    public static let edition = Edition.testing
    #else
    public static let edition = Edition.standard
    #endif

    /// One line for logs and the "What is running" screen.
    public static var summary: String { "\(AppText.productName) \(version) (\(flavour))" }
}
