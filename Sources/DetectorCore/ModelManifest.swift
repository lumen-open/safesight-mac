// SPDX-License-Identifier: Apache-2.0
// The model bundle's manifest (`kestrel-models/1`): which models the detector runs, in which slot, with which input
// side, flag classes and compute units, and the hash of every file of every model. It is a file in the models folder
// (`bundle-manifest.json`), and the hash list sealed in the build names it like any model file, so an edited manifest
// is refused exactly as an edited model is (spec/detector-contract.md).
//
// Read strictly: an unknown key, a missing key, a wrong type or a value out of range refuses the whole manifest. The
// caller covers every display whole when it is refused, as for any model fault.
import CoreML
import Foundation

public struct ModelManifest: Sendable, Equatable {
    public static let schema = "kestrel-models/1"
    /// The file's name in a models folder.
    public static let fileName = "bundle-manifest.json"
    /// The input sides the contract allows.
    public static let sides = 224...512

    /// Where a model sits in the rule: family A, family B, or the tie-breaker asked only when the two disagree.
    public enum Slot: String, Sendable, Equatable { case a = "A", b = "B", tieBreaker = "tie-breaker" }
    /// The runtime that runs a model. Core ML today; another runtime is a new case here and a new branch where
    /// `ModelSet.bundle` makes the scorer.
    public enum Runtime: String, Sendable, Equatable { case coreml }
    /// Which compute units Core ML may use for a model.
    public enum Units: String, Sendable, Equatable, CaseIterable {
        case cpuAndNeuralEngine, cpuAndGPU, cpuOnly, all
        public var mlUnits: MLComputeUnits {
            switch self {
            case .cpuAndNeuralEngine: return .cpuAndNeuralEngine
            case .cpuAndGPU: return .cpuAndGPU
            case .cpuOnly: return .cpuOnly
            case .all: return .all
            }
        }
    }

    public struct File: Sendable, Equatable {
        public let path: String
        public let sha256: String
    }

    public struct Model: Sendable, Equatable {
        public let id: String
        public let slot: Slot
        public let runtime: Runtime
        /// The package's path inside the models folder (`x/x.mlpackage`).
        public let package: String
        public let inputSide: Int
        /// K, the number of values in `probs`.
        public let classCount: Int
        /// The indices in `probs` whose sum is the flag score.
        public let flagClasses: [Int]
        public let computeUnits: Units
        /// Every file of the package, with its SHA-256.
        public let files: [File]

        /// The family the detector's rule sees. The tie-breaker keeps family B's tag, as it always has; the rule
        /// asks it only through its slot.
        public var family: Family { slot == .a ? .a : .b }
    }

    /// 2: the two-family rule (Balanced or Either). 1: single-family mode, where the one family's flag alone covers.
    public let families: Int
    public let models: [Model]

    public enum Failure: Error, Equatable, Sendable {
        case notJSON
        case schema
        case key(String)
        case value(String)
    }

    /// Every file the manifest names, across its models.
    public var files: [File] { models.flatMap(\.files) }

    /// Reads and checks a manifest. Any fault refuses it whole.
    public static func decode(_ data: Data) throws -> ModelManifest {
        guard let top = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Failure.notJSON }
        try keys(top, ["schema", "families", "models"], at: "manifest")
        guard top["schema"] as? String == schema else { throw Failure.schema }
        let families = try int(top["families"], "families")
        guard families == 1 || families == 2 else { throw Failure.value("families must be 1 or 2") }
        guard let list = top["models"] as? [Any], !list.isEmpty else { throw Failure.value("models must be a non-empty list") }
        var models: [Model] = []
        for (i, any) in list.enumerated() {
            guard let m = any as? [String: Any] else { throw Failure.value("models[\(i)] is not an object") }
            models.append(try model(m, at: "models[\(i)]"))
        }
        let manifest = ModelManifest(families: families, models: models)
        try manifest.check()
        return manifest
    }

    /// The rules across models: unique ids, packages and files; the slots the declared families need.
    func check() throws {
        let ids = models.map(\.id)
        guard Set(ids).count == ids.count else { throw Failure.value("model ids must be unique") }
        guard Set(models.map(\.package)).count == models.count else { throw Failure.value("packages must be unique") }
        let paths = files.map(\.path)
        guard Set(paths).count == paths.count else { throw Failure.value("a file is listed twice") }
        let slots = models.map(\.slot)
        let ties = slots.filter { $0 == .tieBreaker }.count
        guard ties <= 1 else { throw Failure.value("at most one tie-breaker") }
        if families == 2 {
            guard slots.contains(.a), slots.contains(.b) else { throw Failure.value("two families need a model in slot A and one in slot B") }
        } else {
            guard ties == 0 else { throw Failure.value("a single-family bundle has no tie-breaker") }
            guard Set(slots).count == 1 else { throw Failure.value("a single-family bundle has all its models in one slot") }
        }
    }

    static func model(_ m: [String: Any], at w: String) throws -> Model {
        try keys(m, ["id", "slot", "runtime", "package", "inputSide", "classCount", "flagClasses", "computeUnits", "files"], at: w)
        guard let id = m["id"] as? String, isName(id) else { throw Failure.value("\(w).id must be a plain name (letters, digits, . _ -)") }
        guard let slot = (m["slot"] as? String).flatMap(Slot.init) else { throw Failure.value("\(w).slot must be A, B or tie-breaker") }
        guard let runtime = (m["runtime"] as? String).flatMap(Runtime.init) else { throw Failure.value("\(w).runtime must be coreml") }
        guard let package = m["package"] as? String, isRelative(package), package.hasSuffix(".mlpackage") else {
            throw Failure.value("\(w).package must be a relative path ending in .mlpackage")
        }
        let side = try int(m["inputSide"], "\(w).inputSide")
        guard sides.contains(side) else { throw Failure.value("\(w).inputSide must be from \(sides.lowerBound) to \(sides.upperBound)") }
        let k = try int(m["classCount"], "\(w).classCount")
        guard (2...1000).contains(k) else { throw Failure.value("\(w).classCount must be from 2 to 1000") }
        guard let flagsAny = m["flagClasses"] as? [Any], !flagsAny.isEmpty else { throw Failure.value("\(w).flagClasses must be a non-empty list") }
        let flags = try flagsAny.map { try int($0, "\(w).flagClasses") }
        guard Set(flags).count == flags.count, flags.allSatisfy({ (0..<k).contains($0) }), flags.count < k else {
            throw Failure.value("\(w).flagClasses must be distinct indices below classCount, and not all of them")
        }
        guard let units = (m["computeUnits"] as? String).flatMap(Units.init) else {
            throw Failure.value("\(w).computeUnits must be one of \(Units.allCases.map(\.rawValue).joined(separator: ", "))")
        }
        guard let filesAny = m["files"] as? [Any], !filesAny.isEmpty else { throw Failure.value("\(w).files must be a non-empty list") }
        var files: [File] = []
        for (j, f) in filesAny.enumerated() {
            guard let o = f as? [String: Any] else { throw Failure.value("\(w).files[\(j)] is not an object") }
            try keys(o, ["path", "sha256"], at: "\(w).files[\(j)]")
            guard let p = o["path"] as? String, isRelative(p), p.hasPrefix(package + "/") else {
                throw Failure.value("\(w).files[\(j)].path must be inside \(package)")
            }
            guard let h = o["sha256"] as? String, h.count == 64, h.allSatisfy({ "0123456789abcdef".contains($0) }) else {
                throw Failure.value("\(w).files[\(j)].sha256 must be 64 lower-case hex digits")
            }
            files.append(File(path: p, sha256: h))
        }
        return Model(id: id, slot: slot, runtime: runtime, package: package, inputSide: side, classCount: k, flagClasses: flags,
                     computeUnits: units, files: files)
    }

    /// Exactly these keys: an unknown one (a typo, say) refuses the manifest rather than being skipped.
    static func keys(_ o: [String: Any], _ want: Set<String>, at w: String) throws {
        let have = Set(o.keys)
        if let extra = have.subtracting(want).sorted().first { throw Failure.key("\(w) has an unknown key \(extra)") }
        if let missing = want.subtracting(have).sorted().first { throw Failure.key("\(w) lacks \(missing)") }
    }

    /// A whole number, written as one (JSON `true` or `2.5` are refused).
    static func int(_ v: Any?, _ w: String) throws -> Int {
        guard let n = v as? NSNumber, CFGetTypeID(n) == CFNumberGetTypeID(), !CFNumberIsFloatType(n) else {
            throw Failure.value("\(w) must be a whole number")
        }
        return n.intValue
    }

    static func isName(_ s: String) -> Bool {
        !s.isEmpty && s.count <= 100 && s.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) && $0.isASCII || "._-".unicodeScalars.contains($0) }
    }

    static func isRelative(_ p: String) -> Bool {
        let parts = p.split(separator: "/", omittingEmptySubsequences: false)
        return !p.isEmpty && !p.hasPrefix("/") && !parts.contains("..") && !parts.contains(".") && !parts.contains("")
            && !p.contains("\\") && p.unicodeScalars.allSatisfy { $0.isASCII && $0.value >= 0x20 }
    }
}
