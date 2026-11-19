// SPDX-License-Identifier: Apache-2.0
// Every display, one rule (register SD-111, SD-112; chapter 05, sections 5.13 and 5.14). The owner's requirement:
// attaching another display, however it is attached, must never be a way to see unjudged content.
//
// The rule, fail-closed: every display the OS lists gets a canvas, and that canvas covers the display whole unless
// a judged plan for exactly that display, at its current bounds, from a capture stream started after the last
// display change, says otherwise. The OS's own lists decide which displays exist and how many are judged
// (`DISPLAYS_MAX`); the capture layer's list can add a display, never remove one.
//
// Pure: no AppKit and no ScreenCaptureKit. The app reads the OS's lists (SafeSightMacCover.SystemDisplays) and
// hands them in; tests hand in fakes.
import CoreGraphics
import Foundation

/// Stream generations. Every start of capture streams takes the next number, and every frame carries its stream's
/// number. A display change raises the number a display's frames must have, so a frame captured before the change
/// (or judged while it happened) can never lower a cover drawn because of it. Thread-safe.
public final class GenerationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    public init() {}
    /// The newest generation handed out so far.
    public var current: Int { lock.withLock { value } }
    /// Hands out a new, higher generation.
    public func next() -> Int { lock.withLock { value += 1; return value } }
}

/// What one CoreGraphics display reconfiguration callback says (CGDisplayRegisterReconfigurationCallback).
public enum DisplayChange: Equatable, Sendable {
    /// `kCGDisplayBeginConfigurationFlag`: macOS is about to apply a change. Every display is covered whole at once.
    case willChange
    /// The change has been applied; this call is one display's part of it (added, removed, moved, a new mode,
    /// mirrored or not). The displays are read again and capture restarts once the change has settled.
    case didChange

    public init(flags: CGDisplayChangeSummaryFlags) {
        self = flags.contains(.beginConfigurationFlag) ? .willChange : .didChange
    }
}

/// Mirror sets: a display that repeats another (`CGDisplayMirrorsDisplay`) shows that display's composited picture.
public enum MirrorSets {
    /// The display at the root of `id`'s mirror set: follow "repeats" until a display that repeats no other. Nil when
    /// the chain loops, which never happens in a real mirror set; the caller then treats `id` as its own display.
    public static func root(of id: UInt32, mirrorOf: (UInt32) -> UInt32?) -> UInt32? {
        var r = id, seen: Set<UInt32> = [id]
        while let s = mirrorOf(r), s != r {
            guard seen.insert(s).inserted else { return nil }
            r = s
        }
        return r
    }

    /// The display `id` repeats, believed only where it is plausible. Members of a mirror set share their source's
    /// place in global coordinates: the same origin or, with a hardware matte, a place inside the source's bounds. A
    /// display placed anywhere else is its own display, whatever `mirrorOf` says (a stale value around un-mirroring,
    /// say), and so is one whose bounds cannot be read. Any doubt means it is covered by a canvas of its own.
    public static func source(of id: UInt32, mirrorOf: (UInt32) -> UInt32?, bounds: (UInt32) -> CGRect) -> UInt32? {
        guard let s = mirrorOf(id), s != id else { return nil }
        let b = bounds(id), sb = bounds(s)
        guard DisplayList.usable(b), DisplayList.usable(sb) else { return nil }
        let sameOrigin = abs(b.minX - sb.minX) <= 0.5 && abs(b.minY - sb.minY) <= 0.5
        return sameOrigin || sb.insetBy(dx: -0.5, dy: -0.5).contains(b) ? s : nil
    }
}

/// The displays as the OS lists them now: AppKit's screens and CoreGraphics' active list, with CoreGraphics' online
/// list for mirror sets and, as a cross-check only, ScreenCaptureKit's list.
public struct DisplayList: Equatable, Sendable {
    /// One `NSScreen`: its display identifier (`NSScreenNumber`) and its frame in Cocoa points.
    public struct Screen: Equatable, Sendable {
        public let id: UInt32
        public let frame: CGRect
        public init(id: UInt32, frame: CGRect) { self.id = id; self.frame = frame }
    }

    /// Every display a cover canvas is drawn on: the main display first, then by identifier.
    public let displays: [DisplayDescriptor]
    /// Displays that repeat another display's pixels (a mirror set: hardware mirroring, AirPlay mirroring), keyed by
    /// the display they repeat. They get no canvas and no judging of their own: what they show is their source's
    /// composited picture, covers included.
    public let mirrors: [UInt32: UInt32]
    /// Displays listed with no usable bounds. Nothing can be drawn on them; they are kept so they can be reported.
    public let unplaced: [UInt32]
    /// The main display, as CoreGraphics names it (the one with the menu bar).
    public let main: UInt32

    public init(displays: [DisplayDescriptor], mirrors: [UInt32: UInt32] = [:], unplaced: [UInt32] = [], main: UInt32) {
        self.displays = displays; self.mirrors = mirrors; self.unplaced = unplaced; self.main = main
    }

    public static let empty = DisplayList(displays: [], main: 0)

    public var ids: [UInt32] { displays.map(\.id) }

    /// The displays that are judged: the first `DISPLAYS_MAX` of this list, counted from the OS's own lists, never
    /// from what the capture layer reports. Every other display is covered whole.
    public var judged: [UInt32] { Array(displays.prefix(Register.DISPLAYS_MAX).map(\.id)) }

    public func descriptor(_ id: UInt32) -> DisplayDescriptor? { displays.first { $0.id == id } }

    /// Merges the OS's lists.
    /// - A display may show something when CoreGraphics lists it as active, AppKit lists it as a screen, or
    ///   ScreenCaptureKit lists it (which can add a display, never take one away).
    /// - A display that repeats another (`mirrorOf`) and shares its place in global coordinates (`MirrorSets.source`),
    ///   whose mirror set's root is such a display, is a mirror: no canvas, no judging and no stream of its own; the
    ///   window system draws the root's windows, covers included, into it. This holds whether CoreGraphics lists it as
    ///   active (software mirroring) or only as online (hardware mirroring).
    /// - Every other such display gets a canvas, including one CoreGraphics says repeats another but which is placed
    ///   elsewhere: any doubt means a canvas.
    /// - Bounds are CoreGraphics' (`bounds`, global points); a display CoreGraphics gives no bounds for is placed by
    ///   its screen frame. A display with neither is `unplaced`.
    public static func make(screens: [Screen], active: [UInt32], online: [UInt32] = [], capture: [UInt32] = [],
                            main: UInt32, primaryHeight: CGFloat,
                            bounds: (UInt32) -> CGRect, mirrorOf: (UInt32) -> UInt32?) -> DisplayList {
        let shown = Set(active).union(screens.map(\.id)).union(capture)
        // A mirror relationship counts only where the display shares its source's place (`MirrorSets.source`).
        func repeats(_ id: UInt32) -> UInt32? { MirrorSets.source(of: id, mirrorOf: mirrorOf, bounds: bounds) }
        var mirrors: [UInt32: UInt32] = [:]
        for id in shown.union(online) {
            if let r = MirrorSets.root(of: id, mirrorOf: repeats), r != id, shown.contains(r) { mirrors[id] = r }
        }
        let drawn = shown.subtracting(mirrors.keys)

        var placed: [DisplayDescriptor] = [], unplaced: [UInt32] = []
        for id in drawn {
            var b = bounds(id)
            if !usable(b), let s = screens.first(where: { $0.id == id }) {
                b = CoordinateSpace.toGlobal(cocoa: s.frame, primaryHeight: primaryHeight)
            }
            if usable(b) { placed.append(DisplayDescriptor(id: id, bounds: b)) } else { unplaced.append(id) }
        }
        // The main display first; when the main display is a mirror, the display at its set's root.
        let first = mirrors[main] ?? main
        placed.sort { ($0.id == first ? 0 : 1, $0.id) < ($1.id == first ? 0 : 1, $1.id) }
        return DisplayList(displays: placed, mirrors: mirrors, unplaced: unplaced.sorted(), main: main)
    }

    static func usable(_ r: CGRect) -> Bool {
        r.hasArea && [r.minX, r.minY, r.width, r.height].allSatisfy(\.isFinite)
    }
}

/// Why every display is held covered whole. Each reason is released only by its own counterpart, so a display change
/// that finishes while the Mac is going to sleep does not end the sleep hold.
public enum HoldReason: Hashable, Sendable, CaseIterable {
    /// macOS announced a display change that has not finished (or the display lists could not be read).
    case change
    /// The Mac is going to sleep, or asleep.
    case sleep
    /// The displays are asleep.
    case displaysAsleep
    /// The session is switched away.
    case session
}

/// Which plan each display shows. Owned by the main thread; the cover coordinator draws `shown()`.
///
/// Fail-closed, display by display:
/// - every display in the list is covered whole unless a plan has been accepted for it;
/// - a plan is accepted only for a judged display (within `DISPLAYS_MAX`, counted from the list), at the display's
///   current bounds, from a stream generation at or above the display's `required` one, and never while a change is
///   held (announced but not finished, sleep, the session away);
/// - every change raises `required` for every display to the next generation, and forgets every accepted plan, so
///   nothing judged before the change (or while it happened) is shown after it.
public final class DisplayCoverage {
    public let generations: GenerationCounter
    /// The OS's display list as last read.
    public private(set) var list: DisplayList = .empty
    /// The reasons every display is held covered whole; while any is set, no plan is accepted.
    public private(set) var holds: Set<HoldReason> = []
    /// When an announced change that never finishes is treated as finished (the `.change` hold only).
    public private(set) var holdEnds: TimeInterval?
    /// Why every display is covered whole right now, if it is held.
    public var hold: FaultCause? { holds.isEmpty ? nil : .displayChanging }
    /// Per display: frames from streams older than this generation never lower its cover.
    public private(set) var required: [UInt32: Int] = [:]
    /// The plan accepted for each display since its last change, and the stream generation it was made from.
    public private(set) var accepted: [UInt32: CoverPlan] = [:]
    public private(set) var acceptedGeneration: [UInt32: Int] = [:]
    /// Why a display without an accepted plan is covered: a fault from the capture layer, a change, or not judged yet.
    public private(set) var causes: [UInt32: FaultCause] = [:]
    /// The detector could not load: every display is covered whole, including displays that appear later.
    public var detectorFailed = false

    public init(generations: GenerationCounter = GenerationCounter()) { self.generations = generations }

    /// Starts over with this list (start, Try again): every display is covered whole until its first judged frame.
    public func reset(_ new: DisplayList) {
        holds = []; holdEnds = nil
        list = new; forget(); causes = [:]
        raise(list.ids, cause: .notYetJudged)
    }

    /// macOS announced a change, the Mac or its displays are going to sleep, or the session is going away: every
    /// display is covered whole at once, and no plan lowers a cover until every reason is released. `until` (for
    /// `.change` only) ends an announced change that never finishes.
    public func hold(_ reason: HoldReason = .change, until: TimeInterval? = nil) {
        holds.insert(reason)
        if reason == .change { holdEnds = until }
        forget()
        raise(list.ids, cause: .displayChanging)
    }

    /// One reason is over (the change is done, the Mac or its displays woke, the session came back), and the displays
    /// are now `new`. Every display stays covered whole until a judged frame from a stream started after this moment,
    /// and while any other reason holds.
    public func release(_ reason: HoldReason = .change, _ new: DisplayList) {
        holds.remove(reason)
        if reason == .change { holdEnds = nil }
        list = new; forget()
        raise(list.ids, cause: .displayChanging)
    }

    /// A fresh reading of the OS's lists with no announcement. When it differs from the last one (a display came or
    /// went, moved, changed size or mirroring, or the main display changed), it is a change nobody announced and is
    /// handled like one: every display is covered whole until judged again. A hold in progress stays. Returns true
    /// when the list changed.
    @discardableResult
    public func update(_ new: DisplayList) -> Bool {
        guard new != list else { return false }
        list = new; forget()
        raise(list.ids, cause: .displayChanging)
        return true
    }

    /// A reading that may only add displays the capture layer listed. An addition that leaves the judged displays as
    /// they were (the added displays are past `DISPLAYS_MAX`) is not a change: each added display is covered whole, and
    /// the others keep their plans. Anything else, including an addition that changes which displays are judged (an
    /// added display needs a stream, and one it pushes past the limit must lose its own), is handled by `update`.
    /// Returns true when it was a change.
    @discardableResult
    public func add(_ new: DisplayList) -> Bool {
        let added = new.ids.filter { list.descriptor($0) == nil }
        let kept = DisplayList(displays: new.displays.filter { list.descriptor($0.id) != nil }, mirrors: new.mirrors,
                               unplaced: new.unplaced, main: new.main)
        guard !added.isEmpty, kept == list, new.judged == list.judged else { return update(new) }
        list = new
        raise(added, cause: .notYetJudged)
        return false
    }

    /// A plan from the judging queue, made from a frame of stream `generation`. Returns true when it is accepted.
    @discardableResult
    public func accept(_ plan: CoverPlan, generation: Int) -> Bool {
        let id = plan.display.id
        guard holds.isEmpty, !detectorFailed, list.judged.contains(id),
              let d = list.descriptor(id), d.bounds == plan.display.bounds,
              let need = required[id], generation >= need else { return false }
        accepted[id] = plan
        acceptedGeneration[id] = generation
        causes[id] = nil
        return true
    }

    /// The display has no stream for request or stream `generation`: a start or top-up of that generation could not
    /// give it one (`noStream`, `noPermissionOrNoContent`), or its stream stopped by itself (`streamStopped`, whose
    /// frames then never lower the cover again). The display is covered whole, unless the plan it shows came from a
    /// newer stream than the report is about: that stream is running, or its own end is reported too.
    public func fault(_ id: UInt32, _ cause: FaultCause, generation g: Int) {
        if cause == .streamStopped { required[id] = max(required[id] ?? 0, g + 1) }
        if let shownFrom = acceptedGeneration[id], shownFrom > g { return }
        accepted[id] = nil; acceptedGeneration[id] = nil
        causes[id] = cause
    }

    /// A stream of this generation was stopped on purpose (a newer start, a newer stream for the display, pause). Its
    /// frames never count again. If the plan shown came from it, or from an older stream, the display is covered
    /// whole until a newer stream's frame is judged.
    public func retire(_ id: UInt32, generation g: Int) {
        required[id] = max(required[id] ?? 0, g + 1)
        guard let shownFrom = acceptedGeneration[id], shownFrom <= g else { return }
        accepted[id] = nil; acceptedGeneration[id] = nil
        causes[id] = .notYetJudged
    }

    /// A new capture request: the generation its streams carry. A display change after this always outranks it.
    public func newRequest() -> Int { generations.next() }

    /// What every display shows now: exactly one plan per listed display. `stalled`: displays whose judging has fallen
    /// too far behind (`JUDGING_STALL`), covered whole until they catch up.
    /// `unjudged`: areas whose change has waited too long to be judged (`WAITING_FRAME_COVER`), covered plainly on top of
    /// the display's plan until it is judged.
    public func shown(stalled: Set<UInt32> = [], unjudged: [UInt32: [CGRect]] = [:]) -> [CoverPlan] {
        let judged = Set(list.judged)
        return list.displays.map { d in
            if detectorFailed { return .covered(d, because: .detectorUnavailable) }
            if let h = hold { return .covered(d, because: h) }
            guard judged.contains(d.id) else { return .covered(d, because: .tooManyDisplays) }
            if stalled.contains(d.id) { return .covered(d, because: .judgingBehind) }
            if var p = accepted[d.id], p.display.bounds == d.bounds {
                for r in unjudged[d.id] ?? [] where r.intersection(d.bounds).hasArea {
                    p.items.append(CoverItem(rect: r.intersection(d.bounds), kind: .plain))
                }
                return p
            }
            return .covered(d, because: causes[d.id] ?? .notYetJudged)
        }
    }

    private func forget() { accepted = [:]; acceptedGeneration = [:] }

    /// Frames for these displays must come from a stream started from now on.
    private func raise(_ ids: [UInt32], cause: FaultCause) {
        let next = generations.current + 1
        for id in ids {
            required[id] = max(required[id] ?? 0, next)
            causes[id] = cause
        }
    }
}
