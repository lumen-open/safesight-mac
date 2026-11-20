// SPDX-License-Identifier: Apache-2.0
// The cover layer's side of the verdict contract (register SD-133): it calls `judge` once per window
// with that window's context, within the window's changed area, with its share of the budget, and
// reads back classes only. No score crosses this line.
import DetectorCore
import Foundation
import Preprocess

public protocol Judging: AnyObject {
    /// `progress` hears, before the call returns, what is still to be judged and any early flag of the
    /// fastest model (classes only); see `Detector.judge`.
    func judgeArea(_ frame: RGBAImage, context: JudgeContext, within area: PixelRect, budget: Int,
                   progress: ((JudgeProgress) -> Void)?) -> FrameVerdict
    func setRule(_ rule: DetectorRule)
    /// The pictures the finder sees in an area (no model runs), or nil when this judge cannot say.
    func pictureRegions(_ frame: RGBAImage, within area: PixelRect) -> [PixelRect]?
    /// Second clean checks in the background (`Detector.secondChecks`), or nil when this judge has none.
    func checkAgainInBackground(_ frame: RGBAImage, context: JudgeContext, within area: PixelRect, budget: Int) -> FrameVerdict?
}

extension Judging {
    public func pictureRegions(_ frame: RGBAImage, within area: PixelRect) -> [PixelRect]? { nil }
    public func checkAgainInBackground(_ frame: RGBAImage, context: JudgeContext, within area: PixelRect, budget: Int) -> FrameVerdict? { nil }

    public func judgeArea(_ frame: RGBAImage, context: JudgeContext, within area: PixelRect, budget: Int) -> FrameVerdict {
        judgeArea(frame, context: context, within: area, budget: budget, progress: nil)
    }
}

extension Detector: Judging {
    public func judgeArea(_ frame: RGBAImage, context: JudgeContext, within area: PixelRect, budget: Int,
                          progress: ((JudgeProgress) -> Void)?) -> FrameVerdict {
        judge(frame, context: context, within: area, budget: budget, progress: progress)
    }

    public func pictureRegions(_ frame: RGBAImage, within area: PixelRect) -> [PixelRect]? { pictures(frame, within: area) }

    public func checkAgainInBackground(_ frame: RGBAImage, context: JudgeContext, within area: PixelRect, budget: Int) -> FrameVerdict? {
        secondChecks(frame, context: context, within: area, budget: budget)
    }
}

/// A token bucket per display: filled at `JUDGEMENT_BUDGET` divided by the number of active displays,
/// at most `JUDGEMENT_BURST` deep. One token is one model judgement. There is no lending between displays.
public struct TokenBucket: Sendable {
    public private(set) var tokens: Double
    public var rate: Double
    public let depth: Double
    private var last: TimeInterval?

    public init(rate: Double, depth: Double = Register.JUDGEMENT_BURST) {
        self.rate = rate; self.depth = depth; self.tokens = depth
    }

    public mutating func refill(now: TimeInterval) {
        if let l = last, now > l { tokens = min(depth, tokens + (now - l) * rate) }
        last = now
    }

    /// Whole judgements available now.
    public var available: Int { Int(tokens.rounded(.down)) }

    public mutating func spend(_ n: Int) { tokens = max(0, tokens - Double(n)) }
}

/// Stage timings of one `DisplayPipeline.process` call, for the lab harness's bench. Durations and counts
/// only: no score, no pixel and no verdict detail.
public struct PipelineTimings: Sendable, Equatable {
    /// Preparing changed areas and splitting them by window.
    public var changeMs = 0.0
    /// Finding content that moved by a translation (scrolling) and moving covers with it.
    public var translateMs = 0.0
    /// Inside `judge` calls (the detector's own stages are in `JudgeTimings`).
    public var judgeMs = 0.0
    /// Turning classes into covers and building the plan.
    public var planMs = 0.0
    /// The whole call.
    public var totalMs = 0.0
    public var calls = 0
    public var judgements = 0
    public var overloaded = 0
    /// Judgements spent on second clean checks in the background (`DisplayPipeline`, step 3c); not in `judgements`.
    public var secondCheckJudgements = 0
    /// Whether this call stopped waiting for second clean checks because their bound passed (0 or 1).
    public var secondChecksGivenUp = 0
    /// Model failures reported by the judge calls (counts only; their entries are covered or blurred).
    public var modelFaults = 0
    /// Plans handed out before the final one (moved covers, cover-first blurs, fast-model blurs), with the
    /// time each was ready, from the start of the call.
    public var provisionalMs: [Double] = []
    /// New picture regions blurred first because judging them would overrun `COVER_GOAL`.
    public var coveredFirst = 0
    /// Pictures the fastest model flagged, shown blurred before the full rule decided.
    public var fastFlags = 0
    /// Changed parts blurred at once, before judging, because recent frames took longer than `COVER_GOAL` to judge.
    public var blurredAtOnce = 0
    /// Whether this call blurred large changed parts at once (0 or 1; for counting frames).
    public var blurAtOnceFirings = 0
    /// Parts of the frame left for the next call because this one reached `JUDGE_CALL_WALL` (blurred meanwhile).
    public var leftForLater = 0
    /// Covers judged on their own, over their whole rectangle (not all on show as their window's).
    public var rechecks = 0
    public init() {}

    static func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
    static func ms(since t: UInt64) -> Double { Double(DispatchTime.now().uptimeNanoseconds &- t) / 1_000_000 }
}
