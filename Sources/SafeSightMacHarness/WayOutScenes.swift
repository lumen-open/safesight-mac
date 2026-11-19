// SPDX-License-Identifier: Apache-2.0
// LAB ONLY. Synthetic desktops for looking at the way out: a browser-like window drawn from plain shapes
// (title bar, tabs, toolbar, a page of grey bars), a menu bar and a Dock, and the lab stand-in (a synthetic
// magenta-and-green checker) to force the covers. The real pipeline judges each frame with null models;
// only the stand-in covers. Each scene is written as a PNG with the cover layer's own layers drawn on it, and
// one more shows the "How it works" window drawn from its own views.
// Harmless shapes only; nothing is captured from the screen.
#if SAFESIGHTMAC_LAB
import AppKit
import CoreGraphics
import DetectorCore
import Foundation
import LabStandIn
import Preprocess
import SafeSightMacCore
import SafeSightMacCover
import SafeSightMacWatcher

enum WayOutScenes {
    static let scale: CGFloat = 2
    static let size = CGSize(width: 1280, height: 800)
    static let menuBar: CGFloat = 24

    struct Palette {
        var wallTop, wallBottom, menuBar, menuInk, dock, dockEdge, tabs, tool, field, page, ink, faint, line: CGColor
        static func of(_ dark: Bool) -> Palette {
            func c(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor { CoverTheme.RGB(hex).cg(a) }
            return dark
                ? Palette(wallTop: c(0x26303D), wallBottom: c(0x10161D), menuBar: c(0x1B2129, 0.92), menuInk: c(0xD6DCE2),
                          dock: c(0x2A3039, 0.85), dockEdge: c(0x454D58), tabs: c(0x1F2023), tool: c(0x2C2D31), field: c(0x1E1F22),
                          page: c(0x18191B), ink: c(0xC9CDD2), faint: c(0x6B7078), line: c(0x3A3B40))
                : Palette(wallTop: c(0xB9CAD6), wallBottom: c(0xE3EAEF), menuBar: c(0xF4F6F8, 0.88), menuInk: c(0x30343A),
                          dock: c(0xF2F4F6, 0.72), dockEdge: c(0xD2D7DD), tabs: c(0xE4E5E8), tool: c(0xF6F6F7), field: c(0xE9EAEC),
                          page: c(0xFFFFFF), ink: c(0x3C4047), faint: c(0xB4B8BE), line: c(0xD5D7DB))
        }
    }

    /// Draws in screen points (origin top-left, y down) into an opaque RGBA frame at `scale`.
    static func frame(_ body: (CGContext) -> Void) -> RGBAImage {
        let w = Int(size.width * scale), h = Int(size.height * scale)
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.translateBy(x: 0, y: CGFloat(h)); ctx.scaleBy(x: scale, y: -scale)
        body(ctx)
        let data = ctx.data!.bindMemory(to: UInt8.self, capacity: w * h * 4)
        var px = Array(UnsafeBufferPointer(start: data, count: w * h * 4))
        for i in stride(from: 3, to: px.count, by: 4) { px[i] = 255 }
        return RGBAImage(width: w, height: h, pixels: px)
    }

    static func rr(_ ctx: CGContext, _ r: CGRect, _ radius: CGFloat, _ c: CGColor) {
        ctx.setFillColor(c); ctx.addPath(CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)); ctx.fillPath()
    }

    static func bar(_ ctx: CGContext, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ c: CGColor) { rr(ctx, CGRect(x: x, y: y, width: w, height: h), h / 2, c) }

    /// Wallpaper, menu bar and (on the main display) the Dock.
    static func desktop(_ ctx: CGContext, _ p: Palette, dock withDock: Bool = true) {
        let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [p.wallTop, p.wallBottom] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(g, start: .zero, end: CGPoint(x: size.width * 0.3, y: size.height), options: [.drawsAfterEndLocation])
        ctx.setFillColor(p.menuBar); ctx.fill(CGRect(x: 0, y: 0, width: size.width, height: menuBar))
        rr(ctx, CGRect(x: 18, y: 6, width: 12, height: 12), 3, p.menuInk)
        var x: CGFloat = 46
        for (i, w) in [52, 30, 34, 40, 48, 54, 34].enumerated() {
            bar(ctx, x, 9, CGFloat(w), 6, i == 0 ? p.menuInk : p.menuInk.copy(alpha: 0.75)!); x += CGFloat(w) + 18
        }
        for (i, w) in [14, 14, 16, 14, 64].enumerated() { bar(ctx, size.width - 230 + CGFloat(i) * 34 + (i == 4 ? 10 : 0), 9, CGFloat(w), 6, p.menuInk.copy(alpha: 0.8)!) }
        guard withDock else { return }
        let icons: [UInt32] = [0x4A90D9, 0xF2A33A, 0x6E8FA8, 0xE8C547, 0x5B6CD6, 0xD9694A, 0x7FA9B8, 0x9AA3AD, 0x3D9DA8]
        let dw = CGFloat(icons.count) * 48 + CGFloat(icons.count - 1) * 8 + 20
        let dock = CGRect(x: (size.width - dw) / 2, y: size.height - 74, width: dw, height: 66)
        rr(ctx, dock, 20, p.dock)
        ctx.setStrokeColor(p.dockEdge); ctx.setLineWidth(0.5)
        ctx.addPath(CGPath(roundedRect: dock, cornerWidth: 20, cornerHeight: 20, transform: nil)); ctx.strokePath()
        for (i, c) in icons.enumerated() { rr(ctx, CGRect(x: dock.minX + 10 + CGFloat(i) * 56, y: dock.minY + 9, width: 48, height: 48), 11, CoverTheme.RGB(c).cg()) }
    }

    /// A browser-like window: tab strip, toolbar (back, forward, reload, address field) and a page of grey bars.
    /// The chrome is 84 points tall.
    static func browser(_ ctx: CGContext, _ wr: CGRect, _ p: Palette) {
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 10), blur: 30, color: CGColor(gray: 0, alpha: 0.28))
        rr(ctx, wr, 10, p.page)
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addPath(CGPath(roundedRect: wr, cornerWidth: 10, cornerHeight: 10, transform: nil)); ctx.clip()
        ctx.setFillColor(p.tabs); ctx.fill(CGRect(x: wr.minX, y: wr.minY, width: wr.width, height: 40))
        ctx.setFillColor(p.tool); ctx.fill(CGRect(x: wr.minX, y: wr.minY + 40, width: wr.width, height: 44))
        ctx.setFillColor(p.line); ctx.fill(CGRect(x: wr.minX, y: wr.minY + 84, width: wr.width, height: 1))
        for (i, c) in [0xFF5F57, 0xFEBC2E, 0x28C840].enumerated() {
            ctx.setFillColor(CoverTheme.RGB(UInt32(c)).cg()); ctx.fillEllipse(in: CGRect(x: wr.minX + 14 + CGFloat(i) * 20, y: wr.minY + 14, width: 12, height: 12))
        }
        // Tabs: the active one joins the toolbar.
        let tabW = min(220, (wr.width - 140) / 2)
        rr(ctx, CGRect(x: wr.minX + 84, y: wr.minY + 6, width: tabW, height: 42), 8, p.tool)
        rr(ctx, CGRect(x: wr.minX + 96, y: wr.minY + 16, width: 16, height: 16), 4, CoverTheme.RGB(0x6E8FA8).cg())
        bar(ctx, wr.minX + 120, wr.minY + 21, tabW * 0.5, 7, p.ink)
        ctx.setStrokeColor(p.faint); ctx.setLineWidth(1.5)
        let cx = wr.minX + 84 + tabW - 20
        ctx.move(to: CGPoint(x: cx - 4, y: wr.minY + 20)); ctx.addLine(to: CGPoint(x: cx + 4, y: wr.minY + 28))
        ctx.move(to: CGPoint(x: cx + 4, y: wr.minY + 20)); ctx.addLine(to: CGPoint(x: cx - 4, y: wr.minY + 28)); ctx.strokePath()
        bar(ctx, wr.minX + 84 + tabW + 36, wr.minY + 21, tabW * 0.45, 7, p.faint)
        ctx.setStrokeColor(p.faint); ctx.setLineWidth(1.5)
        let px = wr.minX + 84 + 2 * tabW + 22
        ctx.move(to: CGPoint(x: px - 5, y: wr.minY + 24)); ctx.addLine(to: CGPoint(x: px + 5, y: wr.minY + 24))
        ctx.move(to: CGPoint(x: px, y: wr.minY + 19)); ctx.addLine(to: CGPoint(x: px, y: wr.minY + 29)); ctx.strokePath()
        // Toolbar: back, forward, reload, the address field.
        ctx.setStrokeColor(p.ink); ctx.setLineWidth(2); ctx.setLineCap(.round); ctx.setLineJoin(.round)
        let ty = wr.minY + 62
        ctx.move(to: CGPoint(x: wr.minX + 26, y: ty - 7)); ctx.addLine(to: CGPoint(x: wr.minX + 19, y: ty)); ctx.addLine(to: CGPoint(x: wr.minX + 26, y: ty + 7)); ctx.strokePath()
        ctx.setStrokeColor(p.faint)
        ctx.move(to: CGPoint(x: wr.minX + 48, y: ty - 7)); ctx.addLine(to: CGPoint(x: wr.minX + 55, y: ty)); ctx.addLine(to: CGPoint(x: wr.minX + 48, y: ty + 7)); ctx.strokePath()
        ctx.setStrokeColor(p.ink)
        ctx.addArc(center: CGPoint(x: wr.minX + 82, y: ty), radius: 6.5, startAngle: 0.6, endAngle: 5.6, clockwise: false); ctx.strokePath()
        let field = CGRect(x: wr.minX + 108, y: wr.minY + 49, width: wr.width - 216, height: 26)
        rr(ctx, field, 13, p.field)
        bar(ctx, field.minX + 16, field.midY - 3.5, min(220, field.width * 0.45), 7, p.faint)
        for i in 0..<2 { rr(ctx, CGRect(x: wr.maxX - 92 + CGFloat(i) * 30, y: ty - 8, width: 16, height: 16), 4, p.faint) }
        // The page: a heading, paragraphs and two neutral "photos".
        var y = wr.minY + 120
        bar(ctx, wr.minX + 48, y, min(380, wr.width * 0.5), 14, p.ink); y += 36
        while y < wr.maxY - 30 {
            bar(ctx, wr.minX + 48, y, (wr.width - 96) * (0.55 + 0.4 * CGFloat(Int(y) % 5) / 5), 7, p.faint); y += 20
        }
        ctx.restoreGState()
    }

    struct Scene { var name: String; var window: CGRect; var standIn: CGRect?; var bandPicture: CGRect?; var whole: FaultCause? }

    static func run(detector: Detector, theme: CoverTheme, out: URL) {
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let look = theme.isDark ? "dark" : "light"
        let display = DisplayDescriptor(id: 1, bounds: CGRect(origin: .zero, size: size))
        let p = Palette.of(theme.isDark)
        let scenes = [
            // A browser window whose page is covered whole: the tabs and toolbar stay in sight.
            Scene(name: "window", window: CGRect(x: 140, y: 56, width: 1000, height: 640),
                  standIn: CGRect(x: 164, y: 300, width: 952, height: 320), bandPicture: nil, whole: nil),
            // The same, with a picture in the toolbar (where a profile picture sits): it is still covered.
            Scene(name: "band-picture", window: CGRect(x: 140, y: 56, width: 1000, height: 640),
                  standIn: CGRect(x: 164, y: 300, width: 952, height: 320), bandPicture: CGRect(x: 1080, y: 104, width: 28, height: 28), whole: nil),
            // A narrow window: the compact line.
            Scene(name: "narrow", window: CGRect(x: 760, y: 90, width: 420, height: 560),
                  standIn: CGRect(x: 776, y: 300, width: 388, height: 300), bandPicture: nil, whole: nil),
            // A whole-display cover (a frame that could not be judged).
            Scene(name: "display", window: CGRect(x: 140, y: 56, width: 1000, height: 640), standIn: nil, bandPicture: nil, whole: .frameNotJudgeable),
        ]
        for s in scenes {
            var img = frame { ctx in desktop(ctx, p); browser(ctx, s.window, p) }
            func px(_ r: CGRect) -> PixelRect { PixelRect(x: Int(r.minX * scale), y: Int(r.minY * scale), w: Int(r.width * scale), h: Int(r.height * scale)) }
            if let r = s.standIn { CheckerStandIn.paint(&img, px(r), seed: 5) }
            if let r = s.bandPicture { CheckerStandIn.paint(&img, px(r), seed: 6) }
            // Front to back, as the window list gives them: the menu bar, the Dock, the browser, the desktop picture.
            let snapshot = WindowSnapshot(windows: [
                WindowInfo(number: 2, ownerPID: 90, layer: 24, bounds: CGRect(x: 0, y: 0, width: size.width, height: menuBar)),
                WindowInfo(number: 3, ownerPID: 91, layer: 20, bounds: CGRect(x: 0, y: size.height - 80, width: size.width, height: 80)),
                WindowInfo(number: 1, ownerPID: 500, layer: 0, bounds: s.window),
                WindowInfo(number: 4, ownerPID: 91, layer: -2147483624, bounds: CGRect(origin: .zero, size: size)),
            ], time: 0)
            let pipeline = DisplayPipeline(display: display, judger: detector, budgetShare: Register.JUDGEMENT_BUDGET, ignoredPIDs: [])
            let map = CaptureMap(displayBounds: display.bounds, contentRect: CGRect(origin: .zero, size: size), contentScale: 1,
                                 scaleFactor: scale, pixelWidth: img.width, pixelHeight: img.height)
            var plan = pipeline.process(CapturedFrame(display: display, status: .complete, image: img, map: map, dirty: nil, time: 0), snapshot: snapshot, now: 0)
            if let cause = s.whole {
                plan = pipeline.process(CapturedFrame(display: display, status: .blank, image: nil, map: nil, dirty: [], time: 0.1), snapshot: snapshot, now: 0.1)
                precondition(plan.wholeDisplay == cause)
            }
            // A whole-display cover leaves the menu bar, found as the app finds it: the screen's top inset, while
            // the window list shows a menu-bar window there.
            let mb = plan.wholeDisplay == nil ? 0 : WayOut.menuBarHeight(display: display.bounds, topInset: menuBar, windows: snapshot.windows)
            let pieces = CoverLayout.layerPieces(plan, menuBar: mb)
            let lines = CoverDrawing.layers(for: plan, theme: theme, scale: scale, menuBar: mb).compactMap { $0 as? WayOutLayer }
            let file = out.appendingPathComponent("wayout-\(s.name)-\(look).png")
            // The repair card, centred on the screen's visible frame (below the menu bar, above the Dock).
            let card = s.whole.flatMap { c in MainActor.assumeIsolated { Composite.card(c, pause: true, theme: theme, scale: scale) } }
            let visibleMid = (size.height - 80 + menuBar) / 2
            let cardFrame = card.map { CGRect(x: (size.width - $0.1.width) / 2, y: size.height - visibleMid - $0.1.height / 2, width: $0.1.width, height: $0.1.height) }
            // The screen under a whole-display cover still shows the desktop; draw it beneath the cover.
            if let cg = Composite.render(img, plan, scale: scale, theme: theme, menuBar: mb, above: { ctx in
                if let card, let cardFrame { Composite.drawCard(ctx, card, at: cardFrame, theme: theme) }
            }) { Composite.writePNG(cg, to: file) }
            let line: [String: Any] = ["scene": s.name, "appearance": look, "file": file.path, "covers": plan.plainCount, "blurs": plan.blurCount,
                                       "wholeDisplay": plan.wholeDisplay?.rawValue ?? NSNull(),
                                       "wayOutPieces": pieces.filter { $0.wayOut != nil }.count, "menuBarLeft": Double(mb),
                                       "card": cardFrame.map(rectJSON) ?? NSNull(),
                                       "lines": lines.map { ["frame": rectJSON($0.frame), "size": "\($0.size)"] }]
            print(String(data: try! JSONSerialization.data(withJSONObject: line, options: [.sortedKeys]), encoding: .utf8)!)
        }
        // The "How it works" window on the plain desktop, drawn offscreen from its own views.
        let titleBar: CGFloat = 28
        if let page = MainActor.assumeIsolated({ Composite.snapshot(HowItWorksView.make(edition: BuildInfo.edition), theme: theme, scale: scale) }) {
            let h = min(page.1.height + titleBar, size.height - menuBar - 16)
            let r = CGRect(x: (size.width - page.1.width) / 2, y: (size.height - menuBar - h) / 2, width: page.1.width, height: h)
            let img = frame { ctx in desktop(ctx, p) }
            let file = out.appendingPathComponent("howitworks-\(look).png")
            if let cg = Composite.render(img, CoverPlan(display: display, items: []), scale: scale, theme: theme, above: { ctx in
                Composite.drawWindow(ctx, page, title: AppText.howItWorksWindowTitle(BuildInfo.edition), at: r, titleBar: titleBar, theme: theme)
            }) { Composite.writePNG(cg, to: file) }
            let line: [String: Any] = ["scene": "howitworks", "appearance": look, "file": file.path, "window": rectJSON(r)]
            print(String(data: try! JSONSerialization.data(withJSONObject: line, options: [.sortedKeys]), encoding: .utf8)!)
        }
    }
}
#endif
