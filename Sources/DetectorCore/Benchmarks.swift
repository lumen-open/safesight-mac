// SPDX-License-Identifier: Apache-2.0
// Vendored from the kestrel lab detector (v3-detector, commit 49ecdd9) under Apache-2.0.
// Timing helpers for bench/ (milliseconds only; no scores are returned).
import CoreML
import Foundation
import Preprocess

public enum ModelTiming {
    public struct Result: Sendable { public var id: String; public var side: Int; public var msPerTileBatch1: Double; public var msPerTileBatch8: Double; public var loadMs: Double }

    /// Times one Core ML model file on the given compute units with spec-sized random tensors.
    public static func time(id: String, side: Int, url: URL, units: MLComputeUnits = .cpuAndNeuralEngine, runs: Int = 100) throws -> Result {
        let t0 = Date()
        let m = try CoreMLScoringModel(id: id, family: .a, side: side, flagIndices: [0], url: url, units: units)
        let load = Date().timeIntervalSince(t0) * 1000
        var g = XorShift32(seed: 5)
        let tensor = (0..<(3 * side * side)).map { _ in UInt8(truncatingIfNeeded: g.next()) }
        for _ in 0..<5 { _ = try m.flagScores([tensor]) }
        var t = Date()
        for _ in 0..<runs { _ = try m.flagScores([tensor]) }
        let b1 = Date().timeIntervalSince(t) * 1000 / Double(runs)
        let batch = Array(repeating: tensor, count: 8)
        _ = try m.flagScores(batch)
        t = Date()
        for _ in 0..<(runs / 8) { _ = try m.flagScores(batch) }
        let b8 = Date().timeIntervalSince(t) * 1000 / Double((runs / 8) * 8)
        return Result(id: id, side: side, msPerTileBatch1: b1, msPerTileBatch8: b8, loadMs: load)
    }
}
