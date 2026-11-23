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
                             shortcut: .registered)

    @Test func percentilesAndCounts() {
        #expect(TestingStats.percentile([], 0.5) == nil)
        #expect(TestingStats.percentile([5, 1, 3], 0.5) == 3)
        var s = TestingStats()
        s.record(display: 1, judgeMs: 10, latencyMs: 40)
        s.record(display: 1, judgeMs: 12, latencyMs: 42, pass: .init(idle: true))
        s.record(display: 1, judgeMs: 11, latencyMs: 41, pass: .init(blurAtOnce: true, coveredFirst: 3, leftForLater: 1, unjudged: 7, rechecks: 2))
        #expect(s.judged == 3 && s.judgedNew == 2 && s.judgedIdle == 1)
        #expect(s.blurAtOnce == 1 && s.coveredFirst == 3 && s.leftForLater == 1 && s.unjudgedEntries == 7 && s.rechecks == 2)
        s.recordCaptured("complete"); s.recordCaptured("idle"); s.recordCaptured("complete")
        #expect(s.captured == ["complete": 2, "idle": 1])
    }

    /// The first live run: final plans said "nothing covered" while every update drawn in between covered or blurred,
    /// and the report said "Frames with a cover or blur: 0" over a covered screen. It now counts what is drawn.
    @Test func itCountsWhatIsDrawnNotOnlyTheFinalPlan() {
        var s = TestingStats()
        s.recordDrawn([.init(display: 1, whole: "notYetJudged", covers: 0, blurs: 0)])
        s.recordDrawn([.init(display: 1, whole: "notYetJudged", covers: 0, blurs: 0)])   // the same cover, still up
        s.recordDrawn([.init(display: 1, whole: nil, covers: 2, blurs: 5)])               // an early plan with blurs
        s.recordDrawn([.init(display: 1, whole: "windowAboveCovers", covers: 0, blurs: 0)])
        s.recordDrawn([.init(display: 1, whole: nil, covers: 0, blurs: 0)])
        #expect(s.drawn == 5 && s.framesWithCovers == 4)
        #expect(s.coversDrawn == 2 && s.blursDrawn == 5)
        #expect(s.wholeDisplay == ["notYetJudged": 1, "windowAboveCovers": 1], "counted when a display becomes covered whole")
        #expect(s.now == [1: "nothing covered"])
        s.recordWaitingCover()
        #expect(s.waitingCovers == 1)
        let t = TestingReport.text(facts: facts, stats: s, running: 60, cpu: 1, note: "")
        #expect(t.contains("Frames with a cover or blur: 4"))
        #expect(t.contains("Updates drawn: 5"))
        #expect(t.contains("On screen now: nothing covered"))
        #expect(t.contains("Whole-display covers: notYetJudged 1, windowAboveCovers 1"))
        #expect(t.contains("waiting covers 1 ticks"))
    }

    @Test func theTimingsStayBounded() {
        var s = TestingStats()
        for i in 0..<(TestingStats.keep + 100) { s.record(display: 1, judgeMs: Double(i), latencyMs: 1) }
        #expect(s.judgeMs.count == TestingStats.keep && s.judged == TestingStats.keep + 100)
    }

    @Test func theReportSaysWhatItShouldAndCarriesTheNote() {
        var s = TestingStats()
        s.record(display: 1, judgeMs: 20, latencyMs: 60)
        s.recordCaptured("complete")
        s.recordDrawn([.init(display: 1, whole: nil, covers: 1, blurs: 0)])
        let t = TestingReport.text(facts: facts, stats: s, running: 120, cpu: 30, note: "  A harmless chart was covered in a slide app.  ")
        #expect(t.hasPrefix(AppText.testingReportTitle))
        #expect(t.contains("Note: A harmless chart was covered in a slide app."))
        #expect(t.contains("Mac: Mac14,2, macOS Version 26.3"))
        #expect(t.contains("Displays: 2 (1512 x 982 pt at 2x, built in; 2560 x 1440 pt at 1x, external)"))
        #expect(t.contains("⌃⌥⌘Q: registered"))
        #expect(t.contains("CPU: 25% of one core on average"))
        #expect(t.contains("Capture to cover plan: median 60 ms"))
        #expect(t.contains("Frames captured: complete 1"))
        #expect(t.contains("Frames judged: 1 with new pixels, 0 judged again with nothing new"))
        #expect(t.contains("On screen now: 1 covers, 0 blurs"))
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

    /// Third live run: at the lock screen every canvas was off the screen, but the report still said "covered whole".
    @Test func whenEveryCanvasIsTakenOffTheReportSaysNothingIsDrawn() {
        var s = TestingStats()
        s.recordDrawn([.init(display: 1, whole: "displayChanging", covers: 0, blurs: 0)])
        s.recordDrawn([])
        #expect(s.now.isEmpty)
        #expect(TestingReport.text(facts: facts, stats: s, running: 60, cpu: 1, note: "").contains("On screen now: nothing drawn"))
    }

    /// After the stall watchdog ended the last run, the report says when, and the menu's words say the covers came down.
    @Test func itSaysWhenTheLastRunEndedItself() {
        var f = facts
        #expect(!TestingReport.text(facts: f, stats: TestingStats(), running: 1, cpu: 0, note: "").contains("Last run"))
        f.endedItselfAt = Date(timeIntervalSince1970: 1_795_000_000)
        let t = TestingReport.text(facts: f, stats: TestingStats(), running: 1, cpu: 0, note: "")
        #expect(t.contains("Last run: ended itself at " + ISO8601DateFormatter().string(from: f.endedItselfAt!) + " after it stopped responding"))
        let line = AppText.testingEndedItself(at: "14:02")
        #expect(line == "Last time, SafeSight Mac Testing stopped responding and ended itself at 14:02. Its covers came down then.")
        #expect(AppText.testingAll.contains(AppText.testingEndedItself(at: "12:00")))
    }
}
