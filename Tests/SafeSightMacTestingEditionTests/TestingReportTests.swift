// SPDX-License-Identifier: Apache-2.0
// The Testing report: numbers about the Mac, its displays and how the app ran, and the helper's note, as text to copy
// by hand. Made from made-up numbers here.
import Foundation
import Testing
@testable import SafeSightMacCore
@testable import SafeSightMacTestingEdition

@Suite struct TestingReportTests {
    let facts = TestingFacts(macModel: "Mac14,2", macOS: "Version 26.3", edition: "testing", version: "0.0.1",
                             executableSHA: String(repeating: "a", count: 64), modelsStamp: String(repeating: "b", count: 64),
                             displays: [.init(width: 1512, height: 982, scale: 2, builtIn: true, mirrored: false),
                                        .init(width: 2560, height: 1440, scale: 1, builtIn: false, mirrored: false)],
                             shortcutRegistered: true)

    @Test func percentilesAndCounts() {
        #expect(TestingStats.percentile([], 0.5) == nil)
        #expect(TestingStats.percentile([5, 1, 3], 0.5) == 3)
        var s = TestingStats()
        s.record(display: 1, judgeMs: 10, latencyMs: 40, covers: 0, whole: "notYetJudged")
        s.record(display: 1, judgeMs: 12, latencyMs: 42, covers: 0, whole: "notYetJudged")   // the same cover, still up
        s.record(display: 1, judgeMs: 11, latencyMs: 41, covers: 2, whole: nil)
        s.record(display: 1, judgeMs: 11, latencyMs: 41, covers: 0, whole: "displayChanging")
        #expect(s.judged == 4 && s.framesWithCovers == 1)
        #expect(s.wholeDisplay == ["notYetJudged": 1, "displayChanging": 1], "counted when a display becomes covered whole")
    }

    @Test func theTimingsStayBounded() {
        var s = TestingStats()
        for i in 0..<(TestingStats.keep + 100) { s.record(display: 1, judgeMs: Double(i), latencyMs: 1, covers: 0, whole: nil) }
        #expect(s.judgeMs.count == TestingStats.keep && s.judged == TestingStats.keep + 100)
    }

    @Test func theReportSaysWhatItShouldAndCarriesTheNote() {
        var s = TestingStats()
        s.record(display: 1, judgeMs: 20, latencyMs: 60, covers: 1, whole: nil)
        let t = TestingReport.text(facts: facts, stats: s, running: 120, cpu: 30, note: "  A harmless chart was covered in a slide app.  ")
        #expect(t.hasPrefix(AppText.testingReportTitle))
        #expect(t.contains("Note: A harmless chart was covered in a slide app."))
        #expect(t.contains("Mac: Mac14,2, macOS Version 26.3"))
        #expect(t.contains("Displays: 2 (1512 x 982 pt at 2x, built in; 2560 x 1440 pt at 1x, external)"))
        #expect(t.contains("⌃⌥⌘Q: registered"))
        #expect(t.contains("CPU: 25% of one core on average"))
        #expect(t.contains("Capture to cover plan: median 60 ms"))
        #expect(!TestingReport.text(facts: facts, stats: s, running: 1, cpu: 0, note: "").contains("Note: \n"))
        #expect(!t.contains("Power:"), "no power line unless one is given")
        let p = TestingReport.text(facts: facts, stats: s, running: 1, cpu: 0, note: "", power: TestingFacts.power())
        #expect(p.contains("Power: heat ") && p.contains(", Low Power Mode o"))
    }

    @Test func theReportsWordsAreCheckedLikeEveryOther() {
        for s in [AppText.testingReportMenu, AppText.testingReportTitle, AppText.testingReportIntro, AppText.testingReportNoteLabel] {
            #expect(AppText.testingAll.contains(s))
        }
        #expect(AppText.testingReportIntro.contains("Nothing here leaves your Mac"))
    }

    @Test func itReadsTheMacsModelAndItsOwnCPUTime() {
        #expect(!TestingFacts.macModel().isEmpty)
        #expect(TestingFacts.cpuSeconds() > 0)
    }
}
