// SPDX-License-Identifier: Apache-2.0
// Energy: how hard the watcher works when the Mac runs on battery, in Low Power Mode or hot, and the budget the project
// holds itself to (docs/ENERGY.md).
//
// The one trade allowed: cover longer and judge later, never show sooner. Saving energy only slows the looks that let
// covers already up lift on a still screen. New pictures, changed pixels, faults and flags are handled exactly as at full
// power: judged at the full budget, blurred or covered while unjudged, covered whole when slow. A cover needs the same
// `VIDEO_VOTE` clean judgements to lift in every mode, and no cut-off or count changes.
import Foundation

public enum EnergyMode: String, Sendable, CaseIterable {
    /// On power, cool, Low Power Mode off.
    case full
    /// On battery.
    case battery
    /// Low Power Mode on, or the Mac is hot (thermal state serious or critical).
    case low

    /// Chooses the mode from what macOS says. The most saving reason wins.
    public static func from(onBattery: Bool, lowPowerMode: Bool, thermal: ProcessInfo.ThermalState) -> EnergyMode {
        if lowPowerMode || thermal == .serious || thermal == .critical { return .low }
        return onBattery ? .battery : .full
    }

    /// The share of the judging budget the looks at a still screen may use while only covers wait to lift (nothing new
    /// is left to judge). Work left over from new pictures always gets the full budget.
    public var settleRateScale: Double {
        switch self { case .full: return 1; case .battery: return 0.5; case .low: return 0.25 }
    }

    /// How long the watcher waits between looks at a still screen while only covers wait to lift (no new pictures left
    /// to judge). Each look has a fixed cost besides its judgements (the window split, finding pictures, hashing every
    /// picture for the cache), measured at most of a look's CPU time in the lab, so fewer, larger looks make the same
    /// judgements for less: at full power a look a second gets the 40 judgements four quarter-second looks got.
    public var lookEvery: TimeInterval {
        switch self { case .full: return 4 * Register.TICK; case .battery: return 8 * Register.TICK; case .low: return 16 * Register.TICK }
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
    /// Judgements a minute while a still screen settles: the judging budget, never more (the bucket's first burst
    /// aside), scaled down on battery, in Low Power Mode and when hot.
    public static func settlingJudgementsPerMinute(_ mode: EnergyMode) -> Double {
        Register.JUDGEMENT_BUDGET * 60 * mode.settleRateScale + Register.JUDGEMENT_BURST
    }
    /// The harness's still desktop settles within this long at full power (and this long divided by the mode's scale
    /// when saving).
    public static let SETTLE_WITHIN: TimeInterval = 300
    /// CPU seconds a simulated minute while the harness's still desktop settles, at full power.
    public static let SETTLING_CPU_SECONDS_PER_MINUTE = 30.0
    /// CPU seconds for the harness's reload of a judged busy page, until it rests again.
    public static let RELOAD_CPU_SECONDS = 15.0
    /// Share of one core while the harness's video plays (30 frames a second over a busy page).
    public static let VIDEO_CPU_SHARE = 1.0
    /// The capture callback's frame copy, a 2880 x 1800 frame, in ms.
    public static let FRAME_COPY_MS = 4.0

    public static var summary: [String: Any] {
        ["settledJudgementsPerMinute": SETTLED_JUDGEMENTS_PER_MINUTE, "settledLooksPerMinute": SETTLED_LOOKS_PER_MINUTE,
         "settledTimerWakeupsPerMinute": SETTLED_TIMER_WAKEUPS_PER_MINUTE,
         "settlingJudgementsPerMinute": Dictionary(uniqueKeysWithValues: EnergyMode.allCases.map { ($0.rawValue, settlingJudgementsPerMinute($0)) }),
         "settleWithinSeconds": SETTLE_WITHIN, "settlingCpuSecondsPerMinute": SETTLING_CPU_SECONDS_PER_MINUTE,
         "reloadCpuSeconds": RELOAD_CPU_SECONDS, "videoCpuShareOfOneCore": VIDEO_CPU_SHARE, "frameCopyMs2880x1800": FRAME_COPY_MS]
    }
}
