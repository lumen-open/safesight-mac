// SPDX-License-Identifier: Apache-2.0
// The way-out line as it is drawn: AppText.wayOutLine in the system font, with each shortcut drawn as small
// plain key caps (neutral, near-black or near-white letters), on a pill in the card colour with a hairline in
// the line colour. No ornament: no serif, no gold. One drawing serves the covers (as a layer's image) and the
// repair card (without the pill). Drawn with Core Text into a bitmap: no view, no control, nothing that can
// take a click or the keyboard.
import AppKit
import CoreGraphics
import CoreText
import QuartzCore
import SafeSightMacCore
import SafeSightMacWatcher

public enum WayOutArt {
    /// Two sizes: the regular one, and a compact one for covers too narrow for it.
    public enum Size: CaseIterable, Sendable { case regular, compact }

    /// Which line is drawn: the way out, or the Testing edition's line (with ⌃⌥⌘Q, or without it when another app
    /// holds the shortcut). Both are drawn the same way: plain words, shortcuts as key caps.
    public enum Line: Hashable, Sendable {
        case wayOut
        case testing(shortcut: Bool)

        public var text: String {
            switch self {
            case .wayOut: return AppText.wayOutLine
            case let .testing(shortcut): return AppText.testingLine(shortcut: shortcut)
            }
        }

        var pieces: [(text: String, isKey: Bool)] {
            switch self {
            case .wayOut: return AppText.wayOutPieces
            case let .testing(shortcut): return AppText.testingPieces(shortcut: shortcut)
            }
        }
    }

    struct Metrics {
        var font: CGFloat, keyFont: CGFloat
        var capHeight: CGFloat, capMinWidth: CGFloat, capRadius: CGFloat, capPad: CGFloat
        var keyGap: CGFloat, keyMargin: CGFloat
        var pillHeight: CGFloat, pillPad: CGFloat
        static func of(_ s: Size) -> Metrics {
            switch s {
            case .regular: return Metrics(font: 14, keyFont: 12.5, capHeight: 22, capMinWidth: 22, capRadius: 6, capPad: 6,
                                          keyGap: 3, keyMargin: 3, pillHeight: 46, pillPad: 22)
            case .compact: return Metrics(font: 12.5, keyFont: 11.5, capHeight: 20, capMinWidth: 20, capRadius: 5, capPad: 5,
                                          keyGap: 2.5, keyMargin: 2, pillHeight: 38, pillPad: 15)
            }
        }
    }

    /// Clear space the line keeps from its cover's edges. A cover with less room shows no line.
    public static let margin: CGFloat = 24
    /// Space around the pill in its image, for the soft shadow. Less than `margin`, so the shadow stays on the cover.
    static let shadowRoom: CGFloat = 14

    // MARK: Layout

    enum Run { case words(CTLine, CGFloat), keys([(CTLine, CGRect, CGFloat)]) }

    static func font(_ size: CGFloat, _ weight: NSFont.Weight) -> CTFont { NSFont.systemFont(ofSize: size, weight: weight) as CTFont }

    static func line(_ s: String, _ font: CTFont, _ color: CGColor) -> CTLine {
        CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        ]))
    }

    /// The runs of the line and its width, in points.
    static func runs(_ m: Metrics, _ t: CoverTheme, _ which: Line = .wayOut) -> ([Run], CGFloat) {
        let words = font(m.font, .regular), keys = font(m.keyFont, .medium)
        var out: [Run] = [], width: CGFloat = 0
        for piece in which.pieces {
            if piece.isKey {
                var caps: [(CTLine, CGRect, CGFloat)] = []
                var w = m.keyMargin
                for (i, ch) in piece.text.enumerated() {
                    let l = line(String(ch), keys, t.keyText.cg())
                    let ink = CTLineGetBoundsWithOptions(l, .useGlyphPathBounds)
                    let capW = max(m.capMinWidth, ceil(ink.width) + 2 * m.capPad)
                    caps.append((l, ink, capW))
                    w += capW + (i > 0 ? m.keyGap : 0)
                }
                w += m.keyMargin
                out.append(.keys(caps)); width += w
            } else {
                let l = line(piece.text, words, t.text.cg())
                let w = CGFloat(CTLineGetTypographicBounds(l, nil, nil, nil))
                out.append(.words(l, w)); width += w
            }
        }
        return (out, ceil(width))
    }

    /// The size of the line alone (no pill), in points.
    static func lineSize(_ s: Size, _ t: CoverTheme, _ which: Line = .wayOut) -> CGSize {
        let m = Metrics.of(s)
        return CGSize(width: runs(m, t, which).1, height: m.capHeight + 2)
    }

    /// The pill's size, in points.
    public static func pillSize(_ s: Size, _ t: CoverTheme = .light, _ which: Line = .wayOut) -> CGSize {
        let m = Metrics.of(s)
        return CGSize(width: runs(m, t, which).1 + 2 * m.pillPad, height: m.pillHeight)
    }

    // MARK: Drawing

    /// Draws the line with its vertical centre at `mid`, starting at `x`, in a context in points (y up).
    static func drawLine(_ ctx: CGContext, x: CGFloat, mid: CGFloat, _ s: Size, _ t: CoverTheme, scale: CGFloat, _ which: Line = .wayOut) {
        let m = Metrics.of(s)
        let (rs, _) = runs(m, t, which)
        let wordsFont = font(m.font, .regular)
        // Optical centre: capitals centred on the middle.
        let baseline = (mid - CTFontGetCapHeight(wordsFont) / 2)
        let px = 1 / max(scale, 1)
        var cx = x
        ctx.textMatrix = .identity
        for r in rs {
            switch r {
            case let .words(l, w):
                ctx.textPosition = CGPoint(x: cx, y: baseline)
                CTLineDraw(l, ctx)
                cx += w
            case let .keys(caps):
                cx += m.keyMargin
                for (i, (l, ink, capW)) in caps.enumerated() {
                    if i > 0 { cx += m.keyGap }
                    let cap = CGRect(x: cx, y: mid - m.capHeight / 2 + 0.5, width: capW, height: m.capHeight)
                    // A plain key: a slightly deeper edge below, the face on top, a hairline rim.
                    ctx.setFillColor(t.keyBase.cg())
                    ctx.addPath(CGPath(roundedRect: cap.offsetBy(dx: 0, dy: -1), cornerWidth: m.capRadius, cornerHeight: m.capRadius, transform: nil))
                    ctx.fillPath()
                    ctx.setFillColor(t.keyFill.cg())
                    ctx.addPath(CGPath(roundedRect: cap, cornerWidth: m.capRadius, cornerHeight: m.capRadius, transform: nil))
                    ctx.fillPath()
                    ctx.setStrokeColor(t.keyEdge.cg())
                    ctx.setLineWidth(px)
                    ctx.addPath(CGPath(roundedRect: cap.insetBy(dx: px / 2, dy: px / 2), cornerWidth: m.capRadius, cornerHeight: m.capRadius, transform: nil))
                    ctx.strokePath()
                    // The glyph, centred by its ink.
                    ctx.textPosition = CGPoint(x: cap.midX - ink.midX, y: cap.midY - ink.midY)
                    CTLineDraw(l, ctx)
                    cx += capW
                }
                cx += m.keyMargin
            }
        }
    }

    /// A bitmap context in points (y up) at `scale`.
    static func context(_ size: CGSize, scale: CGFloat) -> CGContext? {
        let w = Int(ceil(size.width * scale)), h = Int(ceil(size.height * scale))
        guard w > 0, h > 0, let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                               space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                               bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        ctx.setShouldSmoothFonts(false)
        ctx.setAllowsAntialiasing(true)
        return ctx
    }

    /// The pill with the line on it, with `shadowRoom` around it for the shadow. Size in points.
    static func renderPill(_ s: Size, _ t: CoverTheme, scale: CGFloat, _ which: Line = .wayOut) -> (CGImage, CGSize)? {
        let p = pillSize(s, t, which), m = Metrics.of(s)
        let size = CGSize(width: p.width + 2 * shadowRoom, height: p.height + 2 * shadowRoom)
        guard let ctx = context(size, scale: scale) else { return nil }
        let pill = CGRect(x: shadowRoom, y: shadowRoom, width: p.width, height: p.height)
        let shape = CGPath(roundedRect: pill, cornerWidth: p.height / 2, cornerHeight: p.height / 2, transform: nil)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -2), blur: 12, color: CGColor(gray: 0, alpha: t.shadowAlpha))
        ctx.setFillColor(t.card.cg())
        ctx.addPath(shape); ctx.fillPath()
        ctx.restoreGState()
        let px = 1 / max(scale, 1)
        ctx.setStrokeColor(t.line.cg())
        ctx.setLineWidth(px)
        ctx.addPath(CGPath(roundedRect: pill.insetBy(dx: px / 2, dy: px / 2), cornerWidth: p.height / 2 - px / 2, cornerHeight: p.height / 2 - px / 2, transform: nil))
        ctx.strokePath()
        drawLine(ctx, x: pill.minX + m.pillPad, mid: pill.midY, s, t, scale: scale, which)
        return ctx.makeImage().map { ($0, size) }
    }

    /// The line alone, for the repair card. Size in points.
    public static func lineImage(_ s: Size = .regular, theme t: CoverTheme, scale: CGFloat, line which: Line = .wayOut) -> (CGImage, CGSize)? {
        let size = lineSize(s, t, which)
        guard let ctx = context(size, scale: scale) else { return nil }
        drawLine(ctx, x: 0, mid: size.height / 2, s, t, scale: scale, which)
        return ctx.makeImage().map { ($0, size) }
    }

    // Drawn once per theme, scale and size: covers are redrawn on every frame.
    nonisolated(unsafe) static var cache: [String: (CGImage, CGSize)] = [:]
    static let cacheLock = NSLock()

    static func pill(_ s: Size, _ t: CoverTheme, scale: CGFloat, _ which: Line = .wayOut) -> (CGImage, CGSize)? {
        let key = "\(t.isDark)-\(scale)-\(s)-\(which)"
        cacheLock.lock(); defer { cacheLock.unlock() }
        if let hit = cache[key] { return hit }
        let made = renderPill(s, t, scale: scale, which)
        if let made { cache[key] = made }
        return made
    }

    // MARK: Placement

    /// Where the pill goes on a cover (same space as `host`, y up), or nil when the cover has no room for it.
    public static func pillFrame(in host: CGRect, placement: WayOutPlacement, size: CGSize, scale: CGFloat) -> CGRect? {
        guard host.width >= size.width + 2 * margin, host.height >= size.height + 2 * margin else { return nil }
        let x = host.midX - size.width / 2
        var y: CGFloat
        switch placement {
        case .centre:
            // A little above the middle reads as the middle.
            y = host.midY - size.height / 2 + min(host.height * 0.04, (host.height - size.height) / 2 - margin)
        case .belowCard:
            // About a quarter up from the bottom: below the repair card, above the Dock.
            y = max(host.minY + margin, host.minY + host.height * 0.24 - size.height / 2)
        }
        let s = max(scale, 1)
        return CGRect(x: (x * s).rounded() / s, y: (y * s).rounded() / s, width: size.width, height: size.height)
    }

    /// The way-out layer for a cover piece, or nil when the piece has no room for the line.
    static func layer(on frame: CGRect, placement: WayOutPlacement, theme t: CoverTheme, scale: CGFloat) -> WayOutLayer? {
        for s in Size.allCases {
            guard let at = pillFrame(in: frame, placement: placement, size: pillSize(s, t), scale: scale),
                  let (img, size) = pill(s, t, scale: scale) else { continue }
            let l = WayOutLayer()
            l.frame = CGRect(x: at.minX - shadowRoom, y: at.minY - shadowRoom, width: size.width, height: size.height)
            l.contents = img
            l.contentsScale = scale
            l.contentsGravity = .resize
            l.size = s
            return l
        }
        return nil
    }
}

extension WayOutArt {
    /// Space between the way-out pill and the Testing line's pill under it.
    public static let lineGap: CGFloat = 8

    /// Where the Testing line's pill goes on a cover (same space as `host`, y up): just under the way-out pill when
    /// there is one (`under`, the pill's own frame), else where the way-out pill would go; nil without room.
    public static func testingPillFrame(in host: CGRect, placement: WayOutPlacement, under: CGRect?, size: CGSize,
                                        scale: CGFloat) -> CGRect? {
        guard let w = under else { return pillFrame(in: host, placement: placement, size: size, scale: scale) }
        guard host.width >= size.width + 2 * margin else { return nil }
        let x = host.midX - size.width / 2
        // Below the way-out pill, or above it when there is no room below.
        let below = w.minY - lineGap - size.height, above = w.maxY + lineGap
        let y: CGFloat
        if below >= host.minY + margin { y = below }
        else if above + size.height <= host.maxY - margin { y = above }
        else { return nil }
        let s = max(scale, 1)
        return CGRect(x: (x * s).rounded() / s, y: (y * s).rounded() / s, width: size.width, height: size.height)
    }

    /// The Testing line's layer for a cover piece, or nil without room. `under` is the way-out layer on the same
    /// piece, if it has one.
    static func testingLayer(on frame: CGRect, placement: WayOutPlacement, under: WayOutLayer?, shortcut: Bool,
                             theme t: CoverTheme, scale: CGFloat) -> TestingLineLayer? {
        let which = Line.testing(shortcut: shortcut)
        let wayPill = under.map { $0.frame.insetBy(dx: shadowRoom, dy: shadowRoom) }
        for s in Size.allCases {
            guard let at = testingPillFrame(in: frame, placement: placement, under: wayPill, size: pillSize(s, t, which), scale: scale),
                  let (img, size) = pill(s, t, scale: scale, which) else { continue }
            let l = TestingLineLayer()
            l.frame = CGRect(x: at.minX - shadowRoom, y: at.minY - shadowRoom, width: size.width, height: size.height)
            l.contents = img
            l.contentsScale = scale
            l.contentsGravity = .resize
            l.size = s
            l.text = which.text
            return l
        }
        return nil
    }
}

/// The Testing edition's line on a cover: an image only, never a control. `text` is what it says.
public final class TestingLineLayer: CALayer {
    public internal(set) var text = AppText.testingLine
    public internal(set) var size: WayOutArt.Size = .regular
    override init() { super.init(); name = "testing-line" }
    override init(layer: Any) {
        super.init(layer: layer)
        if let o = layer as? TestingLineLayer { text = o.text; size = o.size }
    }
    required init?(coder: NSCoder) { fatalError("not used") }
}

/// The way-out line on a cover: an image only, never a control. `text` is what it says.
public final class WayOutLayer: CALayer {
    public let text = AppText.wayOutLine
    public internal(set) var size: WayOutArt.Size = .regular
    override init() { super.init(); name = "way-out" }
    override init(layer: Any) {
        super.init(layer: layer)
        if let o = layer as? WayOutLayer { size = o.size }
    }
    required init?(coder: NSCoder) { fatalError("not used") }
}
