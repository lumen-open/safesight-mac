// SPDX-License-Identifier: Apache-2.0
// The cover layer's side of the verdict contract (register SD-133): it calls `judge` once per window
// with that window's context, within the window's changed area, with its share of the budget, and
// reads back classes only. No score crosses this line.
import DetectorCore
import Foundation
import Preprocess

public protocol Judging: AnyObject {
    func judgeArea(_ frame: RGBAImage, context: JudgeContext, within area: PixelRect, budget: Int) -> FrameVerdict
    func setRule(_ rule: DetectorRule)
}

extension Detector: Judging {
    public func judgeArea(_ frame: RGBAImage, context: JudgeContext, within area: PixelRect, budget: Int) -> FrameVerdict {
        judge(frame, context: context, within: area, budget: budget)
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
