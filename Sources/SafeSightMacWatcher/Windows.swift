// SPDX-License-Identifier: Apache-2.0
// The window-list snapshot and how changed areas are split by window (sections 5.5 and C05-6).
// One `judge` call covers the visible part of exactly one window or system surface in one frame.
import CoreGraphics
import Foundation

/// One on-screen window, from CGWindowListCopyWindowInfo. Window titles are never read.
public struct WindowInfo: Equatable, Hashable, Sendable {
    public let number: UInt32
    public let ownerPID: Int32
    public let layer: Int
    /// Bounds in global points.
    public let bounds: CGRect
    /// The window's opacity (kCGWindowAlpha). A window at 0 shows nothing: it hides nothing behind it.
    public let alpha: Double
    public init(number: UInt32, ownerPID: Int32, layer: Int, bounds: CGRect, alpha: Double = 1) {
        self.number = number; self.ownerPID = ownerPID; self.layer = layer; self.bounds = bounds
        self.alpha = alpha.isFinite ? alpha : 1
    }

    /// True when the window can be seen at all. A fully transparent window is no judging target and hides nothing.
    public var shows: Bool { alpha > 0.001 }
}

/// A judging context: a window, or the part of a display no window covers (desktop, system surfaces).
public enum JudgeTarget: Equatable, Hashable, Sendable {
    case window(number: UInt32, ownerPID: Int32)
    case surface(display: UInt32)

    /// The stable 64-bit context identifier passed to `judge`: it keys the detector's hot store.
    /// For a window it is the owner process identifier and the window number (section 5.6).
    public var contextID: UInt64 {
        switch self {
        case let .window(n, pid): return (UInt64(UInt32(bitPattern: pid)) << 32) | UInt64(n)
        case let .surface(d): return (UInt64(0xFFFF_FFFF) << 32) | UInt64(d)
        }
    }
}

/// The part of one judging target that a changed area touches, and where that target is visible.
public struct TargetArea: Equatable, Sendable {
    public let target: JudgeTarget
    /// The changed parts that belong to this target, in global points.
    public var changed: [CGRect]
    /// Where this target is visible on the display, in global points: covers are clipped to it.
    public var visible: [CGRect]
}

/// Windows in front-to-back order, with the time the list was read.
public struct WindowSnapshot: Equatable, Sendable {
    public let windows: [WindowInfo]
    public let time: TimeInterval
    /// False when the window list could not be read. An unreadable list is a fault (the display is covered whole), never
    /// an empty screen.
    public let readable: Bool
    public init(windows: [WindowInfo], time: TimeInterval, readable: Bool = true) {
        self.windows = windows; self.time = time; self.readable = readable
    }
    public static let empty = WindowSnapshot(windows: [], time: 0)
    /// A window list that could not be read.
    public static func unreadable(time: TimeInterval) -> WindowSnapshot { WindowSnapshot(windows: [], time: time, readable: false) }

    /// Where each window is visible on `display`: its bounds minus every window in front of it.
    /// Windows of `ignoredPIDs` (the watcher and the app, whose windows are never covered and are left
    /// out of capture) are ignored, as the cover canvas is.
    public func visibleAreas(on display: CGRect, ignoring ignoredPIDs: Set<Int32>) -> [(JudgeTarget, [CGRect])] {
        var free: [CGRect] = [display]
        var out: [(JudgeTarget, [CGRect])] = []
        for w in windows where !ignoredPIDs.contains(w.ownerPID) && w.shows {
            let b = w.bounds.intersection(display)
            guard b.hasArea else { continue }
            let vis = free.clipped(to: b)
            if !vis.isEmpty { out.append((.window(number: w.number, ownerPID: w.ownerPID), vis)) }
            free = free.subtracting(b)
            if free.isEmpty { break }
        }
        if !free.isEmpty { out.append((.surface(display: 0), free)) }
        return out
    }

    /// Splits changed areas (global points) by window: each piece goes to the front-most window that
    /// shows it. Areas no window covers go to the display surface.
    public func split(changed: [CGRect], display: DisplayDescriptor, ignoring ignoredPIDs: Set<Int32>) -> [TargetArea] {
        var result: [TargetArea] = []
        for (target, vis) in visibleAreas(on: display.bounds, ignoring: ignoredPIDs) {
            let t: JudgeTarget
            if case .surface = target { t = .surface(display: display.id) } else { t = target }
            var parts: [CGRect] = []
            for c in changed { parts += vis.clipped(to: c) }
            if !parts.isEmpty { result.append(TargetArea(target: t, changed: parts, visible: vis)) }
        }
        return result
    }

    /// The visible area of one target, or nil if it is no longer on screen.
    public func visibleArea(of target: JudgeTarget, display: DisplayDescriptor, ignoring ignoredPIDs: Set<Int32>) -> [CGRect]? {
        for (t, vis) in visibleAreas(on: display.bounds, ignoring: ignoredPIDs) {
            switch (t, target) {
            case (.surface, .surface): return vis
            case let (.window(a, p), .window(b, q)) where a == b && p == q: return vis
            default: continue
            }
        }
        return nil
    }

    /// The window's bounds, if it is in this snapshot.
    public func bounds(of target: JudgeTarget) -> CGRect? { info(of: target)?.bounds }

    /// The window, if it is in this snapshot.
    public func info(of target: JudgeTarget) -> WindowInfo? {
        guard case let .window(n, pid) = target else { return nil }
        return windows.first { $0.number == n && $0.ownerPID == pid }
    }
}
