// SPDX-License-Identifier: Apache-2.0
// LAB ONLY (absent from release builds): parity for the conformance kit (spec/detector-contract.md, section 5). A
// model's flag scores on fixed harmless inputs, against reference outputs made by the framework it came from. Only
// the largest difference and a count leave, only in lab builds, for measurement on harmless pictures.
#if KESTREL_LAB
import CoreML
import Foundation

public enum LabParity {
    public struct Result: Sendable {
        /// The largest difference in flag score on any input.
        public var maxDiff: Float
        /// Inputs within the tolerance.
        public var within: Int
        public var count: Int
        public var pass: Bool { within == count && count > 0 }
    }

    /// Runs `model` (its package at `url`, shape-checked as it loads) on `units` over `tensors`, in batches of 8, and
    /// compares each flag score with `reference`. `swapRedBlue` swaps the first and third planes of every tensor first:
    /// the kit's own broken control, which must fail.
    public static func run(_ model: ModelManifest.Model, url: URL, units: ModelManifest.Units, tensors: [[UInt8]],
                           reference: [Float], tolerance: Float, swapRedBlue: Bool = false) throws -> Result {
        precondition(tensors.count == reference.count)
        let m = try CoreMLScoringModel(id: model.id, family: model.family, side: model.inputSide, flagIndices: model.flagClasses,
                                       url: url, units: units.mlUnits, classCount: model.classCount)
        let plane = model.inputSide * model.inputSide
        var r = Result(maxDiff: 0, within: 0, count: tensors.count)
        var i = 0
        while i < tensors.count {
            var batch = Array(tensors[i..<min(i + 8, tensors.count)])
            if swapRedBlue {
                for k in batch.indices { for p in 0..<plane { batch[k].swapAt(p, 2 * plane + p) } }
            }
            let s = try m.flagScores(batch)
            for (k, v) in s.enumerated() {
                let d = Detector.usable(v) ? abs(v - reference[i + k]) : .infinity
                r.maxDiff = max(r.maxDiff, d)
                if d <= tolerance { r.within += 1 }
            }
            i += batch.count
        }
        return r
    }
}
#endif
