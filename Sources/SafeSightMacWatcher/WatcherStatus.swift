// SPDX-License-Identifier: Apache-2.0
// The one status line the menu shows.
import SafeSightMacCore
import Foundation

public enum WatcherStatus: Equatable, Sendable {
    case needsScreenRecording
    case paused(until: Date?)
    case starting
    case on
    /// At least one display is covered whole because it cannot be judged.
    case displayCovered(FaultCause)
    case detectorUnavailable

    public static func compute(permission: Bool, paused: Date?, pausedIndefinitely: Bool, detectorFailed: Bool,
                               plans: [CoverPlan], running: Bool) -> WatcherStatus {
        if pausedIndefinitely { return .paused(until: nil) }
        if let p = paused { return .paused(until: p) }
        if !permission { return .needsScreenRecording }
        if detectorFailed { return .detectorUnavailable }
        if !running || plans.isEmpty { return .starting }
        if let c = plans.compactMap(\.wholeDisplay).first(where: { $0 != .notYetJudged }) { return .displayCovered(c) }
        if plans.allSatisfy({ $0.wholeDisplay == .notYetJudged }) { return .starting }
        return .on
    }

    public var title: String {
        switch self {
        case .needsScreenRecording: return AppText.statusNeedsPermission
        case .paused: return AppText.statusPaused
        case .starting: return AppText.statusStarting
        case .on: return AppText.statusOn
        case .displayCovered: return AppText.statusFault
        case .detectorUnavailable: return AppText.statusModelsMissing
        }
    }
}
