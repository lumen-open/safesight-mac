// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
@testable import SafeSightMacCore

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

@Test func theWayOutLineSaysHowToLeaveInPlainWords() {
    #expect(AppText.wayOutLine == "Press ⌘W to close this tab, or ⌘[ to go back.")
    #expect(AppText.all.contains(AppText.wayOutLine), "the forbidden-words check reads it")
    #expect(AppText.wayOutPieces.map(\.text).joined() == AppText.wayOutLine)
    #expect(AppText.wayOutPieces.filter(\.isKey).map(\.text) == AppText.wayOutKeys)
    #expect(AppText.wayOutPieces.first?.text == "Press ")
}

/// The product's name is written once, in `AppText.productName`, so a rebrand is one line. Comments may name it.
@Test func theProductNameIsWrittenOnlyInAppText() throws {
    let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../Sources").standardized
    let files = (FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)?.allObjects ?? [])
        .compactMap { $0 as? URL }
        .filter { $0.pathExtension == "swift" && $0.lastPathComponent != "AppText.swift" }
    #expect(!files.isEmpty)
    for file in files {
        let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n")
        for (n, line) in lines.enumerated() {
            let code = line.trimmingCharacters(in: .whitespaces)
            if code.hasPrefix("//") { continue }
            #expect(!code.contains(AppText.productName), "\(file.lastPathComponent):\(n + 1) names the product; use AppText.productName")
        }
    }
}
