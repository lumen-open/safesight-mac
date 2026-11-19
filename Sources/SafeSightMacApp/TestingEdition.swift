// SPDX-License-Identifier: Apache-2.0
// What the Testing edition adds to the app (docs/TESTING-EDITION.md). Compiled only into the Testing edition.
//
// - ⌃⌥⌘Q quits at once from anywhere, covers or not (EmergencyQuit). If another app holds the shortcut, every
//   line says to quit from the menu bar icon instead.
// - It checks and covers only inside the App Sandbox (Sandbox).
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
    private weak var watcher: WatcherController?
    private var layoutObserver: NSObjectProtocol?

    var shortcutWorks: Bool { emergency?.state.works ?? false }

    /// At launch.
    func launch(watcher: WatcherController) -> Bool {
        self.watcher = watcher
        // The way out that needs nothing else: registered first, before anything can be covered.
        let e = EmergencyQuit { [weak self] in MainActor.assumeIsolated { self?.quitNow() } }
        e.register()
        emergency = e
        // The Q key moves with the keyboard layout (AZERTY, Dvorak): register again when the layout changes.
        layoutObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.followLayout() }
        }
        watcher.notice = .testing(shortcut: shortcutWorks)
        return true
    }

    /// Registers ⌃⌥⌘Q again if the keyboard layout changed, and keeps the covers' line truthful.
    func followLayout() {
        guard let e = emergency, e.followLayout() else { return }
        watcher?.notice = .testing(shortcut: shortcutWorks)
    }

    /// ⌃⌥⌘Q: covers off, and the app ends at once. It does not wait for anything that
    /// could be stuck; macOS removes every window of an ended app, covers included.
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
        if let id = Bundle.main.bundleIdentifier, !id.isEmpty {
            Removal.run(bundleID: id)
        }
        NSApp.activate()
        let a = NSAlert()
        a.messageText = AppText.testingRemovedTitle
        a.informativeText = AppText.testingRemovedDetail
        a.addButton(withTitle: AppText.testingRemovedOpenSettings)
        a.addButton(withTitle: AppText.testingRemovedShowApp)
        a.addButton(withTitle: AppText.testingRemovedDone)
        switch a.runModal() {
        case .alertFirstButtonReturn: AppDelegate.openScreenRecordingSettings()
        case .alertSecondButtonReturn: NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
        default: break
        }
        // Ends without AppKit's own quitting steps, so nothing is written again after the removal.
        exit(0)
    }
}
#endif
