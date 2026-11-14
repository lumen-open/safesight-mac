// SPDX-License-Identifier: Apache-2.0
import Testing
@testable import FernwickCore

@Test func versionIsSemantic() {
    let parts = BuildInfo.version.split(separator: ".")
    #expect(parts.count == 3)
    #expect(parts.allSatisfy { Int($0) != nil })
}

@Test func releaseBuildsAreNotLab() {
    #if !FERNWICK_LAB
    #expect(BuildInfo.flavour == "release")
    #endif
}
