// SPDX-License-Identifier: Apache-2.0
// Stage timings for the judging chain (part of SafeSight Mac, not the vendored lab build). Durations and
// counts only: no score, no cut-off and no pixel ever enters these records. They stay in memory and are
// read by the lab harness's bench; nothing writes them anywhere on its own.
import Foundation

@inline(__always) func nowNs() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
@inline(__always) func msSince(_ t0: UInt64) -> Double { Double(nowNs() &- t0) / 1_000_000 }

/// What one or more `judge` calls spent, by stage. Accumulates until `Detector.resetTimings()`.
public struct JudgeTimings: Sendable, Equatable {
    public var calls = 0
    /// The picture finder.
    public var finderMs = 0.0
    /// Hashing tile pixels for the verdict cache, and the lookups.
    public var cacheMs = 0.0
    /// Per model id: preprocessing (crop, resize, jitter) and inference.
    public var preprocessMs: [String: Double] = [:]
    public var inferenceMs: [String: Double] = [:]
    /// Per model id: pieces judged.
    public var tiles: [String: Int] = [:]
    /// Turning outcomes into classes (rules, hot contexts, containment).
    public var decisionMs = 0.0
    /// Whole `judge` calls, end to end.
    public var totalMs = 0.0
    public var cacheHits = 0
    public var cacheMisses = 0
    /// Calls whose picture-finder result was reused (every pixel the finder reads was the same).
    public var finderCacheHits = 0
    public var judgements = 0
    public var overloaded = 0
    /// Per model id: judgements the model failed (it threw or gave an unusable score; `Detector.usable`).
    public var modelFaults: [String: Int] = [:]
    public init() {}

    public mutating func add(_ o: JudgeTimings) {
        calls += o.calls; finderMs += o.finderMs; cacheMs += o.cacheMs; decisionMs += o.decisionMs; totalMs += o.totalMs
        cacheHits += o.cacheHits; cacheMisses += o.cacheMisses; finderCacheHits += o.finderCacheHits; judgements += o.judgements; overloaded += o.overloaded
        for (k, v) in o.preprocessMs { preprocessMs[k, default: 0] += v }
        for (k, v) in o.inferenceMs { inferenceMs[k, default: 0] += v }
        for (k, v) in o.tiles { tiles[k, default: 0] += v }
        for (k, v) in o.modelFaults { modelFaults[k, default: 0] += v }
    }

    /// Everything spent on models (preprocessing and inference, every model).
    public var modelsMs: Double { preprocessMs.values.reduce(0, +) + inferenceMs.values.reduce(0, +) }
}
