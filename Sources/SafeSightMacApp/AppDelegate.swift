// SPDX-License-Identifier: Apache-2.0
// The minimal menu-bar app of the cover-only build: status, the practice state, the detector mode
// picker, strict cover mode shown as "not in this version", pause (practice state only), "How it
// works" and Quit. No Dock icon, no login item, no network. The Testing edition has no keeper check, says what
// it is everywhere it shows, and adds its own ways out (TestingEdition.swift).
import AppKit
import DetectorCore
import SafeSightMacCapture
import SafeSightMacCore
import SafeSightMacCover
import SafeSightMacWatcher

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    /// The covers read the window list again just before drawing a password prompt's hole, so it never stays open for a
    /// prompt that went.
    let watcher = WatcherController(presenter: CoverForm.current == .overlays
        ? OverlayCovers(windows: { WindowList.snapshot() }) : CoverCanvas(windows: { WindowList.snapshot() }))
    private var practice: PracticePresentation = PracticePresentation(.unknown(reason: "not read yet"))
    private var pausedUntil: Date?
    private var pausedIndefinitely = false
    private var resumeTimer: Timer?
    private var permissionTimer: Timer?
    private var howItWorks: HowItWorksWindow?
    /// CoreGraphics' display reconfiguration callback: every display is covered the moment macOS announces a change.
    private var reconfiguration: DisplayReconfiguration?
    /// On battery, Low Power Mode and heat: the watcher's energy mode follows them (covers lift later, nothing shows sooner).
    private var power: PowerState?
    #if SAFESIGHTMAC_TESTING
    let testing = TestingEditionApp()
    #endif

    private var rule: DetectorRule {
        get { DetectorRule(rawValue: UserDefaults.standard.string(forKey: "detectorRule") ?? "") ?? .balanced }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "detectorRule") }
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        // It starts only when its owner opens it: never again by itself at the next login, and with no window
        // state kept for one (found in the Testing edition's safety pass).
        NSApp.disableRelaunchOnLogin()
        UserDefaults.standard.register(defaults: ["NSQuitAlwaysKeepsWindows": false])
        #if SAFESIGHTMAC_TESTING
        guard testing.launch(watcher: watcher) else { return }
        #endif

        #if SAFESIGHTMAC_LAB
        watcher.logOverlays("launch")
        #endif
        statusItem = NSStatusBar.system.statusItem(withLength: BuildInfo.edition == .testing ? NSStatusItem.variableLength : NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "rectangle.dashed", accessibilityDescription: AppText.productName)
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu

        refreshPractice()
        watcher.onChange = { [weak self] in self?.updateIcon() }
        #if SAFESIGHTMAC_TESTING
        testing.onShortcutChanged = { [weak self] in self?.shownIcon = nil; self?.updateIcon() }
        #endif

        // Display changes (SD-112). The reconfiguration callback is the earliest word: its begin call comes before
        // macOS applies a change, and every display is covered before it returns. The notifications are later
        // backstops, and the watcher also reads the display lists again four times a second.
        let r = DisplayReconfiguration { [weak self] change, _ in
            MainActor.assumeIsolated {
                switch change {
                case .willChange: self?.watcher.displaysWillChange()
                case .didChange: self?.watcher.displaysDidChange()
                }
            }
        }
        r.start()
        reconfiguration = r
        // Sleep, display sleep and a session switch hold every cover until their own counterpart.
        let ws = NSWorkspace.shared.notificationCenter
        let pairs: [(NSNotification.Name, NSNotification.Name, HoldReason)] = [
            (NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification, .sleep),
            (NSWorkspace.screensDidSleepNotification, NSWorkspace.screensDidWakeNotification, .displaysAsleep),
            (NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.sessionDidBecomeActiveNotification, .session),
        ]
        for (away, back, reason) in pairs {
            ws.addObserver(forName: away, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.watcher.suspend(reason) } }
            ws.addObserver(forName: back, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.watcher.resume(reason) } }
        }
        let power = PowerState { [weak self] mode in self?.watcher.setEnergy(mode) }
        power.start()
        self.power = power
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.watcher.displaysDidChange() } }

        startIfAllowed()
    }

    func applicationWillTerminate(_ note: Notification) {
        reconfiguration?.stop()
        watcher.stop()
    }

    // MARK: Running

    private var permission: Bool { ScreenRecordingPermission.granted }

    /// Whether this copy may check and cover at all: always in the release edition; in the Testing edition, only
    /// inside the App Sandbox.
    private var mayRun: Bool {
        #if SAFESIGHTMAC_TESTING
        return testing.sandboxed
        #else
        return true
        #endif
    }

    /// Reads the practice signal and offers Pause on the repair card only in the practice state. The Testing
    /// edition has no keeper check: it always allows pausing.
    private func refreshPractice() {
        #if SAFESIGHTMAC_TESTING
        practice = .testing
        #else
        practice = PracticePresentation(PracticeState.read())
        #endif
        let allowed = practice.pauseAllowed
        watcher.repairActions = RepairCard.Actions(
            tryAgain: { [weak self] in self?.tryAgain() },
            pause: allowed ? { [weak self] in self?.pauseFromCard() } : nil,
            quit: { NSApp.terminate(nil) })
    }

    private func startIfAllowed() {
        guard pausedUntil == nil, !pausedIndefinitely, mayRun else { updateIcon(); return }
        if permission {
            permissionTimer?.invalidate(); permissionTimer = nil
            watcher.start(rule: rule)
        } else if permissionTimer == nil {
            // Until Screen Recording is granted nothing is checked or covered; look again now and then.
            permissionTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { if self?.permission == true { self?.startIfAllowed() } }
            }
        }
        updateIcon()
    }

    /// Try again keeps every display covered while it restarts (no cover comes down in between), unless covering
    /// cannot run at all (paused, or no Screen Recording).
    private func tryAgain() {
        refreshPractice()
        if permission, pausedUntil == nil, !pausedIndefinitely, mayRun {
            watcher.restart(rule: rule)
            updateIcon()
        } else {
            watcher.stop()
            startIfAllowed()
        }
    }

    // MARK: Pause (practice state only: step 1 has no lock)

    private func pause(minutes: Int?) {
        refreshPractice()
        guard practice.pauseAllowed else { return }
        watcher.stop()
        resumeTimer?.invalidate()
        if let m = minutes {
            pausedUntil = Date().addingTimeInterval(TimeInterval(m * 60)); pausedIndefinitely = false
            resumeTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(m * 60), repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.resume() } }
        } else {
            pausedIndefinitely = true
        }
        updateIcon()
    }

    private func pauseFromCard() { pause(minutes: 15) }

    private func resume() {
        resumeTimer?.invalidate(); resumeTimer = nil
        pausedUntil = nil; pausedIndefinitely = false
        startIfAllowed()
    }

    // MARK: Menu

    private var status: WatcherStatus {
        WatcherStatus.compute(permission: permission, paused: pausedUntil, pausedIndefinitely: pausedIndefinitely,
                              detectorFailed: watcher.detectorFailed, plans: watcher.plans, running: watcher.running)
    }

    /// What the menu bar item shows now (its symbol and status), so it is drawn again only when that changes.
    private var shownIcon: (symbol: String, title: String)?

    /// The menu bar item. It is redrawn only when its symbol or status changes: on macOS 26 the item is drawn by the
    /// system's menu bar, not inside this app, so the capture sees it, and redrawing it on every cover update made the
    /// screen "change" by itself many times a second, each change judged again.
    private func updateIcon() {
        let symbol: String
        switch status {
        case .on, .starting: symbol = mayRun ? "rectangle.dashed" : "exclamationmark.triangle"
        case .paused: symbol = "pause.rectangle"
        case .needsScreenRecording, .detectorUnavailable, .displayCovered: symbol = "exclamationmark.triangle"
        }
        let title = status.title
        guard let button = statusItem?.button, shownIcon.map({ $0 != (symbol, title) }) ?? true else { return }
        shownIcon = (symbol, title)
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: AppText.productName + ": " + title)
        #if SAFESIGHTMAC_TESTING
        testing.label(button, status: mayRun ? title : AppText.testingNotSandboxed)
        #endif
    }

    /// While the menu is open its windows are kept above the covers, so it can be used under a whole-display cover.
    private var menuLift: Timer?

    func menuWillOpen(_ menu: NSMenu) {
        menuLift?.invalidate()
        let t = Timer(timeInterval: 0.02, repeats: true) { _ in MainActor.assumeIsolated { _ = OwnMenus.lift() } }
        RunLoop.main.add(t, forMode: .common)
        RunLoop.main.add(t, forMode: .eventTracking)
        menuLift = t
        OwnMenus.lift()
    }

    func menuDidClose(_ menu: NSMenu) {
        menuLift?.invalidate(); menuLift = nil
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        refreshPractice()
        menu.removeAllItems()
        actions.begin()

        #if SAFESIGHTMAC_TESTING
        testing.followLayout()
        for i in testing.menuHeader() { menu.addItem(i) }
        menu.addItem(.separator())
        if !mayRun {
            menu.addItem(label(AppText.testingNotSandboxed, bold: true))
            menu.addItem(note(AppText.testingNotSandboxedDetail))
        }
        #endif

        if mayRun {
            menu.addItem(label(status.title, bold: true))
            switch status {
            case .needsScreenRecording:
                menu.addItem(note(AppText.needsPermissionDetail))
                menu.addItem(item(AppText.grantPermission) { Self.askForScreenRecording() })
                menu.addItem(note(AppText.permissionSteps))
            case let .displayCovered(cause):
                menu.addItem(note(cause.plainWords))
            case .paused(let until):
                if let u = until { menu.addItem(note("Covering resumes at \(DateFormatter.localizedString(from: u, dateStyle: .none, timeStyle: .short)).")) }
            default: break
            }
        }

        if BuildInfo.edition == .standard {
            menu.addItem(.separator())
            menu.addItem(label(practice.title, bold: true))
            menu.addItem(note(practice.detail))
        }

        menu.addItem(.separator())
        menu.addItem(label(AppText.modeHeader, bold: true))
        for (r, title) in [(DetectorRule.balanced, AppText.modeBalanced), (.either, AppText.modeEither)] {
            let i = item(title) { [weak self] in self?.rule = r; self?.watcher.setRule(r) }
            i.state = rule == r ? .on : .off
            menu.addItem(i)
        }
        menu.addItem(note(AppText.modeSentence))
        let strict = label(AppText.strictCoverMode, bold: false)
        menu.addItem(strict)

        menu.addItem(.separator())
        if case .paused = status {
            menu.addItem(item(AppText.resume) { [weak self] in self?.resume() })
        } else {
            for (t, m) in [(AppText.pauseFor15, 15), (AppText.pauseFor60, 60)] {
                let i = item(t) { [weak self] in self?.pause(minutes: m) }
                i.isEnabled = practice.pauseAllowed && mayRun
                menu.addItem(i)
            }
        }

        menu.addItem(.separator())
        menu.addItem(item(AppText.howItWorks) { [weak self] in self?.showHowItWorks() })
        #if SAFESIGHTMAC_TESTING
        menu.addItem(item(AppText.testingReportMenu) { [weak self] in self?.testing.showReport() })
        menu.addItem(item(AppText.testingRemove) { [weak self] in self?.removeEverything() })
        let quit = item(AppText.testingQuit) { NSApp.terminate(nil) }
        testing.showShortcut(on: quit)
        menu.addItem(quit)
        #else
        menu.addItem(item(AppText.quit) { NSApp.terminate(nil) })
        #endif
    }

    private func showHowItWorks() {
        #if SAFESIGHTMAC_TESTING
        // Made afresh, so that it says whether ⌃⌥⌘Q works now.
        let w = HowItWorksWindow(shortcut: testing.shortcutWorks)
        #else
        let w = howItWorks ?? HowItWorksWindow()
        #endif
        howItWorks = w
        w.show()
    }

    #if SAFESIGHTMAC_TESTING
    /// "Remove SafeSight Mac Testing": stop, clear its own data, say what is left, quit.
    private func removeEverything() {
        if let s = statusItem { NSStatusBar.system.removeStatusItem(s) }
        statusItem = nil
        testing.removeEverything(watcher: watcher)
    }
    #endif

    /// The first time, only macOS's own question is asked: it has its own Open System Settings button. Opening System
    /// Settings at the same moment put Settings in front of that question, where it stayed unanswered behind the window
    /// (and later under the covers). After that, macOS asks no more, so System Settings is opened directly.
    static func askForScreenRecording() {
        let key = "askedForScreenRecording"
        if UserDefaults.standard.bool(forKey: key) {
            openScreenRecordingSettings()
        } else {
            UserDefaults.standard.set(true, forKey: key)
            ScreenRecordingPermission.request()
        }
    }

    static func openScreenRecordingSettings() {
        if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") { NSWorkspace.shared.open(u) }
    }

    // MARK: Menu items

    private let actions = MenuActions()

    func item(_ title: String, _ action: @escaping () -> Void) -> NSMenuItem { actions.item(title, action) }

    func label(_ s: String, bold: Bool) -> NSMenuItem {
        let i = NSMenuItem(title: s, action: nil, keyEquivalent: "")
        if bold { i.attributedTitle = NSAttributedString(string: s, attributes: [.font: NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)]) }
        i.isEnabled = false
        return i
    }

    /// A wrapped paragraph inside the menu.
    func note(_ s: String) -> NSMenuItem {
        let i = NSMenuItem()
        let f = NSTextField(wrappingLabelWithString: s)
        f.font = .menuFont(ofSize: NSFont.smallSystemFontSize)
        f.textColor = .secondaryLabelColor
        f.preferredMaxLayoutWidth = 300
        let size = f.fittingSize
        let v = NSView(frame: CGRect(x: 0, y: 0, width: 320, height: size.height + 6))
        f.frame = CGRect(x: 14, y: 3, width: 300, height: size.height)
        v.addSubview(f)
        i.view = v
        return i
    }
}
