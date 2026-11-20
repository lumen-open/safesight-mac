// SPDX-License-Identifier: Apache-2.0
// Vendored from the kestrel lab detector (v3-detector, commit 49ecdd9) under Apache-2.0.
// Scoring models. Internal to the module: scores never leave DetectorCore.
import CoreML
import Foundation
import Preprocess

public enum Family: String, Sendable, Codable { case a = "A-vit", b = "B-cnn", student = "student" }

/// One model's runtime, as the detector sees it: a name, a family, a square input side, and a flag score for each
/// spec tensor. This is the seam for a runtime other than Core ML (spec/detector-contract.md, level 1).
///
/// Scores travel one way only: from a scorer into DetectorCore. Nothing in DetectorCore hands a scorer, a score or a
/// cut-off back out (`ModelSet` keeps its scorers to itself, and every verdict is classes only).
public protocol ScoringModel: AnyObject {
    var id: String { get }
    var family: Family { get }
    var side: Int { get }
    /// Flag scores (summed probability of the flag classes, 0 to 1) for spec tensors [3][side][side], one per tensor.
    /// Throwing, or giving a score that is not a number or not in 0...1, is a model failure: the entry is covered or
    /// blurred and judged again, never shown as clean.
    func flagScores(_ tensors: [[UInt8]]) throws -> [Float]
}

/// Why a Core ML model was refused when it was loaded: it does not have the shape its manifest entry declares.
public enum ModelShapeFailure: Error, Equatable, Sendable {
    /// No multi-array input `image` of float32 [1, 3, side, side].
    case input(String)
    /// No multi-array output `probs` holding the declared number of classes.
    case output(String)
}

/// A Core ML model with input `image` [1][3][N][N] float (0..255) and output `probs` [1][K].
final class CoreMLScoringModel: ScoringModel {
    let id: String
    let family: Family
    let side: Int
    let flagIndices: [Int]
    private let model: MLModel

    /// `url`: a compiled model (`.mlmodelc`), loaded in place, or a package, compiled once to a fixed place
    /// (`CompiledModels`). `compiledKey` names that compiled copy (a hash of the package's files when nil).
    /// `classCount`, when given, is checked against the model's own description with its input, so a model whose
    /// shape is not the declared one is refused here, before it judges anything.
    init(id: String, family: Family, side: Int, flagIndices: [Int], url: URL, units: MLComputeUnits = .cpuAndNeuralEngine,
         compiledKey: String? = nil, classCount: Int? = nil) throws {
        self.id = id; self.family = family; self.side = side; self.flagIndices = flagIndices
        let compiled = try CompiledModels.compiled(url, key: compiledKey)
        let cfg = MLModelConfiguration()
        cfg.computeUnits = units
        model = try MLModel(contentsOf: compiled, configuration: cfg)
        if let k = classCount { try Self.checkShape(model.modelDescription, side: side, classCount: k) }
    }

    /// The contract's shape: input `image`, a float32 multi-array [1, 3, side, side]; output `probs`, a multi-array of
    /// `classCount` values ([1, K] or [K]).
    static func checkShape(_ d: MLModelDescription, side: Int, classCount k: Int) throws {
        guard let i = d.inputDescriptionsByName["image"], i.type == .multiArray, let c = i.multiArrayConstraint else {
            throw ModelShapeFailure.input("no multi-array input named image")
        }
        guard c.dataType == .float32 else { throw ModelShapeFailure.input("image is not float32") }
        guard c.shape.map(\.intValue) == [1, 3, side, side] else {
            throw ModelShapeFailure.input("image is \(c.shape.map(\.intValue)), not [1, 3, \(side), \(side)]")
        }
        guard let o = d.outputDescriptionsByName["probs"], o.type == .multiArray, let oc = o.multiArrayConstraint else {
            throw ModelShapeFailure.output("no multi-array output named probs")
        }
        let shape = oc.shape.map(\.intValue)
        guard shape == [1, k] || shape == [k] else { throw ModelShapeFailure.output("probs is \(shape), not [1, \(k)]") }
    }

    /// A model output the contract does not allow: no `probs`, or too few values in it. A failure, never a score.
    struct OutputFault: Error {}

    func flagScores(_ tensors: [[UInt8]]) throws -> [Float] {
        // Core ML hands back autoreleased buffers; without a pool they pile up in long-running processes.
        try autoreleasepool { try predict(tensors) }
    }

    private func predict(_ tensors: [[UInt8]]) throws -> [Float] {
        let n = side * side * 3
        var providers: [MLFeatureProvider] = []
        for t in tensors {
            guard t.count == n else { throw OutputFault() }
            let arr = try MLMultiArray(shape: [1, 3, NSNumber(value: side), NSNumber(value: side)], dataType: .float32)
            let p = arr.dataPointer.bindMemory(to: Float.self, capacity: n)
            for i in 0..<n { p[i] = Float(t[i]) }
            providers.append(try MLDictionaryFeatureProvider(dictionary: ["image": MLFeatureValue(multiArray: arr)]))
        }
        let out = try model.predictions(from: MLArrayBatchProvider(array: providers), options: MLPredictionOptions())
        var scores: [Float] = []
        for i in 0..<out.count {
            guard let probs = out.features(at: i).featureValue(for: "probs")?.multiArrayValue,
                  let k = probs.shape.last?.intValue, probs.shape.count <= 2, let top = flagIndices.max(), top < k else { throw OutputFault() }
            let twoD = probs.shape.count == 2
            scores.append(flagIndices.reduce(Float(0)) { s, c in
                s + probs[twoD ? [0, NSNumber(value: c)] : [NSNumber(value: c)]].floatValue
            })
        }
        return scores
    }
}

/// Why a set of models cannot judge: the rule it would run under would not be the one the detector promises.
public enum ModelSetFailure: Error, Equatable, Sendable {
    /// Two-family mode needs at least one model of family A and one of family B.
    case needsTwoFamilies
    /// Single-family mode needs every model in one family (A or B), and at least one.
    case needsOneFamily
    /// A tie-breaker only settles disputes between two families; a single-family set has none.
    case tieBreakerWithOneFamily
    /// A small-picture model (`Family.student`) can add a cover but is never a family of its own.
    case studentAsFamily
}

/// The models each place runs. Two families are required, unless the sealed bundle declares one family
/// (`singleFamily`), and then its flag alone covers, as under the Either rule, so fewer models never means less
/// covering.
public struct ModelSet {
    var models: [ScoringModel]
    var students: [ScoringModel]   // small-picture models (Stage 2), may be empty
    /// Asked only when the two families disagree; it may confirm a cover, never clear one.
    var referee: ScoringModel?
    public let bundleVersion: String
    /// One family only: its flag alone covers under every rule, and makes a window hot as both families' agreement
    /// would. Set only by a bundle that declares one family.
    public let singleFamily: Bool

    /// Checks that `models`, `students` and `referee` make a set the detector can judge with.
    static func check(models: [ScoringModel], referee: ScoringModel?, singleFamily: Bool) throws {
        if models.contains(where: { $0.family == .student }) { throw ModelSetFailure.studentAsFamily }
        let families = Set(models.map(\.family))
        if singleFamily {
            guard families.count == 1 else { throw ModelSetFailure.needsOneFamily }
            guard referee == nil else { throw ModelSetFailure.tieBreakerWithOneFamily }
        } else {
            guard families.isSuperset(of: [.a, .b]) else { throw ModelSetFailure.needsTwoFamilies }
        }
    }

    init(models: [ScoringModel], students: [ScoringModel] = [], referee: ScoringModel? = nil, bundleVersion: String,
         singleFamily: Bool = false) {
        precondition((try? Self.check(models: models, referee: referee, singleFamily: singleFamily)) != nil,
                     singleFamily ? "one model family is required" : "two model families are required")
        self.models = models; self.students = students; self.referee = referee; self.bundleVersion = bundleVersion
        self.singleFamily = singleFamily
    }

    /// A set of scorers from any runtime (`ScoringModel`): the family models, any small-picture models, and the
    /// tie-breaker. Refused, never trapped, when the families do not make a set the rule can run with.
    public init(scorers: [ScoringModel], students: [ScoringModel] = [], tieBreaker: ScoringModel? = nil,
                singleFamily: Bool = false, bundleVersion: String) throws {
        try Self.check(models: scorers, referee: tieBreaker, singleFamily: singleFamily)
        self.init(models: scorers, students: students, referee: tieBreaker, bundleVersion: bundleVersion, singleFamily: singleFamily)
    }

    /// The set a sealed bundle's manifest describes (`ModelManifest`). `compiled`: load the compiled models made by
    /// tools/make-app.sh (`x/x.mlmodelc`, checked by the caller), and nothing else. Otherwise load the packages
    /// (`x/x.mlpackage`, checked by the caller), each compiled once to a fixed place; `keys` names those compiled
    /// copies, by the package's path inside `d` (see `CompiledModels`). A compiled copy lying beside a package is
    /// never used in its place: only what was checked is loaded. Every model's shape is checked as it loads.
    public static func bundle(_ manifest: ModelManifest, directory d: URL, bundleVersion: String, compiled: Bool = false,
                              keys: [String: String] = [:]) throws -> ModelSet {
        try bundle(manifest, bundleVersion: bundleVersion) { m in
            switch m.runtime {
            case .coreml:
                return try CoreMLScoringModel(id: m.id, family: m.family, side: m.inputSide, flagIndices: m.flagClasses,
                                              url: locate(m.package, in: d, compiled: compiled), units: m.computeUnits.mlUnits,
                                              compiledKey: compiled ? nil : keys[m.package], classCount: m.classCount)
            }
        }
    }

    /// The set a manifest describes, each model made by `make`: the family models in the manifest's order, then the
    /// tie-breaker. The runtime seam: `make` is where a model is turned into a scorer.
    static func bundle(_ manifest: ModelManifest, bundleVersion: String,
                       make: (ModelManifest.Model) throws -> ScoringModel) throws -> ModelSet {
        let family = try manifest.models.filter { $0.slot != .tieBreaker }.map(make)
        let tie = try manifest.models.first { $0.slot == .tieBreaker }.map(make)
        return try ModelSet(scorers: family, tieBreaker: tie, singleFamily: manifest.families == 1, bundleVersion: bundleVersion)
    }

    /// Where a model is loaded from: the package's place (`x/x.mlpackage`), or for compiled models the same place
    /// with `.mlmodelc`.
    public static func locate(_ package: String, in d: URL, compiled: Bool) -> URL {
        let p = d.appendingPathComponent(package)
        return compiled ? p.deletingPathExtension().appendingPathExtension("mlmodelc") : p
    }

    /// The models' ids and roles, for tests and logs: no scorer, no score.
    var roster: [(id: String, family: Family, tieBreaker: Bool)] {
        models.map { ($0.id, $0.family, false) } + (referee.map { [($0.id, $0.family, true)] } ?? [])
    }
}

#if KESTREL_LAB
/// LAB ONLY (absent from release builds): a model that scores every picture 0, so that only the lab
/// stand-in can produce a cover. Lets the watcher pipeline run end to end with no model file at all.
final class LabNullModel: ScoringModel {
    let id: String, family: Family, side = 32
    init(id: String, family: Family) { self.id = id; self.family = family }
    func flagScores(_ tensors: [[UInt8]]) throws -> [Float] { tensors.map { _ in 0 } }
}

extension ModelSet {
    /// LAB ONLY: two null families and no tie-breaker.
    public static func labNull() -> ModelSet {
        ModelSet(models: [LabNullModel(id: "lab-null-a", family: .a), LabNullModel(id: "lab-null-b", family: .b)], bundleVersion: "lab-null")
    }
}
#endif
