// SPDX-License-Identifier: Apache-2.0
// Vendored from the kestrel lab detector (v3-detector, commit 49ecdd9) under Apache-2.0.
// A tiny photo-versus-interface network over six cell statistics. It runs only on cells the
// colour rule rejected and may only ADD cells. Its weights are trained offline on harmless
// pictures (eval-tools/train_cellnet.py) and written to CellNetWeights.swift.
import Foundation

public struct CellNet: Sendable {
    public static let inputCount = 6
    public let w1: [Float]  // hidden x input
    public let b1: [Float]
    public let w2: [Float]  // hidden
    public let b2: Float
    public let threshold: Float
    public init(w1: [Float], b1: [Float], w2: [Float], b2: Float, threshold: Float) {
        self.w1 = w1; self.b1 = b1; self.w2 = w2; self.b2 = b2; self.threshold = threshold
    }

    @inline(__always) public func logit(_ x: [Float]) -> Float {
        var out = b2
        let n = Self.inputCount
        for h in 0..<b1.count {
            var a = b1[h]
            for i in 0..<n { a += w1[h * n + i] * x[i] }
            out += w2[h] * max(0, a)
        }
        return out
    }

    @inline(__always) public func isPhoto(_ x: [Float]) -> Bool { logit(x) >= threshold }
}
