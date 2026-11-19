// SPDX-License-Identifier: Apache-2.0
// LAB ONLY (absent from release builds): how far the deliberate jitter moves each model's score, for setting
// the clean-cache margin (`VerdictCache`). Each entry is judged many times, each time with fresh jitter on every
// piece, exactly as `topScore` judges it, and each model's top score per judgement is handed back. Scores
// leave the module only here, only in lab builds, for measurement on harmless pictures.
#if KESTREL_LAB
import Foundation
import Preprocess

extension Detector {
    /// An entry the first call over an area would judge: a finder region, the whole pass or a slice.
    public struct LabEntry: Sendable {
        public var pass: JudgePass
        public var rect: PixelRect
        /// Whether a blur can apply to it (a picture region under `max(containBelow, hotBelow)`), so the
        /// containment cut-off acts on it as well as the cover cut-off.
        public var containable: Bool
    }

    /// The entries `judge` builds for `area` (the whole frame when nil), in its order, with no anchor.
    public func labEntries(_ frame: RGBAImage, within area: PixelRect? = nil) -> [LabEntry] {
        let A = area?.clamped(width: frame.width, height: frame.height) ?? PixelRect(x: 0, y: 0, w: frame.width, h: frame.height)
        let found = finder.find(frame, within: A)
        var out = found.regions.map { LabEntry(pass: .region, rect: $0.rect, containable: $0.rect.shortSide < max(config.containBelow, config.hotBelow)) }
        out.append(LabEntry(pass: .whole, rect: A, containable: false))
        out += Self.slices(A, size: config.sliceSize, stride: config.sliceStride).map { LabEntry(pass: .slice, rect: $0, containable: false) }
        return out
    }

    /// The scoring models' ids (the two families, then any small-picture models), and the tie-breaker's.
    public var labModelIDs: [String] { models.models.map(\.id) + models.students.map(\.id) }
    public var labRefereeID: String? { models.referee?.id }

    /// A model's cover and containment cut-offs for a short side (the sealed table's band).
    public func labCutoffs(model: String, shortSide: Int) -> (cover: Float, clean: Float) {
        let c = table.cutoffs(model: model, band: Band(shortSide: shortSide))
        return (c.cover, c.clean)
    }

    /// Judges each of `rects` `draws` times with each model in `ids` (default: every scoring model; the
    /// tie-breaker only if named), with fresh jitter on every piece of every draw, as `topScore` does. Returns,
    /// per rect, each model's top score over the pieces, per draw; a model that failed or gave an unusable score
    /// on a rect is left out for it. Preprocessing runs on all cores, and the tensors are scored in batches (the
    /// same scores as one at a time). Seeds come from the system random source, as in `topScore`.
    public func labJitterDraws(_ frame: RGBAImage, rects: [PixelRect], draws: Int, ids: [String]? = nil) -> [[String: [Float]]] {
        let all = models.models + models.students + (models.referee.map { [$0] } ?? [])
        let wanted = ids ?? labModelIDs
        let pieces = rects.map { Self.pieces($0) }
        var out = [[String: [Float]]](repeating: [:], count: rects.count)
        // Jobs: (rect, draw, piece), grouped so that a batch holds at most about 96 tensors.
        var groups: [[Int]] = [[]]
        var inGroup = 0
        for i in rects.indices {
            let n = draws * pieces[i].count
            if inGroup > 0 && inGroup + n > 96 { groups.append([]); inGroup = 0 }
            groups[groups.count - 1].append(i); inGroup += n
        }
        for m in all where wanted.contains(m.id) {
            let side = m.side
            for g in groups where !g.isEmpty {
                var jobs: [(rect: Int, piece: PixelRect)] = []
                for i in g { for _ in 0..<draws { for p in pieces[i] { jobs.append((i, p)) } } }
                var seeds: [UInt32] = []
                for _ in jobs.indices { seeds.append(UInt32.random(in: 1...UInt32.max, using: &rng)) }
                var tensors = [[UInt8]](repeating: [], count: jobs.count)
                tensors.withUnsafeMutableBufferPointer { buf in
                    let base = buf.baseAddress!
                    DispatchQueue.concurrentPerform(iterations: jobs.count) { k in
                        base[k] = (try? Preprocessor.run(frame, rect: jobs[k].piece, side: side, jitterSeed: seeds[k])) ?? []
                    }
                }
                guard tensors.allSatisfy({ !$0.isEmpty }), let s = try? m.flagScores(tensors), s.count == jobs.count else { continue }
                var k = 0
                for i in g {
                    var top: [Float] = []
                    var ok = true
                    for _ in 0..<draws {
                        let v = s[k..<(k + pieces[i].count)]
                        if !v.allSatisfy(Self.usable) { ok = false }
                        top.append(v.max()!)
                        k += pieces[i].count
                    }
                    if ok { out[i][m.id] = top }
                }
            }
        }
        return out
    }

    /// The same jittered tensors scored in one batch and one at a time, for each scoring model: the largest
    /// difference over `draws` draws of `rect` (checks that batching, used only for measuring, changes nothing).
    public func labBatchParity(_ frame: RGBAImage, rect: PixelRect, draws: Int) -> [String: Float] {
        var out: [String: Float] = [:]
        for m in models.models + models.students {
            let p = Self.pieces(rect)[0]
            var tensors: [[UInt8]] = []
            for _ in 0..<draws {
                guard let t = try? Preprocessor.run(frame, rect: p, side: m.side, jitterSeed: UInt32.random(in: 1...UInt32.max, using: &rng)) else { return [:] }
                tensors.append(t)
            }
            guard let batch = try? m.flagScores(tensors), batch.count == draws else { continue }
            var worst: Float = 0
            for (i, t) in tensors.enumerated() {
                guard let one = try? m.flagScores([t]), one.count == 1 else { worst = .infinity; break }
                worst = max(worst, abs(one[0] - batch[i]))
            }
            out[m.id] = worst
        }
        return out
    }
}
#endif
