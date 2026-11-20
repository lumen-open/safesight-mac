// SPDX-License-Identifier: Apache-2.0
// The bundle's manifest (models/bundle-manifest.json): sealed like a model file, read strictly, and building exactly
// the set of models that used to be written into the code. Synthetic files in temporary folders; the real models are
// used only where they are on this Mac (the lab build's converted folder), never copied anywhere but a temporary
// folder as APFS clones.
import CoreML
import Foundation
import Testing
@testable import DetectorCore
@testable import Preprocess
@testable import RegionFinder
@testable import SafeSightMacWatcher

enum Bundles {
    static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../..").standardized
    static var committedManifest: Data { (try? Data(contentsOf: repo.appendingPathComponent("models/bundle-manifest.json"))) ?? Data() }
    /// Held by every test that runs the real models, so two suites never drive the Neural Engine and the GPU at once
    /// (Core ML can time out a prediction under that load, which the detector counts as a fault, as it should).
    static let realModels = NSLock()

    /// Runs a real model a few times on a blank tensor before a test asserts anything: its first Neural Engine
    /// prediction pays for loading, and on a Mac busy with the rest of the test run Core ML can time that one out (the
    /// detector counts it as a fault and covers, as it should; the bench warms up the same way, `Detector.warmUp`).
    static func warm(_ models: [ScoringModel]) {
        for m in models {
            let blank = [[UInt8](repeating: 128, count: 3 * m.side * m.side)]
            for _ in 0..<3 { if (try? m.flagScores(blank)) != nil { break } }
        }
    }
    /// The lab build's converted models, where this Mac has them (never on CI).
    static let lab = repo.appendingPathComponent("../v3-detector/models/converted").standardized

    /// A temporary models folder holding `files` (path to text).
    static func folder(_ files: [String: Data]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("safesightmac-bundle-\(UUID().uuidString)")
        for (path, data) in files {
            let u = dir.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: u)
        }
        return dir
    }

    static func list(_ files: [String: Data]) -> String {
        files.keys.sorted().map { WatcherModels.sha256(files[$0]!) + "  " + $0 }.joined(separator: "\n")
    }

    /// A manifest for synthetic packages: family A `a`, family B `b`, optionally a tie-breaker `t`.
    static func manifest(_ packages: [String: [String: Data]], families: Int = 2, slots: [String: String]? = nil,
                         side: Int = 224, extra: String = "") -> Data {
        let models = packages.keys.sorted().map { id -> String in
            let files = packages[id]!.keys.sorted().map { #"{"path": "\#($0)", "sha256": "\#(WatcherModels.sha256(packages[id]![$0]!))"}"# }
            let slot = slots?[id] ?? (id == "a" ? "A" : id == "b" ? "B" : "tie-breaker")
            return #"{"id": "\#(id)", "slot": "\#(slot)", "runtime": "coreml", "package": "\#(id)/\#(id).mlpackage", "inputSide": \#(side), "#
                + #""classCount": 2, "flagClasses": [0], "computeUnits": "cpuAndNeuralEngine", "files": [\#(files.joined(separator: ", "))]}"#
        }
        return Data(#"{"schema": "kestrel-models/1", "families": \#(families),\#(extra) "models": [\#(models.joined(separator: ", "))]}"#.utf8)
    }

    static let synthetic: [String: [String: Data]] = [
        "a": ["a/a.mlpackage/Manifest.json": Data("{}".utf8), "a/a.mlpackage/Data/model.mlmodel": Data("synthetic bytes one".utf8)],
        "b": ["b/b.mlpackage/Manifest.json": Data("{ }".utf8), "b/b.mlpackage/Data/weights.bin": Data("synthetic bytes two".utf8)],
    ]

    /// A bundle folder and its sealed list: the packages and the manifest.
    static func sealed(_ packages: [String: [String: Data]] = synthetic, manifest m: Data? = nil) throws -> (URL, String) {
        var files: [String: Data] = [:]
        for p in packages.values { files.merge(p) { a, _ in a } }
        files[ModelManifest.fileName] = m ?? manifest(packages)
        return (try folder(files), list(files))
    }

    /// The lab folder's three packages, cloned into a temporary folder with the committed manifest (nil off this Mac).
    static func stagedLab() throws -> URL? {
        guard FileManager.default.fileExists(atPath: lab.path) else { return nil }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("safesightmac-lab-bundle-\(UUID().uuidString)")
        let m = try ModelManifest.decode(committedManifest)
        for e in m.models {
            let to = dir.appendingPathComponent(e.package)
            try FileManager.default.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: lab.appendingPathComponent(e.package), to: to)   // a clone on APFS
        }
        try committedManifest.write(to: dir.appendingPathComponent(ModelManifest.fileName))
        return dir
    }
}

@Suite struct BundleManifestTests {
    let fm = FileManager.default

    // MARK: the seal covers the manifest

    @Test func theSealedListNamesTheCommittedManifest() throws {
        let entries = try WatcherModels.parse(WatcherModels.committedHashList)
        let entry = try #require(entries.first { $0.path == ModelManifest.fileName })
        #expect(entry.sha256 == WatcherModels.sha256(Bundles.committedManifest), "models/bundle-manifest.json is the one sealed in the build")
        // And the manifest names exactly the other sealed entries.
        let m = try ModelManifest.decode(Bundles.committedManifest)
        #expect(Set(m.files.map { "\($0.sha256)  \($0.path)" }) == Set(entries.filter { $0.path != ModelManifest.fileName }.map { "\($0.sha256)  \($0.path)" }))
    }

    @Test func aMatchingManifestIsRead() throws {
        let (dir, list) = try Bundles.sealed(); defer { try? fm.removeItem(at: dir) }
        try WatcherModels.verify(folder: dir, hashList: list)
        let m = try WatcherModels.readManifest(folder: dir, hashList: list)
        #expect(m.models.map(\.id) == ["a", "b"])
    }

    @Test func anEditedManifestIsRefusedAsAnEditedModelIs() throws {
        let (dir, list) = try Bundles.sealed(); defer { try? fm.removeItem(at: dir) }
        let u = dir.appendingPathComponent(ModelManifest.fileName)
        var bytes = try Data(contentsOf: u)
        bytes[bytes.count / 2] ^= 0x01
        try bytes.write(to: u)
        #expect(throws: ModelCheckFailure.hashMismatch(ModelManifest.fileName)) { try WatcherModels.verify(folder: dir, hashList: list) }
        #expect(throws: ModelCheckFailure.hashMismatch(ModelManifest.fileName)) { try WatcherModels.readManifest(folder: dir, hashList: list) }
        #expect(throws: ModelCheckFailure.self) { try WatcherModels.loadDetector(folder: dir, rule: .balanced, hashList: list) }
    }

    @Test func aManifestTheSealedListDoesNotNameIsRefused() throws {
        let (dir, list) = try Bundles.sealed(); defer { try? fm.removeItem(at: dir) }
        let without = list.split(separator: "\n").filter { !$0.hasSuffix("  " + ModelManifest.fileName) }.joined(separator: "\n")
        #expect(throws: ModelCheckFailure.self) { try WatcherModels.readManifest(folder: dir, hashList: without) }
        #expect(throws: ModelCheckFailure.self) { try WatcherModels.loadDetector(folder: dir, rule: .balanced, hashList: without) }
    }

    @Test func aMissingManifestIsRefused() throws {
        let (dir, list) = try Bundles.sealed(); defer { try? fm.removeItem(at: dir) }
        try fm.removeItem(at: dir.appendingPathComponent(ModelManifest.fileName))
        #expect(throws: ModelCheckFailure.missingFile(ModelManifest.fileName)) { try WatcherModels.readManifest(folder: dir, hashList: list) }
        #expect(throws: ModelCheckFailure.self) { try WatcherModels.loadDetector(folder: dir, rule: .balanced, hashList: list) }
    }

    @Test func aManifestThatNamesOtherFilesThanTheSealedListIsRefused() throws {
        // Sealed, but it leaves out one model file the list names: the two would disagree about what is loaded.
        var fewer = Bundles.synthetic
        fewer["b"]!["b/b.mlpackage/Data/weights.bin"] = nil
        var files: [String: Data] = [:]
        for p in Bundles.synthetic.values { files.merge(p) { a, _ in a } }
        files[ModelManifest.fileName] = Bundles.manifest(fewer)
        let dir = try Bundles.folder(files); defer { try? fm.removeItem(at: dir) }
        let list = Bundles.list(files)
        try WatcherModels.verify(folder: dir, hashList: list)
        #expect(throws: ModelCheckFailure.self) { try WatcherModels.readManifest(folder: dir, hashList: list) }
    }

    @Test func aModelWithoutSealedCutoffsIsRefused() throws {
        // The synthetic models "a" and "b" have no cut-offs in the sealed table: refused before anything loads.
        let (dir, list) = try Bundles.sealed(); defer { try? fm.removeItem(at: dir) }
        let m = try WatcherModels.readManifest(folder: dir, hashList: list)
        #expect(m.modelsMissingCutoffs(in: WatcherModels.committedThresholds) == ["a", "b"])
        #expect(throws: ModelCheckFailure.manifest("the sealed cut-off table has no cut-offs for a, b")) {
            try WatcherModels.loadDetector(folder: dir, rule: .balanced, hashList: list)
        }
        #expect(try ModelManifest.decode(Bundles.committedManifest).modelsMissingCutoffs(in: WatcherModels.committedThresholds).isEmpty)
    }

    // MARK: read strictly

    @Test func theCommittedManifestReads() throws {
        let m = try ModelManifest.decode(Bundles.committedManifest)
        #expect(m.families == 2 && m.models.count == 3)
    }

    @Test(arguments: [
        ("an unknown key", #" "familes": 1,"#),
        ("a second schema", #" "schema2": "x","#),
    ])
    func anUnknownTopLevelKeyIsRefused(_ name: String, _ extra: String) {
        #expect(throws: ModelManifest.Failure.self, "\(name)") { try ModelManifest.decode(Bundles.manifest(Bundles.synthetic, extra: extra)) }
    }

    @Test func badValuesAreRefused() {
        let s = Bundles.synthetic
        let bad: [(String, Data)] = [
            ("not JSON", Data("{".utf8)),
            ("three families", Bundles.manifest(s, families: 3)),
            ("no families", Bundles.manifest(s, families: 0)),
            ("a side below the contract", Bundles.manifest(s, side: 100)),
            ("a side above the contract", Bundles.manifest(s, side: 1024)),
            ("two families without B", Bundles.manifest(s, slots: ["a": "A", "b": "A"])),
            ("one family across two slots", Bundles.manifest(s, families: 1)),
            ("one family with a tie-breaker", Bundles.manifest(["a": s["a"]!, "t": ["t/t.mlpackage/x": Data("x".utf8)]], families: 1)),
            ("two tie-breakers", Bundles.manifest(s.merging(["t": ["t/t.mlpackage/x": Data("x".utf8)], "u": ["u/u.mlpackage/x": Data("y".utf8)]]) { a, _ in a })),
            ("another schema", Data(String(decoding: Bundles.manifest(s), as: UTF8.self).replacingOccurrences(of: "kestrel-models/1", with: "kestrel-models/2").utf8)),
            ("a side written as a fraction", Data(String(decoding: Bundles.manifest(s), as: UTF8.self).replacingOccurrences(of: "\"inputSide\": 224", with: "\"inputSide\": 224.5").utf8)),
            ("a flag class out of range", Data(String(decoding: Bundles.manifest(s), as: UTF8.self).replacingOccurrences(of: "\"flagClasses\": [0]", with: "\"flagClasses\": [2]").utf8)),
            ("every class a flag class", Data(String(decoding: Bundles.manifest(s), as: UTF8.self).replacingOccurrences(of: "\"flagClasses\": [0]", with: "\"flagClasses\": [0, 1]").utf8)),
            ("unknown compute units", Data(String(decoding: Bundles.manifest(s), as: UTF8.self).replacingOccurrences(of: "cpuAndNeuralEngine", with: "neuralEngineOnly").utf8)),
            ("another runtime", Data(String(decoding: Bundles.manifest(s), as: UTF8.self).replacingOccurrences(of: "\"coreml\"", with: "\"onnx\"").utf8)),
            ("a path outside the package", Data(String(decoding: Bundles.manifest(s), as: UTF8.self).replacingOccurrences(of: "\"a/a.mlpackage/Manifest.json\"", with: "\"a/../b.json\"").utf8)),
            ("an upper-case hash", Data(String(decoding: Bundles.manifest(s), as: UTF8.self).replacingOccurrences(of: WatcherModels.sha256(Data("{}".utf8)), with: WatcherModels.sha256(Data("{}".utf8)).uppercased()).utf8)),
        ]
        for (name, data) in bad {
            #expect(throws: ModelManifest.Failure.self, "\(name)") { try ModelManifest.decode(data) }
        }
    }

    @Test func aMissingModelKeyIsRefused() {
        let text = String(decoding: Bundles.manifest(Bundles.synthetic), as: UTF8.self).replacingOccurrences(of: "\"computeUnits\": \"cpuAndNeuralEngine\", ", with: "")
        #expect(throws: ModelManifest.Failure.self) { try ModelManifest.decode(Data(text.utf8)) }
    }

    // MARK: the same set as before

    /// What the code used to say (`ModelSet.watcher` before the manifest): Marqo (A) and NSFWJS (B) on the Neural
    /// Engine, the Bumble float32 build as the tie-breaker on the GPU, in that order.
    struct Planned: Equatable {
        var id: String, family: Family, side: Int, flags: [Int], package: String, units: MLComputeUnits, tieBreaker: Bool
    }
    static let before = [
        Planned(id: "marqo-vit-tiny-384", family: .a, side: 384, flags: [0], package: "marqo-vit-tiny-384/marqo-vit-tiny-384.mlpackage",
                units: .cpuAndNeuralEngine, tieBreaker: false),
        Planned(id: "nsfwjs-mobilenet-v2", family: .b, side: 224, flags: [1, 3], package: "nsfwjs-mobilenet-v2/nsfwjs-mobilenet-v2.mlpackage",
                units: .cpuAndNeuralEngine, tieBreaker: false),
        Planned(id: "bumble-private-detector", family: .b, side: 480, flags: [0],
                package: "bumble-private-detector/bumble-private-detector.fp32.mlpackage", units: .cpuAndGPU, tieBreaker: true),
    ]

    final class Recorded: ScoringModel {
        let id: String, family: Family, side: Int
        init(_ m: ModelManifest.Model) { id = m.id; family = m.family; side = m.inputSide }
        func flagScores(_ tensors: [[UInt8]]) throws -> [Float] { tensors.map { _ in 0 } }
    }

    @Test func theManifestBuildsTheSetThatWasHardCoded() throws {
        let m = try ModelManifest.decode(Bundles.committedManifest)
        var made: [Planned] = []
        let set = try ModelSet.bundle(m, bundleVersion: "t") { e in
            made.append(Planned(id: e.id, family: e.family, side: e.inputSide, flags: e.flagClasses, package: e.package,
                                units: e.computeUnits.mlUnits, tieBreaker: e.slot == .tieBreaker))
            return Recorded(e)
        }
        #expect(made == Self.before)
        #expect(set.models.map(\.id) == ["marqo-vit-tiny-384", "nsfwjs-mobilenet-v2"])
        #expect(set.models.map(\.family) == [.a, .b])
        #expect(set.referee?.id == "bumble-private-detector" && set.referee?.family == .b)
        #expect(set.students.isEmpty && !set.singleFamily)
        // Every package has its compiled copy's name from the sealed list, as before.
        #expect(Set(try WatcherModels.packageKeys(WatcherModels.committedHashList).keys) == Set(Self.before.map(\.package)))
        // Each model's cut-offs are in the sealed table under its id.
        let table = try JSONDecoder().decode(ThresholdTable.self, from: WatcherModels.committedThresholds)
        #expect(Set(table.models.keys) == Set(Self.before.map(\.id)))
    }

    // MARK: with the real models, where this Mac has them

    /// The manifest's models and the old hard-coded ones, loaded from the same files: the same scores, bit for bit, on
    /// the same tensors, and the same verdicts on the synthetic fixtures.
    @Test func theRealModelsBehaveAsBefore() throws {
        guard let dir = try Bundles.stagedLab() else { return }   // not on CI
        defer { try? fm.removeItem(at: dir) }
        Bundles.realModels.lock(); defer { Bundles.realModels.unlock() }
        let keys = try WatcherModels.packageKeys(WatcherModels.committedHashList)
        let fromManifest = try WatcherModels.loadDetector(folder: dir, rule: .balanced)
        let old = Self.before.map { p in
            try! CoreMLScoringModel(id: p.id, family: p.family, side: p.side, flagIndices: p.flags,
                                    url: dir.appendingPathComponent(p.package), units: p.units, compiledKey: keys[p.package])
        }
        let new = fromManifest.models.models + [fromManifest.models.referee!]
        Bundles.warm(old + new)
        #expect(new.map(\.id) == old.map(\.id))
        var img = Fixtures.blank(600, 400)
        Fixtures.paint(&img, PixelRect(x: 40, y: 40, w: 200, h: 150), channel: nil, seed: 3)
        Fixtures.paintFlagged(&img, PixelRect(x: 300, y: 100, w: 220, h: 220))
        for (a, b) in zip(old, new) {
            let t = [try Preprocessor.run(img, rect: PixelRect(x: 0, y: 0, w: 600, h: 400), side: a.side, jitterSeed: nil),
                     try Preprocessor.run(img, rect: PixelRect(x: 300, y: 100, w: 220, h: 220), side: a.side, jitterSeed: 7)]
            #expect(try a.flagScores(t) == b.flagScores(t), "\(a.id)")
        }
        let oldSet = ModelSet(models: Array(old.prefix(2)), referee: old[2], bundleVersion: fromManifest.models.bundleVersion)
        let oldDetector = try Detector(models: oldSet, thresholdsJSON: WatcherModels.committedThresholds)
        let ctx = JudgeContext(windowID: 1, startsCovered: false)
        let v1 = oldDetector.judge(img, context: ctx), v2 = fromManifest.judge(img, context: ctx)
        #expect(v1.regions.map(\.rect) == v2.regions.map(\.rect))
        #expect(v1.regions.map(\.display) == v2.regions.map(\.display))
        #expect(v1.coverWindow == v2.coverWindow && v1.overloaded == v2.overloaded)
    }

    @Test func aRealModelOfAnotherShapeIsRefusedWhenItLoads() throws {
        guard FileManager.default.fileExists(atPath: Bundles.lab.path) else { return }   // not on CI
        Bundles.realModels.lock(); defer { Bundles.realModels.unlock() }
        let url = Bundles.lab.appendingPathComponent("nsfwjs-mobilenet-v2/nsfwjs-mobilenet-v2.mlpackage")
        let key = try WatcherModels.packageKeys(WatcherModels.committedHashList)["nsfwjs-mobilenet-v2/nsfwjs-mobilenet-v2.mlpackage"]
        _ = try CoreMLScoringModel(id: "n", family: .b, side: 224, flagIndices: [1, 3], url: url, compiledKey: key, classCount: 5)
        #expect(throws: ModelShapeFailure.self) {
            try CoreMLScoringModel(id: "n", family: .b, side: 384, flagIndices: [1, 3], url: url, compiledKey: key, classCount: 5)
        }
        #expect(throws: ModelShapeFailure.self) {
            try CoreMLScoringModel(id: "n", family: .b, side: 224, flagIndices: [1], url: url, compiledKey: key, classCount: 2)
        }
    }
}
