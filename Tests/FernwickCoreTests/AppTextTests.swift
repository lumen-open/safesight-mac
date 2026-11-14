// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
@testable import FernwickCore

@Test func thePromiseIsTheREADMEsWordForWord() throws {
    let readme = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../README.md").standardized, encoding: .utf8)
    #expect(readme.contains("> " + AppText.honestPromise))
}

@Test func noTextMakesAClaimTheProjectNeverMakes() {
    for s in AppText.all {
        for bad in AppText.forbiddenPhrases {
            #expect(!s.lowercased().contains(bad.lowercased()), "\(bad) in: \(s)")
        }
    }
}

@Test func theMenuSaysPlainlyThereIsNoLock() {
    #expect(AppText.practiceTitle.lowercased().contains("no lock"))
    #expect(AppText.practiceDetail.contains("no lock"))
    #expect(AppText.howItWorksBody.contains { $0.contains("no lock") })
}

@Test func theModePickerUsesTheRegistersSentenceAndNoFigure() {
    #expect(AppText.modeSentence == "Balanced covers fewer harmless things and misses more. How much more has not been measured.")
    let picker = [AppText.modeHeader, AppText.modeBalanced, AppText.modeEither, AppText.modeSentence].joined()
    #expect(picker.rangeOfCharacter(from: .decimalDigits) == nil)
}

@Test func strictCoverModeIsShownAsNotInThisVersion() {
    #expect(AppText.strictCoverMode.hasSuffix("not in this version"))
}
