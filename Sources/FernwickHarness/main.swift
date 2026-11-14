// SPDX-License-Identifier: Apache-2.0
// fernwick-harness: feeds frames through the watcher pipeline (cover layer and detector) without
// capturing the screen. Frames come from image files or from built-in synthetic scenes. Use harmless
// synthetic test patterns only. It never imports the capture layer and opens no network connection.
//
//   fernwick-harness demo [--out DIR]                         scripted synthetic scenes (lab build: with the stand-in)
//   fernwick-harness frames FILE... [--models DIR] [--out DIR] image files as successive frames of one display
//   options: --scale N (1, 2 or 3; default 2)  --origin X,Y (global points; default 0,0)  --primary-height H
//            --rule balanced|either  --window X,Y,W,H (one window, global points; default: the whole display)
//            --models DIR (real models, checked against the sealed hash list)  --null-models (lab build only)
//
// Prints one JSON line per frame: the cover plan, each cover's global rectangle, its overlay window
// frame (Cocoa points) and its canvas layer frame. With --out, also writes each frame with its covers
// drawn on it as a PNG, so the covers can be looked at.
import CoreGraphics
import DetectorCore
import FernwickWatcher
import Foundation
import ImageIO
import Preprocess
import UniformTypeIdentifiers
#if FERNWICK_LAB
import LabStandIn
#endif

struct Options {
    var command = "demo"
    var files: [String] = []
    var scale: CGFloat = 2
    var origin = CGPoint.zero
    var primaryHeight: CGFloat?
    var rule = DetectorRule.balanced
    var window: CGRect?
    var models: String?
    var nullModels = false
    var out: String?
}

func fail(_ s: String) -> Never { FileHandle.standardError.write(Data((s + "\n").utf8)); exit(2) }

func parse() -> Options {
    var o = Options()
    var a = Array(CommandLine.arguments.dropFirst())
    if let c = a.first, !c.hasPrefix("--") { o.command = c; a.removeFirst() }
    func nums(_ s: String) -> [CGFloat] { s.split(separator: ",").compactMap { Double($0).map { CGFloat($0) } } }
    while !a.isEmpty {
        let k = a.removeFirst()
        func v() -> String { guard !a.isEmpty else { fail("missing value for \(k)") }; return a.removeFirst() }
        switch k {
        case "--scale": o.scale = CGFloat(Double(v()) ?? 0); if ![1, 2, 3].contains(o.scale) { fail("--scale must be 1, 2 or 3") }
        case "--origin": let n = nums(v()); guard n.count == 2 else { fail("--origin X,Y") }; o.origin = CGPoint(x: n[0], y: n[1])
        case "--primary-height": o.primaryHeight = CGFloat(Double(v()) ?? 0)
        case "--rule": guard let r = DetectorRule(rawValue: v()) else { fail("--rule balanced|either") }; o.rule = r
        case "--window": let n = nums(v()); guard n.count == 4 else { fail("--window X,Y,W,H") }; o.window = CGRect(x: n[0], y: n[1], width: n[2], height: n[3])
        case "--models": o.models = v()
        case "--null-models": o.nullModels = true
        case "--out": o.out = v()
        case "--help", "-h": print("see the header of Sources/FernwickHarness/main.swift"); exit(0)
        default:
            if k.hasPrefix("--") { fail("unknown option \(k)") }
            o.files.append(k)
        }
    }
    return o
}

// MARK: Synthetic scenes (harmless patterns only)

enum Synthetic {
    /// A plain page: light background, grey text-like bars and a few neutral textured "photos".
    static func page(_ w: Int, _ h: Int, seed: UInt32) -> RGBAImage {
        var img = RGBAImage(width: w, height: h, pixels: (0..<(w * h * 4)).map { $0 % 4 == 3 ? 255 : 244 })
        var g = XorShift32(seed: seed)
        var y = h / 12
        while y < h - 20 {
            let len = w / 3 + Int(g.next() % UInt32(w / 3))
            fill(&img, PixelRect(x: w / 12, y: y, w: min(len, w - w / 6), h: max(4, h / 90)), r: 90, g: 92, b: 96)
            y += max(12, h / 30)
        }
        for i in 0..<3 {
            let side = max(24, w / 10)
            texture(&img, PixelRect(x: w / 2 + i * (side + side / 4), y: h / 5, w: side, h: side), seed: seed &+ UInt32(i) &+ 7)
        }
        return img
    }

    static func fill(_ img: inout RGBAImage, _ r: PixelRect, r R: UInt8, g G: UInt8, b B: UInt8) {
        guard let c = r.clamped(width: img.width, height: img.height) else { return }
        for y in c.y..<c.maxY { for x in c.x..<c.maxX { let p = (y * img.width + x) * 4; img.pixels[p] = R; img.pixels[p + 1] = G; img.pixels[p + 2] = B } }
    }

    /// A neutral noise-and-gradient patch: photo-like to the picture finder, harmless to anyone.
    static func texture(_ img: inout RGBAImage, _ r: PixelRect, seed: UInt32) {
        guard let c = r.clamped(width: img.width, height: img.height) else { return }
        var g = XorShift32(seed: seed)
        for y in c.y..<c.maxY { for x in c.x..<c.maxX {
            let p = (y * img.width + x) * 4, n = Int(g.next() % 70)
            img.pixels[p] = UInt8(60 + n + (x - c.x) * 60 / max(1, c.w)); img.pixels[p + 1] = UInt8(90 + n); img.pixels[p + 2] = UInt8(80 + n + (y - c.y) * 50 / max(1, c.h))
        } }
    }
}

// MARK: Output

func rectJSON(_ r: CGRect) -> [String: Double] {
    ["x": Double(r.minX), "y": Double(r.minY), "w": Double(r.width), "h": Double(r.height)]
}

func report(_ i: Int, _ label: String, _ plan: CoverPlan, primaryHeight: CGFloat, ms: Double) {
    let overlays = CoverLayout.overlayFrames(plan, primaryHeight: primaryHeight)
    let layers = CoverLayout.layerFrames(plan)
    var items: [[String: Any]] = []
    if let c = plan.wholeDisplay {
        items.append(["kind": "whole-display", "cause": c.rawValue, "global": rectJSON(plan.display.bounds),
                      "overlayWindow": rectJSON(overlays[0].0), "canvasLayer": rectJSON(layers[0].0)])
    } else {
        for (k, item) in plan.items.enumerated() {
            items.append(["kind": item.kind == .plain ? "cover" : "blur", "global": rectJSON(item.rect),
                          "overlayWindow": rectJSON(overlays[k].0), "canvasLayer": rectJSON(layers[k].0)])
        }
    }
    let line: [String: Any] = ["frame": i, "scene": label, "display": plan.display.id,
                               "canvasWindow": rectJSON(CoverLayout.canvasFrame(display: plan.display.bounds, primaryHeight: primaryHeight)),
                               "wholeDisplay": plan.wholeDisplay?.rawValue ?? NSNull(), "covers": plan.plainCount, "blurs": plan.blurCount,
                               "items": items, "ms": Int(ms)]
    print(String(data: try! JSONSerialization.data(withJSONObject: line, options: [.sortedKeys]), encoding: .utf8)!)
}

/// Draws the plan over the frame (covers grey, blurs as their colour cells) and writes a PNG.
func writeComposite(_ img: RGBAImage?, _ plan: CoverPlan, map: CaptureMap?, to url: URL) {
    let w = img?.width ?? Int(plan.display.bounds.width), h = img?.height ?? Int(plan.display.bounds.height)
    var px = img?.pixels ?? [UInt8](repeating: 0, count: w * h * 4)
    func paint(_ r: PixelRect, _ color: (Int, Int) -> (UInt8, UInt8, UInt8)) {
        guard let c = r.clamped(width: w, height: h) else { return }
        for y in c.y..<c.maxY { for x in c.x..<c.maxX {
            let p = (y * w + x) * 4, (R, G, B) = color(x - c.x, y - c.y)
            px[p] = R; px[p + 1] = G; px[p + 2] = B; px[p + 3] = 255
        } }
    }
    if plan.wholeDisplay != nil || map == nil {
        paint(PixelRect(x: 0, y: 0, w: w, h: h)) { _, _ in (102, 105, 110) }
    } else if let m = map {
        for item in plan.items {
            guard let r = m.toPixels(item.rect) else { continue }
            switch item.kind {
            case .plain: paint(r) { _, _ in (102, 105, 110) }
            case let .blur(t):
                paint(r) { x, y in
                    let o = ((y * t.rows / max(1, r.h)) * t.columns + (x * t.columns / max(1, r.w))) * 4
                    return (t.rgba[o], t.rgba[o + 1], t.rgba[o + 2])
                }
            }
        }
    }
    guard let provider = CGDataProvider(data: Data(px) as CFData),
          let cg = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                           bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: provider, decode: nil,
                           shouldInterpolate: false, intent: .defaultIntent),
          let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
    CGImageDestinationAddImage(dest, cg, nil)
    CGImageDestinationFinalize(dest)
}

// MARK: Run

let o = parse()

func makeDetector() -> Detector {
    if let m = o.models {
        do { return try WatcherModels.loadDetector(folder: URL(fileURLWithPath: m), rule: o.rule) }
        catch { fail("models refused: \(error)") }
    }
    #if FERNWICK_LAB
    var cfg = DetectorConfig(); cfg.rule = o.rule
    let d = try! Detector(models: .labNull(), thresholdsJSON: WatcherModels.committedThresholds, config: cfg)
    d.standIn = CheckerStandIn()
    return d
    #else
    if o.nullModels { fail("--null-models needs a lab build: FERNWICK_LAB=1 swift run --scratch-path .build-lab fernwick-harness") }
    fail("a release build needs --models DIR (the stand-in exists only in lab builds)")
    #endif
}

let detector = makeDetector()

struct Step { var label: String; var image: RGBAImage?; var status: FrameStatus; var dirty: [PixelRect]? }

func demoSteps(_ w: Int, _ h: Int) -> [Step] {
    let page = Synthetic.page(w, h, seed: 11)
    var steps = [Step(label: "clean synthetic page", image: page, status: .complete, dirty: nil)]
    #if FERNWICK_LAB
    // The lab stand-in: a synthetic magenta-and-green checker that forces a cover. Harmless.
    let spot = PixelRect(x: w / 10, y: h / 2, w: w / 5, h: w / 5)
    var withStandIn = page
    CheckerStandIn.paint(&withStandIn, spot, seed: 3)
    steps.append(Step(label: "stand-in appears", image: withStandIn, status: .complete, dirty: [spot]))
    var small = withStandIn
    let tiny = PixelRect(x: w * 7 / 10, y: h * 3 / 4, w: 48, h: 48)
    CheckerStandIn.paint(&small, tiny, seed: 4)
    steps.append(Step(label: "small stand-in appears", image: small, status: .complete, dirty: [tiny]))
    var gone = page; gone.pixels[0] ^= 1
    for i in 1...5 {
        var f = gone; f.pixels[4] = UInt8(i)
        steps.append(Step(label: "stand-ins removed, clean judgement \(i)", image: f, status: .complete, dirty: [spot, tiny]))
    }
    #endif
    steps.append(Step(label: "fault: blank frame", image: nil, status: .blank, dirty: []))
    steps.append(Step(label: "recovered", image: page, status: .complete, dirty: nil))
    return steps
}

func steps(for d: DisplayDescriptor) -> [Step] {
    let w = Int(d.bounds.width * o.scale), h = Int(d.bounds.height * o.scale)
    switch o.command {
    case "demo":
        return demoSteps(w, h)
    case "frames":
        guard !o.files.isEmpty else { fail("frames needs at least one image file") }
        return o.files.map { f in
            guard let img = ImageLoading.load(URL(fileURLWithPath: f)) else { fail("unreadable image: \(f)") }
            return Step(label: (f as NSString).lastPathComponent, image: img, status: .complete, dirty: nil)
        }
    default:
        fail("unknown command \(o.command): use demo or frames")
    }
}

// The display: for image files its size follows the first image and the scale.
var size = CGSize(width: 800, height: 500)
if o.command == "frames", let f = o.files.first, let img = ImageLoading.load(URL(fileURLWithPath: f)) {
    size = CGSize(width: CGFloat(img.width) / o.scale, height: CGFloat(img.height) / o.scale)
}
let display = DisplayDescriptor(id: 1, bounds: CGRect(origin: o.origin, size: size))
let primaryHeight = o.primaryHeight ?? size.height
let snapshot = WindowSnapshot(windows: [WindowInfo(number: 1, ownerPID: 500, layer: 0, bounds: o.window ?? display.bounds)], time: 0)
let pipeline = DisplayPipeline(display: display, judger: detector, budgetShare: Register.JUDGEMENT_BUDGET, ignoredPIDs: [])
if let out = o.out { try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true) }

var t: TimeInterval = 0
for (i, s) in steps(for: display).enumerated() {
    var frame = CapturedFrame(display: display, status: s.status, image: s.image, map: nil, dirty: s.dirty, time: t)
    if let img = s.image {
        guard img.width == Int(size.width * o.scale), img.height == Int(size.height * o.scale) else { fail("frame \(i): every image must be the same size") }
        frame.map = CaptureMap(displayBounds: display.bounds, contentRect: CGRect(origin: .zero, size: size), contentScale: 1,
                               scaleFactor: o.scale, pixelWidth: img.width, pixelHeight: img.height)
    }
    let t0 = Date()
    let plan = pipeline.process(frame, snapshot: snapshot, now: t)
    report(i, s.label, plan, primaryHeight: primaryHeight, ms: Date().timeIntervalSince(t0) * 1000)
    if let out = o.out {
        writeComposite(s.image, plan, map: frame.map, to: URL(fileURLWithPath: out).appendingPathComponent(String(format: "frame-%02d.png", i)))
    }
    t += 0.1
}
