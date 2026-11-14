// SPDX-License-Identifier: Apache-2.0
// The repair card: shown above the covers whenever a display is covered whole, so the owner can
// always see what happened and reach Try again, Pause (practice state only) and Quit. A whole-display
// cover is never a locked screen. The card holds no word about screen content.
import AppKit
import FernwickWatcher

@MainActor
public final class RepairCard {
    public struct Actions {
        public var tryAgain: () -> Void
        public var pause: (() -> Void)?
        public var quit: () -> Void
        public init(tryAgain: @escaping () -> Void, pause: (() -> Void)?, quit: @escaping () -> Void) {
            self.tryAgain = tryAgain; self.pause = pause; self.quit = quit
        }
    }

    private var panel: NSPanel?
    private let label = NSTextField(wrappingLabelWithString: "")
    private var actions: Actions?
    public init() {}

    /// Shows the card for the given causes, or hides it when there are none.
    public func show(causes: [FaultCause], actions: Actions) {
        self.actions = actions
        guard let first = causes.first else { hide(); return }
        let p = panel ?? makePanel()
        panel = p
        label.stringValue = "Fernwick Open is covering a display.\n\n" + first.plainWords
            + "\n\nWhile it is covered you cannot see other apps on it. Nothing is locked, and nobody is told."
        rebuildButtons(in: p)
        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            p.setFrameOrigin(CGPoint(x: f.midX - p.frame.width / 2, y: f.midY - p.frame.height / 2))
        }
        p.orderFrontRegardless()
    }

    public func hide() { panel?.orderOut(nil) }

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 420, height: 210), styleMask: [.titled, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.title = "Fernwick Open"
        p.level = CoverLevels.appAbove
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        p.isReleasedWhenClosed = false
        p.hidesOnDeactivate = false
        label.frame = CGRect(x: 20, y: 60, width: 380, height: 130)
        p.contentView?.addSubview(label)
        return p
    }

    private var buttons: [NSButton] = []
    private func rebuildButtons(in p: NSPanel) {
        buttons.forEach { $0.removeFromSuperview() }
        var specs: [(String, Selector)] = [("Try again", #selector(Target.tryAgain)), ("Quit", #selector(Target.quit))]
        if actions?.pause != nil { specs.insert(("Pause", #selector(Target.pause)), at: 1) }
        target.card = self
        buttons = specs.enumerated().map { i, s in
            let b = NSButton(title: s.0, target: target, action: s.1)
            b.frame = CGRect(x: 20 + CGFloat(i) * 128, y: 16, width: 120, height: 32)
            p.contentView?.addSubview(b)
            return b
        }
    }

    private let target = Target()
    @objc final class Target: NSObject {
        weak var card: RepairCard?
        @MainActor @objc func tryAgain() { card?.actions?.tryAgain() }
        @MainActor @objc func pause() { card?.actions?.pause?() }
        @MainActor @objc func quit() { card?.actions?.quit() }
    }
}
