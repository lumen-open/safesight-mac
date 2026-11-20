// SPDX-License-Identifier: Apache-2.0
// The contract with a real bundle plugged in (tools/conformance/run.sh sets SAFESIGHTMAC_BUNDLE to a models folder
// sealed into the build under test). Without it these tests use the lab build's models where this Mac has them, and
// otherwise do nothing. Fault drills: a missing file, a changed byte, an unlisted file, an edited manifest and a model
// that fails to load are each refused, and a refused bundle covers every display whole (the app's detector failure,
// CoverCoordinatorTests). Every copy is an APFS clone in a temporary folder; synthetic patterns only.
import Foundation
import Testing
@testable import DetectorCore
@testable import Preprocess
@testable import RegionFinder
@testable import SafeSightMacWatcher

@Suite(.serialized) struct PluggedInBundleTests {
    let fm = FileManager.default

    /// The bundle under test, cloned into a temporary folder the test may change, or nil.
    func bundle() throws -> URL? {
        if let p = ProcessInfo.processInfo.environment["SAFESIGHTMAC_BUNDLE"] {
            let dir = fm.temporaryDirectory.appendingPathComponent("safesightmac-plugged-\(UUID().uuidString)")
            try fm.copyItem(at: URL(fileURLWithPath: p), to: dir)
            return dir
        }
        return try Bundles.stagedLab()
    }

    @Test func itLoadsAndKeepsTheContract() throws {
        guard let dir = try bundle() else { return }
        defer { try? fm.removeItem(at: dir) }
        Bundles.realModels.lock(); defer { Bundles.realModels.unlock() }
        let m = try WatcherModels.readManifest(folder: dir)
        for rule in DetectorRule.allCases {
            let d = try WatcherModels.loadDetector(folder: dir, rule: rule)
            Bundles.warm(d.models.models + d.models.students + (d.models.referee.map { [$0] } ?? []))
            #expect(d.models.singleFamily == (m.families == 1))
            #expect(d.models.roster.map(\.id) == m.models.filter { $0.slot != .tieBreaker }.map(\.id) + m.models.filter { $0.slot == .tieBreaker }.map(\.id))
            var img = Fixtures.blank(900, 600)
            Fixtures.paint(&img, PixelRect(x: 60, y: 60, w: 160, h: 120), channel: nil, seed: 3)
            Fixtures.paint(&img, PixelRect(x: 400, y: 200, w: 300, h: 240), channel: nil, seed: 9)
            // Nothing judged: nothing clear.
            let z = d.judge(img, context: JudgeContext(windowID: 1, startsCovered: false), budget: 0)
            #expect(!z.regions.isEmpty && z.regions.allSatisfy { $0.reason == .overload && $0.display != .clear })
            // Judged: classes only, and no fault.
            let v = d.judge(img, context: JudgeContext(windowID: 2, startsCovered: false))
            #expect(v.modelFaults == 0, "model faults per model (counts only): \(d.modelFaults)")
            #expect(v.judgements > 0)
            #expect(Self.floats(in: v).isEmpty, "a verdict holds classes only")
        }
    }

    static func floats(in v: Any) -> [String] {
        if v is Float { return ["Float"] }
        return Mirror(reflecting: v).children.flatMap { floats(in: $0.value) }
    }

    /// Each drill changes one thing in a clone of the bundle; each must be refused.
    @Test func faultDrillsAreRefused() throws {
        guard let base = try bundle() else { return }
        defer { try? fm.removeItem(at: base) }
        Bundles.realModels.lock(); defer { Bundles.realModels.unlock() }
        let m = try WatcherModels.readManifest(folder: base)
        let smallest = try #require(m.files.min { (size($0.path, in: base)) < (size($1.path, in: base)) })
        func drill(_ name: String, _ change: (URL) throws -> Void, hashList: ((URL) throws -> String)? = nil) throws {
            let dir = fm.temporaryDirectory.appendingPathComponent("safesightmac-drill-\(UUID().uuidString)")
            try fm.copyItem(at: base, to: dir)
            defer { try? fm.removeItem(at: dir) }
            try change(dir)
            let list = try hashList?(dir) ?? WatcherModels.committedHashList
            #expect(throws: ModelCheckFailure.self, "\(name)") { try WatcherModels.loadDetector(folder: dir, rule: .balanced, hashList: list) }
        }
        try drill("a missing file") { try fm.removeItem(at: $0.appendingPathComponent(smallest.path)) }
        try drill("a changed byte") { d in
            let u = d.appendingPathComponent(smallest.path)
            var b = try Data(contentsOf: u); b[0] ^= 0x01; try fm.removeItem(at: u); try b.write(to: u)
        }
        try drill("an unlisted file") { d in
            try Data("x".utf8).write(to: d.appendingPathComponent(m.models[0].package).appendingPathComponent("extra.bin"))
        }
        try drill("an edited manifest") { d in
            let u = d.appendingPathComponent(ModelManifest.fileName)
            var b = try Data(contentsOf: u); b.append(0x20); try fm.removeItem(at: u); try b.write(to: u)
        }
        // A failed load: the files and the manifest are consistent and sealed (in a list made for the drill), but the
        // manifest gives the first model the wrong input side, so its shape check refuses it as it loads.
        let wrongSide = m.models[0].inputSide == 224 ? 256 : 224
        try drill("a model that fails to load", { d in
            let u = d.appendingPathComponent(ModelManifest.fileName)
            var text = try String(contentsOf: u, encoding: .utf8)
            let from = "\"inputSide\": \(m.models[0].inputSide)"
            let r = try #require(text.range(of: from))
            text.replaceSubrange(r, with: "\"inputSide\": \(wrongSide)")
            try fm.removeItem(at: u); try Data(text.utf8).write(to: u)
        }, hashList: { d in
            try WatcherModels.parse(WatcherModels.committedHashList).map { e in
                e.path == ModelManifest.fileName ? (WatcherModels.sha256(of: d.appendingPathComponent(e.path))! + "  " + e.path) : "\(e.sha256)  \(e.path)"
            }.joined(separator: "\n")
        })
    }

    func size(_ path: String, in d: URL) -> Int {
        ((try? fm.attributesOfItem(atPath: d.appendingPathComponent(path).path)[.size]) as? Int) ?? .max
    }
}
