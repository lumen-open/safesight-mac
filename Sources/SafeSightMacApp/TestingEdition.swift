// SPDX-License-Identifier: Apache-2.0
// What the Testing edition adds to the app (docs/TESTING-EDITION.md). Compiled only into the Testing edition.
//
// - One copy at a time: a second copy says so and quits.
// - ⌃⌥⌘Q quits at once from anywhere, covers or not (EmergencyQuit). If another app holds the shortcut, every
//   line says to quit from the menu bar icon instead.
// - It checks and covers only inside the App Sandbox (Sandbox).
// - If its main thread stops answering while a cover is up, it quits (StallWatchdog).
// - Its line is on the menu bar item, the menu, the repair card, whole-window and whole-display covers, any cover
//   that hides half a display, and the "How it works" window.
// - "Remove SafeSight Mac Testing" clears its own settings and data (Removal) and says what macOS keeps.
#if SAFESIGHTMAC_TESTING
import AppKit
import Carbon.HIToolbox
import SafeSightMacCore
import SafeSightMacCover
import SafeSightMacTestingEdition

@MainActor
final class TestingEditionApp {
    let sandboxed = Sandbox.isSandboxed()
    private var emergency: EmergencyQuit?
    private var stallWatchdog: StallWatchdog?
    private weak var watcher: WatcherController?
    private var layoutObserver: NSObjectProtocol?
    private var layoutTimer: Timer?
    /// The Testing report's numbers, from the moment covering starts; in memory only.
    private var stats = TestingStats()
    private let startedAt = ProcessInfo.processInfo.systemUptime
    private let cpuAtStart = TestingFacts.cpuSeconds()
    private var report: TestingReportWindow?

    var shortcutWorks: Bool { emergency?.state.works ?? false }

    /// At launch. False only when another copy is already running: this one has then said so and is ending.
    func launch(watcher: WatcherController) -> Bool {
        if SingleCopy.anotherCopyRunning() {
            showAlreadyRunning()
            return false
        }
        self.watcher = watcher
        // The way out that needs nothing else: registered first, before anything can be covered.
        let e = EmergencyQuit { [weak self] in MainActor.assumeIsolated { self?.quitNow() } }
        e.register()
        emergency = e
        // The Q key moves with the keyboard layout (AZERTY, Dvorak): register again when the layout changes. macOS
        // holds back distributed notifications from an app that is not in front, and this one almost never is, so a
        // timer also looks every two seconds (a cheap comparison of the layout's name).
        layoutObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.followLayout() }
        }
        let t = Timer(timeInterval: 2, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.followLayout() } }
        RunLoop.main.add(t, forMode: .common)
        layoutTimer = t
        let dog = StallWatchdog { _exit(0) }
        dog.start()
        stallWatchdog = dog
        watcher.onCoversShown = { [weak dog] shown in dog?.setCoverShown(shown) }
        watcher.notice = .testing(shortcut: shortcutWorks)
        watcher.onJudged = { [weak self] id, judgeMs, latencyMs, _, idle, t in
            self?.stats.record(display: id, judgeMs: judgeMs, latencyMs: latencyMs,
                               pass: .init(idle: idle, blurAtOnce: t.blurAtOnceFirings > 0, coveredFirst: t.coveredFirst,
                                           leftForLater: t.leftForLater, unjudged: t.overloaded, rechecks: t.rechecks))
        }
        watcher.onCaptured = { [weak self] status in self?.stats.recordCaptured(status.rawValue) }
        // What was actually drawn, early plans included: the report counts what was on screen.
        watcher.onDrawn = { [weak self] plans in
            self?.stats.recordDrawn(plans.map { .init(display: $0.display.id, whole: $0.wholeDisplay?.rawValue, covers: $0.plainCount, blurs: $0.blurCount) })
        }
        watcher.onWaitingCover = { [weak self] in self?.stats.recordWaitingCover() }
        return true
    }

    /// Told when whether ⌃⌥⌘Q is this copy's changed (the menu bar item's words change with it).
    var onShortcutChanged: (() -> Void)?

    /// Registers ⌃⌥⌘Q again if the keyboard layout changed, and keeps the covers' line truthful.
    func followLayout() {
        guard let e = emergency, e.followLayout() else { return }
        watcher?.notice = .testing(shortcut: shortcutWorks)
        onShortcutChanged?()
    }

    /// ⌃⌥⌘Q: covers off, and the app ends at once. It does not wait for anything that could be stuck; macOS removes
    /// every window of an ended app, covers included.
    func quitNow() {
        watcher?.hideEverything()
        _exit(0)
    }

    /// The menu bar item: the icon, the word "Testing", and the edition's line as its tooltip and spoken label.
    func label(_ button: NSStatusBarButton, status: String) {
        let line = AppText.testingLine(shortcut: shortcutWorks)
        button.title = AppText.testingBadge
        button.imagePosition = .imageLeading
        button.toolTip = line
        button.setAccessibilityLabel(AppText.testingName + ". " + line + " " + status)
    }

    /// The top of the menu: the edition's line, what the edition is, and a note when ⌃⌥⌘Q is not this copy's.
    func menuHeader() -> [NSMenuItem] {
        let d = NSApp.delegate as? AppDelegate
        var items: [NSMenuItem] = []
        if let d {
            items.append(d.label(AppText.testingLine(shortcut: shortcutWorks), bold: true))
            items.append(d.note(AppText.testingDetail))
            if !shortcutWorks { items.append(d.note(AppText.testingShortcutTaken)) }
        }
        return items
    }

    /// The Testing report window: numbers to copy by hand, and the helper's note.
    func showReport() {
        let facts = TestingReportWindow.facts(shortcut: shortcutWorks)
        let w = report ?? TestingReportWindow { [weak self] note in
            guard let self else { return "" }
            return TestingReport.text(facts: facts, stats: self.stats, running: ProcessInfo.processInfo.systemUptime - self.startedAt,
                                      cpu: TestingFacts.cpuSeconds() - self.cpuAtStart, note: note,
                                      power: TestingFacts.power())
        }
        report = w
        w.show()
    }

    /// Shows ⌃⌥⌘Q beside Quit, when the shortcut is this copy's.
    func showShortcut(on item: NSMenuItem) {
        guard shortcutWorks else { return }
        item.keyEquivalent = "q"
        item.keyEquivalentModifierMask = [.control, .option, .command]
    }

    /// "Remove SafeSight Mac Testing". Stops covering, waits briefly for judging to finish, removes the app's own
    /// settings and data, says what macOS keeps and how to remove it, and quits.
    func removeEverything(watcher: WatcherController) {
        watcher.stop()
        _ = watcher.waitForJudging(timeout: 3)
        stallWatchdog?.stop()
        layoutTimer?.invalidate()
        let id = Bundle.main.bundleIdentifier ?? ""
        if !id.isEmpty { Removal.run(bundleID: id) }
        let a = NSAlert()
        a.messageText = AppText.testingRemovedTitle
        a.informativeText = AppText.testingRemovedDetail
        a.addButton(withTitle: AppText.testingRemovedOpenSettings)
        a.addButton(withTitle: AppText.testingRemovedShowApp)
        a.addButton(withTitle: AppText.testingRemovedDone)
        switch Self.showAboveCovers(a) {
        case .alertFirstButtonReturn: AppDelegate.openScreenRecordingSettings()
        case .alertSecondButtonReturn: NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
        default: break
        }
        // Once more, for anything written while the message was up (judging that had not finished, AppKit's own
        // settings), then end without AppKit's quitting steps, so nothing is written after it.
        if !id.isEmpty { Removal.run(bundleID: id) }
        exit(0)
    }

    /// The second copy's message, in a panel of its own at the level above covers (the first copy's covers may be
    /// up). Not an NSAlert: running one modally may set its own window level, below the covers. This copy ends when
    /// the button is clicked, or after 30 seconds on its own.
    private var alreadyRunning: NSPanel?
    private func showAlreadyRunning() {
        let p = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 420, height: 120), styleMask: [.titled], backing: .buffered, defer: false)
        p.title = AppText.testingName
        p.isRestorable = false
        p.level = CoverLevels.appAbove
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let text = NSTextField(wrappingLabelWithString: AppText.testingAlreadyRunning)
        text.frame = CGRect(x: 20, y: 56, width: 380, height: 44)
        let button = NSButton(title: AppText.testingRemovedDone, target: nil, action: nil)
        button.frame = CGRect(x: 310, y: 14, width: 90, height: 32)
        button.bezelStyle = .push
        button.keyEquivalent = "\r"
        button.target = QuitTarget.shared
        button.action = #selector(QuitTarget.quit)
        p.contentView?.addSubview(text)
        p.contentView?.addSubview(button)
        p.center()
        NSApp.activate()
        p.orderFrontRegardless()
        p.makeKey()
        alreadyRunning = p
        Timer.scheduledTimer(withTimeInterval: 30, repeats: false) { _ in exit(0) }
    }

    /// Shows an alert in front, above every cover (covers sit at the screen-saver level, above ordinary alerts).
    @discardableResult
    static func showAboveCovers(_ a: NSAlert) -> NSApplication.ModalResponse {
        NSApp.activate()
        a.layout()
        a.window.level = CoverLevels.appAbove
        return a.runModal()
    }
}
/// Ends the second copy when its message is dismissed.
final class QuitTarget: NSObject {
    static let shared = QuitTarget()
    @objc func quit() { exit(0) }
}
#endif
