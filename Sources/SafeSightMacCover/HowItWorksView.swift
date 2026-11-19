// SPDX-License-Identifier: Apache-2.0
// The content of the "How it works" window: plain words, then the honest promise in its own panel. Built from
// views alone (no window), so the lab harness can draw it offscreen. Its colours follow the appearance while
// the window is open. Draws no picture.
import AppKit
import SafeSightMacCore

@MainActor
public enum HowItWorksView {
    public static let width: CGFloat = 540
    static let pad: CGFloat = 32
    /// The promise panel: an arch rising this far over its walls, corners, and the gold hairline's inset.
    static let arch: CGFloat = 92, corner: CGFloat = 14, goldInset: CGFloat = 8

    /// A top-down view, sized to its content.
    final class Page: NSView {
        override var isFlipped: Bool { true }
    }

    /// The promise's panel: a niche of whitewash with a stone edge and a gold hairline inside it, as on the website.
    final class PromisePanel: NSView {
        override var isFlipped: Bool { true }
        override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
        override func draw(_ dirty: CGRect) {
            guard let ctx = NSGraphicsContext.current?.cgContext else { return }
            let t = CoverTheme.forAppearance(effectiveAppearance)
            let edge = bounds.insetBy(dx: 0.5, dy: 0.5)
            let v = HowItWorksView.self
            ctx.addPath(Niche.path(edge, arch: v.arch, corner: v.corner, topAtMinY: true))
            ctx.setFillColor(t.card.cg()); ctx.setStrokeColor(t.line.cg()); ctx.setLineWidth(1)
            ctx.drawPath(using: .fillStroke)
            let i = v.goldInset + 0.5
            ctx.addPath(Niche.path(bounds.insetBy(dx: i, dy: i), arch: v.arch - v.goldInset, corner: v.corner - v.goldInset, topAtMinY: true))
            ctx.setStrokeColor(t.gold.cg(t.goldLineAlpha))
            ctx.strokePath()
        }
    }

    static func text(_ s: String, font: NSFont, color: KeyPath<CoverTheme, CoverTheme.RGB>, width: CGFloat,
                     lineHeight: CGFloat = 1.18, kern: CGFloat = 0, align: NSTextAlignment = .natural) -> NSTextField {
        let style = NSMutableParagraphStyle()
        style.lineHeightMultiple = lineHeight
        style.alignment = align
        let f = NSTextField(wrappingLabelWithString: s)
        f.font = font
        f.attributedStringValue = NSAttributedString(string: s, attributes: [
            .font: font, .foregroundColor: CoverTheme.dynamic(color), .paragraphStyle: style, .kern: kern,
        ])
        f.isSelectable = true
        f.drawsBackground = false
        f.preferredMaxLayoutWidth = width
        f.frame.size = CGSize(width: width, height: ceil(f.fittingSize.height))
        return f
    }

    public static func make() -> NSView {
        let inner = width - 2 * pad
        let page = Page(frame: CGRect(x: 0, y: 0, width: width, height: 100))
        var y: CGFloat = 16
        for p in AppText.howItWorksBody {
            let l = text(p, font: CoverTheme.body(13), color: \.text, width: inner)
            l.frame.origin = CGPoint(x: pad - 2, y: y)   // a label draws its text 2 points in
            page.addSubview(l)
            y += l.frame.height + 10
        }

        y += 14
        let panelPad: CGFloat = 26, panelInner = inner - 2 * panelPad
        let panel = PromisePanel(frame: CGRect(x: pad, y: y, width: inner, height: 100))
        var py = arch * 0.5 + 16
        let heading = text("The honest promise", font: CoverTheme.heading(17), color: \.text, width: panelInner,
                           lineHeight: 1, kern: CoverTheme.headingKern(17), align: .center)
        heading.frame.origin = CGPoint(x: panelPad - 2, y: py)
        panel.addSubview(heading)
        py += heading.frame.height + 12
        let promise = text(AppText.honestPromise, font: CoverTheme.heading(14.5, weight: .regular), color: \.text,
                           width: panelInner, lineHeight: 1.28, kern: CoverTheme.headingKern(14.5))
        promise.frame.origin = CGPoint(x: panelPad - 2, y: py)
        panel.addSubview(promise)
        py += promise.frame.height + panelPad
        panel.frame.size.height = ceil(py)
        page.addSubview(panel)
        y += panel.frame.height + pad

        page.frame.size.height = ceil(y)
        return page
    }
}
