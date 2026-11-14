// SPDX-License-Identifier: Apache-2.0
// Vendored from the kestrel lab detector (v3-detector, commit 49ecdd9) under Apache-2.0.
// Scoring models. Internal to the module: scores never leave DetectorCore.
import CoreML
import Foundation
import Preprocess

public enum Family: String, Sendable, Codable { case a = "A-vit", b = "B-cnn", student = "student" }

protocol ScoringModel: AnyObject {
    var id: String { get }
    var family: Family { get }
    var side: Int { get }
    /// Flag scores (summed probability of the flag classes) for spec tensors [3][side][side].
    func flagScores(_ tensors: [[UInt8]]) throws -> [Float]
}

/// A Core ML model with input `image` [1][3][N][N] float (0..255) and output `probs`.
final class CoreMLScoringModel: ScoringModel {
    let id: String
    let family: Family
    let side: Int
    let flagIndices: [Int]
    private let model: MLModel

    init(id: String, family: Family, side: Int, flagIndices: [Int], url: URL, units: MLComputeUnits = .cpuAndNeuralEngine) throws {
        self.id = id; self.family = family; self.side = side; self.flagIndices = flagIndices
        let compiled = url.pathExtension == "mlmodelc" ? url : try MLModel.compileModel(at: url)
        let cfg = MLModelConfiguration()
        cfg.computeUnits = units
        model = try MLModel(contentsOf: compiled, configuration: cfg)
    }

    func flagScores(_ tensors: [[UInt8]]) throws -> [Float] {
        // Core ML hands back autoreleased buffers; without a pool they pile up in long-running processes.
        try autoreleasepool { try predict(tensors) }
    }

    private func predict(_ tensors: [[UInt8]]) throws -> [Float] {
        let n = side * side * 3
        var providers: [MLFeatureProvider] = []
        for t in tensors {
            precondition(t.count == n)
            let arr = try MLMultiArray(shape: [1, 3, NSNumber(value: side), NSNumber(value: side)], dataType: .float32)
            let p = arr.dataPointer.bindMemory(to: Float.self, capacity: n)
            for i in 0..<n { p[i] = Float(t[i]) }
            providers.append(try MLDictionaryFeatureProvider(dictionary: ["image": MLFeatureValue(multiArray: arr)]))
        }
        let out = try model.predictions(from: MLArrayBatchProvider(array: providers), options: MLPredictionOptions())
        return (0..<out.count).map { i in
            let probs = out.features(at: i).featureValue(for: "probs")!.multiArrayValue!
            return flagIndices.reduce(Float(0)) { $0 + probs[[0, NSNumber(value: $1)] as [NSNumber]].floatValue }
        }
    }
}

/// The models each place runs. Two families are required everywhere.
public struct ModelSet {
    var models: [ScoringModel]
    var students: [ScoringModel]   // small-picture models (Stage 2), may be empty
    /// Asked only when the two families disagree; it may confirm a cover, never clear one.
    var referee: ScoringModel?
    public let bundleVersion: String

    init(models: [ScoringModel], students: [ScoringModel] = [], referee: ScoringModel? = nil, bundleVersion: String) {
        precondition(Set(models.map(\.family)).isSuperset(of: [.a, .b]),
                     "two model families are required")
        self.models = models; self.students = students; self.referee = referee; self.bundleVersion = bundleVersion
    }

    /// The standard screen-watcher set: Marqo (A) and NSFWJS (B) on the Neural Engine, Bumble as the
    /// referee for disagreements (float32 on the GPU; its float16 build failed parity). `referee: false`
    /// gives the browser-like set, where disputes are blurred instead.
    /// `familyB` picks the family-B model: NSFWJS today, or the screen-aware model from the cloud run
    /// (`kestrel-screen-b-224`, classes [NSFW, SFW]) once Stage 3 has converted it.
    public static func watcher(directory d: URL, bundleVersion: String, referee: Bool = true,
                               familyB: String = "nsfwjs-mobilenet-v2") throws -> ModelSet {
        let b: ScoringModel = familyB == "nsfwjs-mobilenet-v2"
            ? try CoreMLScoringModel(id: familyB, family: .b, side: 224, flagIndices: [1, 3],
                                     url: d.appendingPathComponent("nsfwjs-mobilenet-v2/nsfwjs-mobilenet-v2.mlpackage"))
            : try CoreMLScoringModel(id: familyB, family: .b, side: 224, flagIndices: [0],
                                     url: d.appendingPathComponent("\(familyB)/\(familyB).mlpackage"))
        return try ModelSet(models: [
            CoreMLScoringModel(id: "marqo-vit-tiny-384", family: .a, side: 384, flagIndices: [0],
                               url: d.appendingPathComponent("marqo-vit-tiny-384/marqo-vit-tiny-384.mlpackage")),
            b,
        ], referee: referee ? try CoreMLScoringModel(id: "bumble-private-detector", family: .b, side: 480, flagIndices: [0],
                               url: d.appendingPathComponent("bumble-private-detector/bumble-private-detector.fp32.mlpackage"), units: .cpuAndGPU) : nil,
           bundleVersion: bundleVersion)
    }

    /// Measurement option: Marqo + Bumble (float32 on the GPU; its float16 Neural Engine build failed parity).
    public static func watcherWithBumble(directory d: URL, bundleVersion: String) throws -> ModelSet {
        try ModelSet(models: [
            CoreMLScoringModel(id: "marqo-vit-tiny-384", family: .a, side: 384, flagIndices: [0],
                               url: d.appendingPathComponent("marqo-vit-tiny-384/marqo-vit-tiny-384.mlpackage")),
            CoreMLScoringModel(id: "bumble-private-detector", family: .b, side: 480, flagIndices: [0],
                               url: d.appendingPathComponent("bumble-private-detector/bumble-private-detector.fp32.mlpackage"), units: .cpuAndGPU),
        ], bundleVersion: bundleVersion)
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
