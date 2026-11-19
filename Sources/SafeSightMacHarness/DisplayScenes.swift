// SPDX-License-Identifier: Apache-2.0
// LAB ONLY. A display being attached, step by step, through the real display rule (CoverCoordinator and
// DisplayCoverage), the real cover layer (DisplayPipeline, null models and the lab stand-in, a synthetic
// magenta-and-green checker that forces a cover) and the cover layer's own layers. Synthetic desktops only (the
// way-out scenes' shapes); nothing is captured, no window is shown and no display is touched. Each step is written
// as one PNG of the display arrangement, with a line under each display saying what it shows.
#if SAFESIGHTMAC_LAB
import AppKit
import CoreGraphics
import CoreText
import DetectorCore
import Foundation
import LabStandIn
import Preprocess
import SafeSightMacCover
import SafeSightMacWatcher

enum DisplayScenes {
    /// Records what the coordinator draws instead of drawing it on a screen.
    @MainActor final class Recorder: CoverPresenter {
        var plans: [CoverPlan] = []
        func apply(_ p: [CoverPlan]) { plans = p }
        func removeAll() { plans = [] }
    }

    /// The OS as the coordinator sees it here: the display list and a clock the scenes move on.
    @MainActor final class OS {
        var list: DisplayList?
        var now: TimeInterval = 1000
        var restarts = 0
        /// The generation of the last capture restart asked for: the generation its streams' frames carry.
        var lastRestart = 0
    }

    /// The judging queue's pipelines, one per display.
    final class Pipelines { var all: [UInt32: DisplayPipeline] = [:] }

    struct Screen {
        let display: DisplayDescriptor
        let name: String
        /// The browser-like window, in the display's own points.
        let window: CGRect
        /// The lab stand-in, in the display's own points.
        let standIn: CGRect?
        var id: UInt32 { display.id }
        var main: Bool { display.id == 1 }
    }

    static let gap: CGFloat = 56, margin: CGFloat = 48, titleHeight: CGFloat = 84, captionHeight: CGFloat = 104

    static func run(detector: Detector, theme: CoverTheme, out: URL) {
        MainActor.assumeIsolated { runScenes(detector: detector, theme: theme, out: out) }
    }

    @MainActor static func runScenes(detector: Detector, theme: CoverTheme, out: URL) {
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let look = theme.isDark ? "dark" : "light"
        let size = WayOutScenes.size, scale = WayOutScenes.scale
        let palette = WayOutScenes.Palette.of(theme.isDark)
        let builtIn = Screen(display: DisplayDescriptor(id: 1, bounds: CGRect(origin: .zero, size: size)), name: "Built-in display (main)",
                             window: CGRect(x: 140, y: 56, width: 1000, height: 640), standIn: CGRect(x: 690, y: 300, width: 300, height: 220))
        let added = Screen(display: DisplayDescriptor(id: 2, bounds: CGRect(x: size.width, y: 0, width: size.width, height: size.height)),
                           name: "Second display", window: CGRect(x: 120, y: 70, width: 1040, height: 660),
                           standIn: CGRect(x: 180, y: 330, width: 340, height: 240))
        let third = Screen(display: DisplayDescriptor(id: 3, bounds: CGRect(x: 2 * size.width, y: 0, width: size.width, height: size.height)),
                           name: "Third display", window: CGRect(x: 160, y: 90, width: 960, height: 600), standIn: nil)

        // What each display shows under any cover: a desktop and a browser-like window, plus the stand-in.
        var frames: [UInt32: RGBAImage] = [:]
        for s in [builtIn, added, third] {
            var img = WayOutScenes.frame { ctx in
                WayOutScenes.desktop(ctx, palette, dock: s.main)
                WayOutScenes.browser(ctx, s.window, palette)
            }
            if let r = s.standIn {
                CheckerStandIn.paint(&img, PixelRect(x: Int(r.minX * scale), y: Int(r.minY * scale), w: Int(r.width * scale), h: Int(r.height * scale)), seed: s.id + 4)
            }
            frames[s.id] = img
        }

        /// The window list, front to back, in global points: each display's menu bar, the Dock, the windows, the desktop pictures.
        func snapshot(_ attached: [Screen]) -> WindowSnapshot {
            var w: [WindowInfo] = []
            for s in attached {
                w.append(WindowInfo(number: 10 + s.id, ownerPID: 90, layer: 24,
                                    bounds: CGRect(x: s.display.bounds.minX, y: 0, width: size.width, height: WayOutScenes.menuBar)))
            }
            w.append(WindowInfo(number: 20, ownerPID: 91, layer: 20, bounds: CGRect(x: 0, y: size.height - 80, width: size.width, height: 80)))
            for s in attached {
                w.append(WindowInfo(number: 100 + s.id, ownerPID: 500 + Int32(s.id), layer: 0,
                                    bounds: s.window.offsetBy(dx: s.display.bounds.minX, dy: s.display.bounds.minY)))
            }
            for s in attached { w.append(WindowInfo(number: 200 + s.id, ownerPID: 91, layer: -2147483624, bounds: s.display.bounds)) }
            return WindowSnapshot(windows: w, time: 0)
        }

        // The real coordinator, with the OS's lists and the clock faked and the judging queue run inline.
        let recorder = Recorder(), os = OS(), generations = GenerationCounter(), pipelines = Pipelines()
        func list(_ s: [Screen]) -> DisplayList { DisplayList(displays: s.map(\.display), main: 1) }
        let coordinator = CoverCoordinator(presenter: recorder, generations: generations, read: { _ in os.list }, flush: {}, clock: { os.now },
                                           state: { _ in SystemState(displaysAsleep: false, sessionOnConsole: true) })
        coordinator.restartCapture = { g in os.restarts += 1; os.lastRestart = g }
        coordinator.judging = { _, required in
            for (id, p) in pipelines.all { if let r = required[id], r > p.requiredGeneration { p.cover(because: .displayChanging, until: r) } }
        }

        /// One frame of display `s`, from a stream of generation `g`, judged and handed to the coordinator.
        func judge(_ s: Screen, _ g: Int, attached: [Screen]) {
            let p = pipelines.all[s.id] ?? {
                let p = DisplayPipeline(display: s.display, judger: detector, budgetShare: Register.JUDGEMENT_BUDGET, ignoredPIDs: [])
                p.cover(because: .notYetJudged, until: coordinator.coverage.required[s.id])
                pipelines.all[s.id] = p
                return p
            }()
            guard let img = frames[s.id], let map = CaptureMap(displayBounds: s.display.bounds, contentRect: CGRect(origin: .zero, size: size),
                                                              contentScale: 1, scaleFactor: scale, pixelWidth: img.width, pixelHeight: img.height)
            else { return }
            let plan = p.process(CapturedFrame(display: s.display, status: .complete, image: img, map: map, dirty: nil, time: os.now, generation: g),
                                 snapshot: snapshot(attached), now: os.now)
            coordinator.deliver(plan, generation: g)
        }

        var step = 0
        func shot(_ slug: String, _ title: String, attached: [Screen], slots: [Screen], captions: [UInt32: String], card: Bool = false) {
            step += 1
            let file = out.appendingPathComponent("displays-\(step)-\(slug)-\(look).png")
            let windows = snapshot(attached).windows
            var rendered: [UInt32: CGImage] = [:]
            var states: [[String: Any]] = []
            for s in attached {
                guard let plan = recorder.plans.first(where: { $0.display.id == s.id }) else { continue }
                // The menu bar a whole-display cover leaves: on the main display only.
                let mb = plan.wholeDisplay != nil && WayOut.leavesMenuBar(display: s.id, main: 1)
                    ? WayOut.menuBarHeight(display: s.display.bounds, topInset: WayOutScenes.menuBar, windows: windows) : 0
                var cardImage: (CGImage, CGSize)?
                if card, s.main, let cause = recorder.plans.compactMap(\.wholeDisplay).first {
                    cardImage = Composite.card(cause, pause: true, theme: theme, scale: scale)
                }
                rendered[s.id] = Composite.render(frames[s.id], plan, scale: scale, theme: theme, menuBar: mb, above: { ctx in
                    guard let c = cardImage else { return }
                    let visibleMid = (size.height - 80 + WayOutScenes.menuBar) / 2
                    Composite.drawCard(ctx, c, at: CGRect(x: (size.width - c.1.width) / 2, y: size.height - visibleMid - c.1.height / 2,
                                                         width: c.1.width, height: c.1.height), theme: theme)
                })
                states.append(["display": Int(s.id), "wholeDisplay": plan.wholeDisplay?.rawValue ?? NSNull(), "covers": plan.plainCount,
                               "blurs": plan.blurCount, "menuBarLeft": Double(mb)])
            }
            if let cg = arrangement(title, slots: slots, rendered: rendered, captions: captions, theme: theme) {
                Composite.writePNG(cg, to: file)
            }
            let line: [String: Any] = ["step": step, "scene": slug, "appearance": look, "file": file.path, "displays": states,
                                       "streamRestarts": os.restarts]
            print(String(data: try! JSONSerialization.data(withJSONObject: line, options: [.sortedKeys]), encoding: .utf8)!)
        }

        // 1. One display, judged: the stand-in is covered, everything else shows.
        os.list = list([builtIn])
        coordinator.start()
        coordinator.restartNow()
        let g1 = os.lastRestart
        judge(builtIn, g1, attached: [builtIn])
        shot("before", "1. One display, checked", attached: [builtIn], slots: [builtIn, added], captions: [
            1: "Checked. The test picture is covered; everything else shows.",
            2: "Not attached yet."])

        // 2. macOS announces a change (the reconfiguration callback's begin call): every display is covered at once.
        coordinator.willChange()
        shot("announced", "2. macOS announces a display change", attached: [builtIn], slots: [builtIn, added], captions: [
            1: "Covered whole the moment macOS announces the change. The main display keeps its menu bar.",
            2: "Not attached yet."])

        // 3. The change is applied: the new display gets its canvas, covered whole, before any stream exists. A plan
        //    judged on a frame from before the change arrives now and is refused.
        os.list = list([builtIn, added])
        coordinator.didChange()
        judge(builtIn, g1, attached: [builtIn, added])
        shot("attached", "3. The second display is attached", attached: [builtIn, added], slots: [builtIn, added], captions: [
            1: "Still covered: only a frame from a stream started after the change can lower it.",
            2: "Covered whole from the moment macOS lists it, before any stream starts. Its menu bar too."])

        // 4. Capture restarts once the change has settled; the built-in display's first judged frame lowers its cover.
        os.now += CoverCoordinator.settle
        coordinator.tick()
        let g2 = os.lastRestart
        judge(builtIn, g2, attached: [builtIn, added])
        shot("first-frame-main", "4. The first checked frame on the built-in display", attached: [builtIn, added], slots: [builtIn, added], captions: [
            1: "Checked again: the cover comes down, the test picture stays covered.",
            2: "Still covered: it waits for its own first checked frame."])

        // 5. The new display's first judged frame: lowered, its own stand-in covered.
        judge(added, g2, attached: [builtIn, added])
        shot("first-frame-new", "5. The first checked frame on the second display", attached: [builtIn, added], slots: [builtIn, added], captions: [
            1: "Checked.",
            2: "Checked: the cover comes down; its test picture is covered."])

        // 6. A third display: past DISPLAYS_MAX, counted from the OS's own list. Covered whole for as long as it is
        //    attached, even when a plan for it arrives; the repair card says why.
        coordinator.willChange()
        os.list = list([builtIn, added, third])
        coordinator.didChange()
        os.now += CoverCoordinator.settle
        coordinator.tick()
        let g3 = os.lastRestart
        for s in [builtIn, added, third] { judge(s, g3, attached: [builtIn, added, third]) }
        os.now += 2
        shot("third", "6. A third display", attached: [builtIn, added, third], slots: [builtIn, added, third], captions: [
            1: "Checked. The repair card says why another display is covered.",
            2: "Checked.",
            3: "Past the limit of \(Register.DISPLAYS_MAX) displays: covered whole for as long as it is attached."], card: true)
    }

    /// The displays side by side at one pixel per point, under a title, each with its name and what it shows.
    static func arrangement(_ title: String, slots: [Screen], rendered: [UInt32: CGImage], captions: [UInt32: String], theme: CoverTheme) -> CGImage? {
        let size = WayOutScenes.size
        let w = CGFloat(slots.count) * size.width + CGFloat(slots.count - 1) * gap + 2 * margin
        let h = titleHeight + size.height + captionHeight + margin / 2
        guard let ctx = CGContext(data: nil, width: Int(w), height: Int(h), bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        let dark = theme.isDark
        let desk = dark ? CGColor(srgbRed: 0.05, green: 0.07, blue: 0.08, alpha: 1) : CGColor(srgbRed: 0.93, green: 0.94, blue: 0.94, alpha: 1)
        let ink = dark ? CGColor(srgbRed: 0.92, green: 0.95, blue: 0.95, alpha: 1) : CGColor(srgbRed: 0.06, green: 0.1, blue: 0.11, alpha: 1)
        let muted = dark ? CGColor(srgbRed: 0.62, green: 0.68, blue: 0.68, alpha: 1) : CGColor(srgbRed: 0.33, green: 0.4, blue: 0.41, alpha: 1)
        ctx.setFillColor(desk)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        text(ctx, title, at: CGPoint(x: margin, y: h - 52), size: 30, weight: .semibold, color: ink)
        for (i, s) in slots.enumerated() {
            let r = CGRect(x: margin + CGFloat(i) * (size.width + gap), y: captionHeight, width: size.width, height: size.height)
            let shape = CGPath(roundedRect: r, cornerWidth: 14, cornerHeight: 14, transform: nil)
            if let img = rendered[s.id] {
                ctx.saveGState()
                ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 30, color: CGColor(gray: 0, alpha: dark ? 0.5 : 0.18))
                ctx.addPath(shape); ctx.setFillColor(CGColor(gray: 0, alpha: 1)); ctx.fillPath()
                ctx.restoreGState()
                ctx.saveGState()
                ctx.addPath(shape); ctx.clip()
                ctx.draw(img, in: r)
                ctx.restoreGState()
                ctx.addPath(shape); ctx.setStrokeColor(CGColor(gray: dark ? 1 : 0, alpha: 0.18)); ctx.setLineWidth(1); ctx.strokePath()
            } else {
                ctx.saveGState()
                ctx.addPath(shape); ctx.setStrokeColor(muted); ctx.setLineWidth(2); ctx.setLineDash(phase: 0, lengths: [14, 10]); ctx.strokePath()
                ctx.restoreGState()
            }
            text(ctx, s.name, at: CGPoint(x: r.minX + 4, y: captionHeight - 40), size: 22, weight: .semibold, color: ink)
            text(ctx, captions[s.id] ?? "", at: CGPoint(x: r.minX + 4, y: captionHeight - 72), size: 19, weight: .regular, color: muted)
        }
        return ctx.makeImage()
    }

    static func text(_ ctx: CGContext, _ s: String, at p: CGPoint, size: CGFloat, weight: NSFont.Weight, color: CGColor) {
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size, weight: weight),
                                                         NSAttributedString.Key(kCTForegroundColorAttributeName as String): color]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: attributes))
        ctx.textPosition = p
        CTLineDraw(line, ctx)
    }
}
#endif
