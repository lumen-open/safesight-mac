// SPDX-License-Identifier: Apache-2.0

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

    /// One line for logs and the "What is running" screen.
    public static var summary: String { "SafeSight Mac \(version) (\(flavour))" }
}
