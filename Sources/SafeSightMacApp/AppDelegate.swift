// SPDX-License-Identifier: Apache-2.0
// The minimal menu-bar app of the cover-only build: status, the practice state, the detector mode
// picker, strict cover mode shown as "not in this version", pause (practice state only), "How it
// works" and Quit. No Dock icon, no login item, no network.
import AppKit
import DetectorCore
import SafeSightMacCapture
import SafeSightMacCore
import SafeSightMacCover
import SafeSightMacWatcher

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let watcher = WatcherController(presenter: CoverForm.current == .overlays ? OverlayCovers() : CoverCanvas())
    private var practice: PracticeSignal = .unknown(reason: "not read yet")
    private var pausedUntil: Date?
    private var pausedIndefinitely = false
    private var resumeTimer: Timer?
    private var permissionTimer: Timer?
    private var howItWorks: HowItWorksWindow?
    /// CoreGraphics' display reconfiguration callback: every display is covered the moment macOS announces a change.
    private var reconfiguration: DisplayReconfiguration?

    private var rule: DetectorRule {
        get { DetectorRule(rawValue: UserDefaults.standard.string(forKey: "detectorRule") ?? "") ?? .balanced }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "detectorRule") }
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "rectangle.dashed", accessibilityDescription: "SafeSight Mac")
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu

        refreshPractice()
        watcher.onChange = { [weak self] in self?.updateIcon() }

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

    /// Reads the practice signal and offers Pause on the repair card only in the practice state.
    private func refreshPractice() {
        practice = PracticeState.read()
        let allowed = PracticePresentation(practice).pauseAllowed
        watcher.repairActions = RepairCard.Actions(
            tryAgain: { [weak self] in self?.tryAgain() },
            pause: allowed ? { [weak self] in self?.pauseFromCard() } : nil,
            quit: { NSApp.terminate(nil) })
    }

    private func startIfAllowed() {
        guard pausedUntil == nil, !pausedIndefinitely else { return }
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
        if permission, pausedUntil == nil, !pausedIndefinitely {
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
        guard PracticePresentation(practice).pauseAllowed else { return }
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

    private func updateIcon() {
        let symbol: String
        switch status {
        case .on, .starting: symbol = "rectangle.dashed"
        case .paused: symbol = "pause.rectangle"
        case .needsScreenRecording, .detectorUnavailable, .displayCovered: symbol = "exclamationmark.triangle"
        }
        statusItem?.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "SafeSight Mac: " + status.title)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        refreshPractice()
        let pp = PracticePresentation(practice)
        menu.removeAllItems()

        menu.addItem(label(status.title, bold: true))
        switch status {
        case .needsScreenRecording:
            menu.addItem(note(AppText.needsPermissionDetail))
            menu.addItem(item(AppText.grantPermission) { ScreenRecordingPermission.request(); Self.openScreenRecordingSettings() })
        case let .displayCovered(cause):
            menu.addItem(note(cause.plainWords))
        case .paused(let until):
            if let u = until { menu.addItem(note("Covering resumes at \(DateFormatter.localizedString(from: u, dateStyle: .none, timeStyle: .short)).")) }
        default: break
        }

        menu.addItem(.separator())
        menu.addItem(label(pp.title, bold: true))
        menu.addItem(note(pp.detail))

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
                i.isEnabled = pp.pauseAllowed
                menu.addItem(i)
            }
        }

        menu.addItem(.separator())
        menu.addItem(item(AppText.howItWorks) { [weak self] in self?.showHowItWorks() })
        menu.addItem(item(AppText.quit) { NSApp.terminate(nil) })
    }

    private func showHowItWorks() {
        let w = howItWorks ?? HowItWorksWindow()
        howItWorks = w
        w.show()
    }

    static func openScreenRecordingSettings() {
        if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") { NSWorkspace.shared.open(u) }
    }

    // MARK: Menu items

    private var handlers: [ClosureTarget] = []

    private func item(_ title: String, _ action: @escaping () -> Void) -> NSMenuItem {
        let t = ClosureTarget(action)
        handlers.append(t)
        let i = NSMenuItem(title: title, action: #selector(ClosureTarget.fire), keyEquivalent: "")
        i.target = t
        return i
    }

    private func label(_ s: String, bold: Bool) -> NSMenuItem {
        let i = NSMenuItem(title: s, action: nil, keyEquivalent: "")
        if bold { i.attributedTitle = NSAttributedString(string: s, attributes: [.font: NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)]) }
        i.isEnabled = false
        return i
    }

    /// A wrapped paragraph inside the menu.
    private func note(_ s: String) -> NSMenuItem {
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

final class ClosureTarget: NSObject {
    let action: () -> Void
    init(_ a: @escaping () -> Void) { action = a }
    @objc func fire() { action() }
}
