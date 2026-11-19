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

// MARK: The Testing edition

@Test func theTestingLineIsTheOwnersWordForWord() {
    #expect(AppText.testingLine == "Testing edition: no lock. Quit any time with ⌃⌥⌘Q.")
    #expect(AppText.all.contains(AppText.testingLine), "the forbidden-words check reads it")
    #expect(AppText.testingPieces().map(\.text).joined() == AppText.testingLine)
    #expect(AppText.testingPieces().filter(\.isKey).map(\.text) == AppText.testingKeys)
    #expect(AppText.testingKeys == ["⌃⌥⌘Q"])
}

@Test func withoutTheShortcutTheLineStillSaysThereIsNoLockAndHowToQuit() {
    let l = AppText.testingLine(shortcut: false)
    #expect(l == AppText.testingLineNoShortcut)
    #expect(l.hasPrefix("Testing edition: no lock.") && l.contains("Quit any time"))
    #expect(!l.contains("⌃⌥⌘Q"), "never names a shortcut this copy does not have")
}

@Test func everyTestingTextIsCheckedAndSaysWhatTheEditionIs() {
    for s in AppText.testingAll { #expect(AppText.all.contains(s), "\(s)") }
    #expect(AppText.testingTitle.lowercased().contains("no lock"))
    #expect(AppText.testingDetail.contains("no lock") && AppText.testingDetail.contains("installs nothing"))
    #expect(AppText.testingDetail.contains("administrator password"), "says it never asks for one")
    #expect(AppText.testingRemove == "Remove SafeSight Mac Testing")
    #expect(AppText.testingRemovedDetail.contains("Screen Recording") && AppText.testingRemovedDetail.contains("Trash"))
}

@Test func theTestingHowItWorksOpensWithTheLineAndPromisesNoLockLater() {
    let t = AppText.howItWorksParagraphs(.testing)
    #expect(t.first == AppText.testingLine)
    #expect(!t.contains { $0.contains("comes in a later version") }, "the Testing edition never gets a lock")
    #expect(t.contains { $0.contains("⌃⌥⌘Q") && $0.contains("Remove SafeSight Mac Testing") })
    #expect(t.count == AppText.testingHowItWorksBody.count + AppText.howItWorksBody.count - 1)
    #expect(AppText.howItWorksParagraphs(.standard) == AppText.howItWorksBody)
    #expect(AppText.howItWorksWindowTitle(.testing) == "How SafeSight Mac Testing works")
}

@Test func helpersAreAskedNeverToTestWithExplicitMaterial() {
    #expect(AppText.testingHowItWorksBody.contains { $0.contains("never with explicit material") })
}

@Test func theBuildsEditionFollowsItsFlag() {
    #if SAFESIGHTMAC_TESTING
    #expect(BuildInfo.edition == .testing)
    #else
    #expect(BuildInfo.edition == .standard)
    #endif
}
