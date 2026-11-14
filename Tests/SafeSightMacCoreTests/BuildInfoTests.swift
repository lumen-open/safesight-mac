// SPDX-License-Identifier: Apache-2.0
import Testing
@testable import SafeSightMacCore

@Test func versionIsSemantic() {
    let parts = BuildInfo.version.split(separator: ".")
    #expect(parts.count == 3)
    #expect(parts.allSatisfy { Int($0) != nil })
}

@Test func releaseBuildsAreNotLab() {
    #if !SAFESIGHTMAC_LAB
    #expect(BuildInfo.flavour == "release")
    #endif
}
