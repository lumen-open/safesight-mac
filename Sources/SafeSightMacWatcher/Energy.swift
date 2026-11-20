// SPDX-License-Identifier: Apache-2.0
// Energy: how often the watcher looks at a still screen, on power, on battery, in Low Power Mode and when hot, and the
// budget the project holds itself to (docs/ENERGY.md).
//
// The one trade allowed is to cover longer and judge later, never to show sooner. What is changed here is only how often
// the watcher looks at the last frame while covers wait to lift on a still screen. New pictures, changed pixels, faults
// and flags are handled exactly the same in every mode, at the full judging budget; a cover needs the same `VIDEO_VOTE`
// clean judgements to lift, and no cut-off or count changes.
//
// Measured in the lab (docs/ENERGY.md): a look has a fixed cost besides its judgements (the window split, finding pictures,
// hashing every picture for the cache), so fewer looks with the same budget each make the same judgements for less CPU.
// Giving the settling a smaller share of the budget did the opposite: a still desktop took longer to settle and cost
// more in total (the re-checks that come round every 30 s kept coming), and at a quarter of the budget it did not
// settle in 20 minutes. So no mode lowers the budget.
import Foundation

public enum EnergyMode: String, Sendable, CaseIterable {
    /// On power, or on battery, cool, Low Power Mode off.
    case full
    /// On battery. The same as `full` today: the measured settings that cost least in total are already `full`'s.
    case battery
    /// Low Power Mode on, or the Mac is hot (thermal state serious or critical): fewer looks still, for less power at
    /// any moment.
    case low

    /// Chooses the mode from what macOS says. The most saving reason wins.
    public static func from(onBattery: Bool, lowPowerMode: Bool, thermal: ProcessInfo.ThermalState) -> EnergyMode {
        if lowPowerMode || thermal == .serious || thermal == .critical { return .low }
        return onBattery ? .battery : .full
    }

    /// How long the watcher waits between looks at a still screen while only covers wait to lift (no new pictures left
    /// to judge; with some left, it looks every `Register.TICK`). Each look is given what the budget gathered since the
    /// last, so the judgements a second are the same; only the looks' fixed cost is paid less often.
    public var lookEvery: TimeInterval {
        switch self { case .full, .battery: return 4 * Register.TICK; case .low: return 8 * Register.TICK }
    }
}

/// The energy budget: figures the project holds itself to. The harness (`safesightmac-harness energy --check`) and the
/// tests (`EnergyBudgetTests`) fail when one is exceeded. CPU figures are for the reference Mac (Apple M1 Max) on the
/// harness's simulated clock and say nothing about the Neural Engine, the GPU or battery drain; see docs/ENERGY.md.
public enum EnergyBudget {
    /// A settled still screen (nothing drawn, nothing left to judge): no judgement at all.
    public static let SETTLED_JUDGEMENTS_PER_MINUTE = 0
    /// A settled still screen: no look asked for by the pipeline. What still wakes the watcher there is the quarter-second
    /// check (`Register.TICK`) and any frame the capture sends.
    public static let SETTLED_LOOKS_PER_MINUTE = 0
    /// The quarter-second check is the only timer at a settled screen: 240 wake-ups a minute.
    public static let SETTLED_TIMER_WAKEUPS_PER_MINUTE = Int(60 / Register.TICK)
    /// Judgements charged to the budget over a still screen's settling: the judging budget, never more (the bucket's
    /// first burst aside), in every mode.
    public static func settlingJudgements(seconds: TimeInterval) -> Double {
        Register.JUDGEMENT_BUDGET * seconds + Register.JUDGEMENT_BURST
    }
    /// Looks a minute while covers wait to lift on a still screen with nothing new left over: at most one a second.
    public static let SETTLING_LOOKS_PER_MINUTE = 60
    /// The harness's still desktop settles within this long at full power and on battery (measured: 208 s)...
    public static let SETTLE_WITHIN: TimeInterval = 300
    /// ...and within this long in Low Power Mode or when hot, where the looks are rarer (measured: 389 s).
    public static func settleWithin(_ mode: EnergyMode) -> TimeInterval { mode == .low ? 2 * SETTLE_WITHIN : SETTLE_WITHIN }
    /// CPU seconds a simulated minute while the harness's still desktop settles, at full power (measured: 12.7).
    public static let SETTLING_CPU_SECONDS_PER_MINUTE = 18.0
    /// CPU seconds for the harness's reload of a judged busy page, until it rests again (measured: 0.2).
    public static let RELOAD_CPU_SECONDS = 2.0
    /// Share of one core while the harness's video plays (30 frames a second over a busy page; measured: 0.92).
    public static let VIDEO_CPU_SHARE = 1.0
    /// CPU time of the capture callback's frame copy, a 2880 x 1800 frame, in ms (measured: 1.9).
    public static let FRAME_COPY_CPU_MS = 3.0

    public static var summary: [String: Any] {
        ["settledJudgementsPerMinute": SETTLED_JUDGEMENTS_PER_MINUTE, "settledLooksPerMinute": SETTLED_LOOKS_PER_MINUTE,
         "settledTimerWakeupsPerMinute": SETTLED_TIMER_WAKEUPS_PER_MINUTE,
         "settlingJudgementsPerSecond": Register.JUDGEMENT_BUDGET, "settlingBurst": Register.JUDGEMENT_BURST,
         "settlingLooksPerMinute": SETTLING_LOOKS_PER_MINUTE,
         "settleWithinSeconds": Dictionary(uniqueKeysWithValues: EnergyMode.allCases.map { ($0.rawValue, settleWithin($0)) }), "settlingCpuSecondsPerMinute": SETTLING_CPU_SECONDS_PER_MINUTE,
         "reloadCpuSeconds": RELOAD_CPU_SECONDS, "videoCpuShareOfOneCore": VIDEO_CPU_SHARE, "frameCopyCpuMs2880x1800": FRAME_COPY_CPU_MS]
    }
}
