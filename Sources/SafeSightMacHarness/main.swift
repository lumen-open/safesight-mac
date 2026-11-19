// SPDX-License-Identifier: Apache-2.0
// safesightmac-harness: feeds frames through the watcher pipeline (cover layer and detector) without
// capturing the screen. Frames come from image files or from built-in synthetic scenes. Use harmless
// synthetic test patterns only. It never imports the capture layer and opens no network connection.
//
//   safesightmac-harness demo [--out DIR]                         scripted synthetic scenes (lab build: with the stand-in)
//   safesightmac-harness frames FILE... [--models DIR] [--out DIR] image files as successive frames of one display
//   safesightmac-harness bench [--models DIR] [--pages DIR] [--json FILE] [--trials N] [--cases single,grid,busy,scroll]
//            (lab build only) times the chain from frame to cover plan to cover layer update, by stage; see Bench.swift
//   safesightmac-harness falsecovers --models DIR --list FILE [--root DIR] [--rule R] [--jsonl FILE] [--json FILE]
//            false covers on harmless screens through the whole pipeline; see FalseCovers.swift
//   safesightmac-harness wayout --out DIR [--appearance light|dark]
//            (lab build only) synthetic desktops whose covers leave the way out in sight, and the "How it works"
//            window drawn from its own views; see WayOutScenes.swift
//   safesightmac-harness displays --out DIR [--appearance light|dark]
//            (lab build only) a display being attached, step by step, through the display rule; see DisplayScenes.swift
//   safesightmac-harness vanish
//            a real cover window, invisible and off every display, goes the moment its process is killed or quits;
//            see Vanish.swift
//   safesightmac-harness jitter --models DIR --list FILE [--root DIR] [--draws N] [--per-band K] [--background B]
//            [--every K] [--seed S] [--json FILE]
//            (lab build only) how far jitter moves each model's score on harmless screens; see JitterSpread.swift
//   options: --scale N (1, 2 or 3; default 2)  --origin X,Y (global points; default 0,0)  --primary-height H
//            --rule balanced|either  --window X,Y,W,H (one window, global points; default: the whole display)
//            --models DIR (real models, checked against the sealed hash list)  --null-models (lab build only)
//            --appearance light|dark (how the covers are drawn in the PNGs; default light)
//
// Prints one JSON line per frame: the cover plan, each cover's global rectangle, its overlay window
// frame (Cocoa points) and its canvas layer frame. With --out, also writes each frame with its covers
// drawn on it as a PNG (the cover layer's own layers, rendered offscreen), so the covers can be looked at.
import CoreGraphics
import DetectorCore
import SafeSightMacWatcher
import Foundation
import ImageIO
import Preprocess
import SafeSightMacCover
#if SAFESIGHTMAC_LAB
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
    var bench = BenchSettings()
    var jitter = JitterSettings()
    var list: String?
    var root: String?
    var jsonl: String?
    var theme = CoverTheme.light
}

/// Bench options, parsed in every build so that a release build can refuse `bench` plainly.
struct BenchSettings {
    var trials = 8
    var pages: String?
    var json: String?
    var cases: [String] = ["single", "grid", "busy", "scroll", "reappear"]
    var label = "bench"
    var busyPages = 6
    var scrollSpeeds = [8, 32, 96]
}

/// Jitter-measurement options, parsed in every build so that a release build can refuse `jitter` plainly.
struct JitterSettings {
    var draws = 24
    var perBand = 3000
    var background = 400
    var every = 1
    var seed: UInt64 = 7
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
        case "--appearance":
            switch v() { case "light": o.theme = .light; case "dark": o.theme = .dark; default: fail("--appearance light|dark") }
        case "--trials": o.bench.trials = Int(v()) ?? 8
        case "--list": o.list = v()
        case "--root": o.root = v()
        case "--jsonl": o.jsonl = v()
        case "--pages": o.bench.pages = v()
        case "--json": o.bench.json = v()
        case "--cases": o.bench.cases = v().split(separator: ",").map(String.init)
        case "--label": o.bench.label = v()
        case "--busy-pages": o.bench.busyPages = Int(v()) ?? 6
        case "--scroll-speeds": o.bench.scrollSpeeds = v().split(separator: ",").compactMap { Int($0) }
        case "--draws": o.jitter.draws = max(2, Int(v()) ?? 24)
        case "--per-band": o.jitter.perBand = max(0, Int(v()) ?? 3000)
        case "--background": o.jitter.background = max(0, Int(v()) ?? 400)
        case "--every": o.jitter.every = max(1, Int(v()) ?? 1)
        case "--seed": o.jitter.seed = UInt64(v()) ?? 7
        case "--help", "-h": print("see the header of Sources/SafeSightMacHarness/main.swift"); exit(0)
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
            items.append(["kind": item.kind == .plain ? "cover" : "blur", "global": rectJSON(item.rect), "wayOut": item.wayOut,
                          "overlayWindow": rectJSON(overlays[k].0), "canvasLayer": rectJSON(layers[k].0)])
        }
    }
    let line: [String: Any] = ["frame": i, "scene": label, "display": plan.display.id,
                               "canvasWindow": rectJSON(CoverLayout.canvasFrame(display: plan.display.bounds, primaryHeight: primaryHeight)),
                               "wholeDisplay": plan.wholeDisplay?.rawValue ?? NSNull(), "covers": plan.plainCount, "blurs": plan.blurCount,
                               "items": items, "ms": Int(ms)]
    print(String(data: try! JSONSerialization.data(withJSONObject: line, options: [.sortedKeys]), encoding: .utf8)!)
}

// MARK: Run

if CommandLine.arguments.dropFirst().first == "vanish" {
    if CommandLine.arguments.contains("--child") { Vanish.child() }
    Vanish.run()
}

let o = parse()

func makeDetector() -> Detector {
    if let m = o.models {
        // Packages are compiled once each, to a fixed place in this tool's Caches folder (DetectorCore's
        // CompiledModels); an app's models folder holds them compiled already.
        do { return try WatcherModels.loadDetector(folder: URL(fileURLWithPath: m), rule: o.rule) }
        catch { fail("models refused: \(error)") }
    }
    #if SAFESIGHTMAC_LAB
    var cfg = DetectorConfig(); cfg.rule = o.rule
    let d = try! Detector(models: .labNull(), thresholdsJSON: WatcherModels.committedThresholds, config: cfg)
    d.standIn = CheckerStandIn()
    return d
    #else
    if o.nullModels { fail("--null-models needs a lab build: SAFESIGHTMAC_LAB=1 swift run --scratch-path .build-lab safesightmac-harness") }
    fail("a release build needs --models DIR (the stand-in exists only in lab builds)")
    #endif
}

let detector = makeDetector()

if o.command == "falsecovers" {
    guard let list = o.list, o.models != nil else { fail("falsecovers needs --models DIR and --list FILE") }
    FalseCovers.run(detector: detector, list: list, root: o.root ?? FileManager.default.currentDirectoryPath, rule: o.rule,
                    jsonl: o.jsonl, json: o.bench.json, modelsNote: "real models (\((o.models! as NSString).lastPathComponent)), checked against the sealed hash list: Marqo, NSFWJS and the Bumble tie-breaker")
    exit(0)
}

if o.command == "wayout" {
    #if SAFESIGHTMAC_LAB
    guard let out = o.out else { fail("wayout needs --out DIR") }
    WayOutScenes.run(detector: detector, theme: o.theme, out: URL(fileURLWithPath: out))
    exit(0)
    #else
    fail("wayout needs a lab build (the lab stand-in forces its covers): SAFESIGHTMAC_LAB=1 swift run --scratch-path .build-lab safesightmac-harness wayout --out DIR")
    #endif
}

if o.command == "displays" {
    #if SAFESIGHTMAC_LAB
    guard let out = o.out else { fail("displays needs --out DIR") }
    DisplayScenes.run(detector: detector, theme: o.theme, out: URL(fileURLWithPath: out))
    exit(0)
    #else
    fail("displays needs a lab build (the lab stand-in forces its covers): SAFESIGHTMAC_LAB=1 swift run --scratch-path .build-lab safesightmac-harness displays --out DIR")
    #endif
}

if o.command == "jitter" {
    #if SAFESIGHTMAC_LAB
    guard let list = o.list, let m = o.models else { fail("jitter needs --models DIR and --list FILE") }
    JitterSpread.run(detector: detector, list: list, root: o.root ?? FileManager.default.currentDirectoryPath, o: o.jitter, json: o.bench.json,
                     modelsNote: "real models (\((m as NSString).lastPathComponent)), checked against the sealed hash list; sealed cut-off table")
    exit(0)
    #else
    fail("jitter needs a lab build (it reads scores, which release builds never expose): SAFESIGHTMAC_LAB=1 swift run -c release --scratch-path .build-lab safesightmac-harness jitter")
    #endif
}

if o.command == "bench" {
    #if SAFESIGHTMAC_LAB
    var b = BenchOptions()
    b.trials = o.bench.trials; b.pages = o.bench.pages; b.json = o.bench.json; b.cases = Set(o.bench.cases)
    b.label = o.bench.label; b.busyPages = o.bench.busyPages; b.scrollSpeeds = o.bench.scrollSpeeds
    b.modelsNote = o.models.map { "real models (\(($0 as NSString).lastPathComponent)), checked against the sealed hash list; sealed cut-off table" } ?? "null models (lab): every model scores 0, only the stand-in covers"
    Bench(detector: detector, options: b).run()
    exit(0)
    #else
    fail("bench needs a lab build (it uses the lab stand-in): SAFESIGHTMAC_LAB=1 swift run -c release --scratch-path .build-lab safesightmac-harness bench")
    #endif
}

struct Step { var label: String; var image: RGBAImage?; var status: FrameStatus; var dirty: [PixelRect]? }

func demoSteps(_ w: Int, _ h: Int) -> [Step] {
    let page = Synthetic.page(w, h, seed: 11)
    var steps = [Step(label: "clean synthetic page", image: page, status: .complete, dirty: nil)]
    #if SAFESIGHTMAC_LAB
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
        if let cg = Composite.render(s.image, plan, scale: o.scale, theme: o.theme) {
            Composite.writePNG(cg, to: URL(fileURLWithPath: out).appendingPathComponent(String(format: "frame-%02d.png", i)))
        }
    }
    t += 0.1
}
