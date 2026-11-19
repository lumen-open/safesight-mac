// SPDX-License-Identifier: Apache-2.0
// The repair card: shown above the covers whenever a display is covered whole, so the owner can
// always see what happened and reach Try again, Pause (practice state only) and Quit. A whole-display
// cover is never a locked screen. The card holds no word about screen content. It repeats the way out:
// the keyboard shortcuts that still reach the app underneath.
//
// The card never takes the keyboard on its own: it is a non-activating panel that becomes key only if a
// view needs typing (none does), so ⌘W and ⌘[ keep going to the app underneath even after a click on it.
//
// It sits on a display that is covered whole, never on one the owner is working on: with a third display
// covered for good (DISPLAYS_MAX is 2), a card in the middle of the main display would never go away (found in
// the Testing edition's safety pass). In the Testing edition it also carries the edition's line, with ⌃⌥⌘Q.
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
    private var shown: (cause: FaultCause, pause: Bool, dark: Bool, notice: CoverNotice?)?
    private var placedOn: UInt32?
    /// The Testing edition's line, under the way out; nil in the release edition.
    public var notice: CoverNotice?
    public init() {}

    /// Which display the card goes on: the main display when it is covered whole, else the first display that is
    /// (in `covered` order), else nil (the main display). Never a display that is not covered whole.
    public static func display(covered: [UInt32], main: UInt32) -> UInt32? {
        covered.contains(main) ? main : covered.first
    }

    /// Shows the card for the given causes, or hides it when there are none. `display` is the display it sits on:
    /// one covered whole (`display(covered:main:)`); the main display when nil.
    public func show(causes: [FaultCause], actions: Actions, on display: UInt32? = nil) {
        self.actions = actions
        guard let first = causes.first else { hide(); return }
        let theme = CoverTheme.current
        let p = panel ?? RepairPanel.make()
        panel = p
        target.card = self
        if shown.map({ $0.cause != first || $0.pause != (actions.pause != nil) || $0.dark != theme.isDark || $0.notice != notice }) ?? true {
            let v = RepairCardView.make(cause: first, pause: actions.pause != nil, theme: theme, target: target,
                                        tryAgain: #selector(Target.tryAgain), pause: #selector(Target.pause), quit: #selector(Target.quit),
                                        notice: notice)
            p.appearance = NSAppearance(named: theme.isDark ? .darkAqua : .aqua)
            p.backgroundColor = NSColor(cgColor: theme.card.cg())
            p.contentView = v
            p.setContentSize(v.frame.size)
            shown = (first, actions.pause != nil, theme.isDark, notice)
        }
        // Centred on its display when it appears or its display changes; after that the owner may move it.
        if !p.isVisible || placedOn != display, let screen = display.flatMap(CoverCanvas.screen) ?? NSScreen.main {
            let f = screen.visibleFrame
            p.setFrameOrigin(CGPoint(x: f.midX - p.frame.width / 2, y: f.midY - p.frame.height / 2))
            placedOn = display
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
        p.title = AppText.productName
        p.titleVisibility = .hidden
        p.titlebarAppearsTransparent = true
        for b in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] { p.standardWindowButton(b)?.isHidden = true }
        p.isMovableByWindowBackground = true
        p.becomesKeyOnlyIfNeeded = true
        p.level = CoverLevels.appAbove
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        p.isReleasedWhenClosed = false
        p.hidesOnDeactivate = false
        p.isRestorable = false
        return p
    }
}

/// The card's content, built from views alone (no window), so the lab harness can draw it offscreen.
@MainActor
public enum RepairCardView {
    public static let width: CGFloat = 440
    static let pad: CGFloat = 28
    /// The mark: a small niche, 36 by 40 points.
    static let mark = CGSize(width: 36, height: 40)
    /// The gold hairline sits this far inside the card's edge, its corners concentric with the panel's.
    static let goldInset: CGFloat = 6
    /// The panel's corner radius as the lab harness draws it (the real panel's corners are the system's).
    nonisolated public static let panelCorner: CGFloat = 16

    /// A top-down view that paints the card, its gold hairline, its mark and its divider.
    final class Card: NSView {
        let theme: CoverTheme
        var divider: CGFloat = 0
        init(frame: CGRect, theme: CoverTheme) { self.theme = theme; super.init(frame: frame) }
        required init?(coder: NSCoder) { fatalError("not used") }
        override var isFlipped: Bool { true }
        override func draw(_ dirty: CGRect) {
            guard let ctx = NSGraphicsContext.current?.cgContext else { return }
            let t = theme, pad = RepairCardView.pad
            ctx.setFillColor(t.card.cg()); ctx.fill(bounds)
            // Gold leaf: one hairline just inside the edge. It carries no meaning and no words.
            let i = RepairCardView.goldInset + 0.5, r = RepairCardView.panelCorner - i
            ctx.setStrokeColor(t.gold.cg(t.goldLineAlpha)); ctx.setLineWidth(1)
            ctx.addPath(CGPath(roundedRect: bounds.insetBy(dx: i, dy: i), cornerWidth: r, cornerHeight: r, transform: nil)); ctx.strokePath()
            // The mark: the app's symbol in a small niche of malachite wash.
            ctx.setFillColor(t.softAccent.cg())
            ctx.addPath(Niche.path(CGRect(origin: CGPoint(x: pad, y: pad), size: RepairCardView.mark),
                                   arch: RepairCardView.mark.width / 2, corner: 9, topAtMinY: true)); ctx.fillPath()
            ctx.setFillColor(t.line.cg())
            ctx.fill(CGRect(x: pad, y: divider, width: bounds.width - 2 * pad, height: 1))
        }
    }

    static func label(_ s: String, _ font: NSFont, _ color: CoverTheme.RGB, width: CGFloat, kern: CGFloat = 0) -> NSTextField {
        let f = NSTextField(wrappingLabelWithString: s)
        f.font = font
        f.attributedStringValue = NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color.ns(), .kern: kern])
        f.isSelectable = false
        f.drawsBackground = false
        f.preferredMaxLayoutWidth = width
        f.frame.size = CGSize(width: width, height: ceil(f.fittingSize.height))
        return f
    }

    public static func make(cause: FaultCause, pause: Bool, theme t: CoverTheme, target: AnyObject?,
                            tryAgain: Selector?, pause pauseAction: Selector?, quit: Selector?,
                            notice: CoverNotice? = nil) -> NSView {
        let inner = width - 2 * pad
        let card = Card(frame: CGRect(x: 0, y: 0, width: width, height: 100), theme: t)
        card.setAccessibilityLabel(AppText.productName)
        var y = pad

        // The symbol sits a little low in the niche, centred under the arch.
        let symbol = NSImageView(frame: CGRect(x: pad + (mark.width - 20) / 2, y: y + 12, width: 20, height: 20))
        symbol.image = NSImage(systemSymbolName: "rectangle.dashed", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 15, weight: .semibold))
        symbol.contentTintColor = t.accentText.ns()
        card.addSubview(symbol)
        y += mark.height + 16

        for (text, font, color, gap, kern) in [
            (AppText.repairHeading, CoverTheme.heading(18), t.text, CGFloat(6), CoverTheme.headingKern(18)),
            (cause.plainWords, CoverTheme.body(13), t.text, CGFloat(10), CGFloat(0)),
            (AppText.repairDetail, CoverTheme.body(12), t.muted, CGFloat(18), CGFloat(0)),
        ] {
            let l = label(text, font, color, width: inner, kern: kern)
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

        // The Testing edition's line, just under the way out and drawn the same way. Read aloud as its sentence.
        if case let .testing(shortcut)? = notice {
            let which = WayOutArt.Line.testing(shortcut: shortcut)
            let regular = WayOutArt.lineImage(.regular, theme: t, scale: scale, line: which)
            let fits = regular.map { $0.1.width <= inner } ?? false
            if let (img, size) = fits ? regular : WayOutArt.lineImage(.compact, theme: t, scale: scale, line: which) {
                let top = y - 12
                let line = NSImageView(frame: CGRect(x: pad, y: top, width: min(size.width, inner), height: size.height))
                line.image = NSImage(cgImage: img, size: size)
                line.imageScaling = .scaleProportionallyDown
                line.setAccessibilityLabel(which.text)
                card.addSubview(line)
                y = top + size.height + 22
            }
        }

        // Buttons, right-aligned: Quit, Pause (practice state only), Try again. Native push buttons; Try again
        // is malachite with its own ink.
        var specs: [(String, Selector?, Bool)] = [(AppText.repairQuit, quit, false)]
        if pause { specs.append((AppText.repairPause, pauseAction, false)) }
        specs.append((AppText.repairTryAgain, tryAgain, true))
        var x = width - pad
        for (title, action, main) in specs.reversed() {
            let b = NSButton(title: title, target: target, action: action)
            b.bezelStyle = .push
            b.controlSize = .large
            b.font = CoverTheme.body(13, weight: main ? .medium : .regular)
            if main {
                b.bezelColor = t.accent.ns()
                b.attributedTitle = NSAttributedString(string: title, attributes: [
                    .font: CoverTheme.body(13, weight: .medium), .foregroundColor: t.onAccent.ns(), .paragraphStyle: centred,
                ])
            }
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

    static var centred: NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.alignment = .center
        return p
    }
}
