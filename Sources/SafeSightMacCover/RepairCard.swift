// SPDX-License-Identifier: Apache-2.0
// The repair card: shown above the covers whenever a display is covered whole, so the owner can
// always see what happened and reach Try again, Pause (practice state only) and Quit. A whole-display
// cover is never a locked screen. The card holds no word about screen content. It repeats the way out:
// the keyboard shortcuts that still reach the app underneath.
//
// The card never takes the keyboard on its own: it is a non-activating panel that becomes key only if a
// view needs typing (none does), so ⌘W and ⌘[ keep going to the app underneath even after a click on it.
import AppKit
import SafeSightMacCore
import SafeSightMacWatcher

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

    private(set) var panel: RepairPanel?
    private var actions: Actions?
    private var shown: (cause: FaultCause, pause: Bool, dark: Bool)?
    public init() {}

    /// Shows the card for the given causes, or hides it when there are none.
    public func show(causes: [FaultCause], actions: Actions) {
        self.actions = actions
        guard let first = causes.first else { hide(); return }
        let theme = CoverTheme.current
        let p = panel ?? RepairPanel.make()
        panel = p
        target.card = self
        if shown.map({ $0.cause != first || $0.pause != (actions.pause != nil) || $0.dark != theme.isDark }) ?? true {
            let v = RepairCardView.make(cause: first, pause: actions.pause != nil, theme: theme, target: target,
                                        tryAgain: #selector(Target.tryAgain), pause: #selector(Target.pause), quit: #selector(Target.quit))
            p.appearance = NSAppearance(named: theme.isDark ? .darkAqua : .aqua)
            p.backgroundColor = NSColor(cgColor: theme.card.cg())
            p.contentView = v
            p.setContentSize(v.frame.size)
            shown = (first, actions.pause != nil, theme.isDark)
        }
        // Centred on the main display when it appears; after that the owner may move it.
        if !p.isVisible, let screen = NSScreen.main {
            let f = screen.visibleFrame
            p.setFrameOrigin(CGPoint(x: f.midX - p.frame.width / 2, y: f.midY - p.frame.height / 2))
        }
        p.orderFrontRegardless()
    }

    public func hide() { panel?.orderOut(nil) }

    private let target = Target()
    @objc final class Target: NSObject {
        weak var card: RepairCard?
        @MainActor @objc func tryAgain() { card?.actions?.tryAgain() }
        @MainActor @objc func pause() { card?.actions?.pause?() }
        @MainActor @objc func quit() { card?.actions?.quit() }
    }
}

/// The card's panel: above the covers, on every Space, never main, key only if a view needs typing.
final class RepairPanel: NSPanel {
    override var canBecomeMain: Bool { false }

    static func make() -> RepairPanel {
        let p = RepairPanel(contentRect: CGRect(x: 0, y: 0, width: RepairCardView.width, height: 300),
                            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel], backing: .buffered, defer: false)
        p.title = "SafeSight Mac"
        p.titleVisibility = .hidden
        p.titlebarAppearsTransparent = true
        for b in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] { p.standardWindowButton(b)?.isHidden = true }
        p.isMovableByWindowBackground = true
        p.becomesKeyOnlyIfNeeded = true
        p.level = CoverLevels.appAbove
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        p.isReleasedWhenClosed = false
        p.hidesOnDeactivate = false
        return p
    }
}

/// The card's content, built from views alone (no window), so the lab harness can draw it offscreen.
@MainActor
public enum RepairCardView {
    public static let width: CGFloat = 440
    static let pad: CGFloat = 28

    /// A top-down view that paints the card, its mark and its divider.
    final class Card: NSView {
        let theme: CoverTheme
        var divider: CGFloat = 0
        init(frame: CGRect, theme: CoverTheme) { self.theme = theme; super.init(frame: frame) }
        required init?(coder: NSCoder) { fatalError("not used") }
        override var isFlipped: Bool { true }
        override func draw(_ dirty: CGRect) {
            guard let ctx = NSGraphicsContext.current?.cgContext else { return }
            ctx.setFillColor(theme.card.cg()); ctx.fill(bounds)
            // The mark: a soft teal tile behind the app's symbol.
            let mark = CGRect(x: RepairCardView.pad, y: RepairCardView.pad, width: 36, height: 36)
            ctx.setFillColor(theme.softAccent.cg())
            ctx.addPath(CGPath(roundedRect: mark, cornerWidth: 10, cornerHeight: 10, transform: nil)); ctx.fillPath()
            ctx.setFillColor(theme.line.cg())
            ctx.fill(CGRect(x: RepairCardView.pad, y: divider, width: bounds.width - 2 * RepairCardView.pad, height: 1))
        }
    }

    static func label(_ s: String, _ font: NSFont, _ color: CoverTheme.RGB, width: CGFloat) -> NSTextField {
        let f = NSTextField(wrappingLabelWithString: s)
        f.font = font
        f.textColor = NSColor(cgColor: color.cg())
        f.isSelectable = false
        f.drawsBackground = false
        f.preferredMaxLayoutWidth = width
        f.frame.size = CGSize(width: width, height: ceil(f.fittingSize.height))
        return f
    }

    public static func make(cause: FaultCause, pause: Bool, theme t: CoverTheme, target: AnyObject?,
                            tryAgain: Selector?, pause pauseAction: Selector?, quit: Selector?) -> NSView {
        let inner = width - 2 * pad
        let card = Card(frame: CGRect(x: 0, y: 0, width: width, height: 100), theme: t)
        card.setAccessibilityLabel("SafeSight Mac")
        var y = pad

        let symbol = NSImageView(frame: CGRect(x: pad + 8, y: y + 8, width: 20, height: 20))
        symbol.image = NSImage(systemSymbolName: "rectangle.dashed", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 15, weight: .semibold))
        symbol.contentTintColor = NSColor(cgColor: t.accent.cg())
        card.addSubview(symbol)
        y += 36 + 16

        for (text, font, color, gap) in [
            (AppText.repairHeading, NSFont.systemFont(ofSize: 15, weight: .semibold), t.text, CGFloat(6)),
            (cause.plainWords, NSFont.systemFont(ofSize: 13), t.text, CGFloat(10)),
            (AppText.repairDetail, NSFont.systemFont(ofSize: 12), t.muted, CGFloat(18)),
        ] {
            let l = label(text, font, color, width: inner)
            l.frame.origin = CGPoint(x: pad - 2, y: y)   // a label draws its text 2 points in
            card.addSubview(l)
            y += l.frame.height + gap
        }

        card.divider = y
        y += 1 + 18
        // The way out, as on the covers: words and key caps. Read aloud as the plain sentence.
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        if let (img, size) = WayOutArt.lineImage(.regular, theme: t, scale: scale) ?? WayOutArt.lineImage(.compact, theme: t, scale: scale) {
            let hint = NSImageView(frame: CGRect(x: pad, y: y, width: min(size.width, inner), height: size.height))
            hint.image = NSImage(cgImage: img, size: size)
            hint.imageScaling = .scaleProportionallyDown
            hint.setAccessibilityLabel(AppText.wayOutLine)
            card.addSubview(hint)
            y += size.height + 22
        }

        // Buttons, right-aligned: Quit, Pause (practice state only), Try again.
        var specs: [(String, Selector?, Bool)] = [(AppText.repairQuit, quit, false)]
        if pause { specs.append((AppText.repairPause, pauseAction, false)) }
        specs.append((AppText.repairTryAgain, tryAgain, true))
        var x = width - pad
        for (title, action, main) in specs.reversed() {
            let b = NSButton(title: title, target: target, action: action)
            b.bezelStyle = .push
            b.controlSize = .large
            b.font = .systemFont(ofSize: 13, weight: main ? .medium : .regular)
            if main { b.bezelColor = NSColor(cgColor: t.accent.cg()) }
            // A click never makes the card key, so the keyboard stays with the app underneath.
            b.refusesFirstResponder = true
            b.sizeToFit()
            b.frame.size.width = max(b.frame.width + 8, 84)
            x -= b.frame.width
            b.frame.origin = CGPoint(x: x, y: y)
            card.addSubview(b)
            x -= 8
        }
        y += 32 + pad - 4
        card.frame.size.height = ceil(y)
        return card
    }
}
