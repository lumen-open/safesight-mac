// SPDX-License-Identifier: Apache-2.0
// What the capture layer hands to the cover layer, and how changed areas are prepared (section 5.1).
import CoreGraphics
import Foundation
import Preprocess

/// A display, as the watcher knows it.
public struct DisplayDescriptor: Equatable, Hashable, Sendable {
    /// The system's display identifier at this moment. It can change on reconnect, so a new identifier
    /// always starts uncovered-and-unjudged and is covered whole until its first judged frame.
    public let id: UInt32
    /// Bounds in global points (CGDisplayBounds).
    public let bounds: CGRect
    public init(id: UInt32, bounds: CGRect) { self.id = id; self.bounds = bounds }
}

/// The status ScreenCaptureKit gives each frame (SCFrameStatus), in the watcher's words.
public enum FrameStatus: String, Sendable {
    /// A new frame with content: judged.
    case complete
    /// Nothing changed since the last frame: the last judged frame stands.
    case idle
    /// The display is not being judged: whole-display cover.
    case blank, suspended, stopped
    /// The stream has just started; no content yet. The display stays covered whole until judged.
    case started

    /// How much a status protects, for merging frames that wait: one that says "nothing new" (idle, started) never
    /// replaces pixels waiting to be judged, and nothing but a complete frame with pixels replaces one that covers the
    /// display (blank, suspended, stopped).
    var protectiveRank: Int {
        switch self {
        case .idle: return 0
        case .started: return 1
        case .complete: return 2
        case .blank, .suspended, .stopped: return 3
        }
    }
}

/// One frame from one display stream.
public struct CapturedFrame: Sendable {
    public var display: DisplayDescriptor
    public var status: FrameStatus
    /// The frame's pixels, for complete frames only. Held in memory only, never written anywhere.
    public var image: RGBAImage?
    /// The map from this frame's own metadata; nil when the metadata was missing or unusable.
    public var map: CaptureMap?
    /// The changed areas in frame pixels, as reported; nil means "the whole frame changed".
    public var dirty: [PixelRect]?
    /// The frame's time in seconds (a monotonic clock).
    public var time: TimeInterval
    /// The generation of the stream that captured it (`GenerationCounter`). A display change raises the generation a
    /// display's frames need, so a frame from an older stream never lowers a cover drawn because of the change.
    public var generation: Int
    /// The window list read when the frame arrived, so covers are placed on the windows these pixels show; nil when it
    /// was not read (the cover layer then reads it when it judges).
    public var windows: WindowSnapshot?

    public init(display: DisplayDescriptor, status: FrameStatus, image: RGBAImage?, map: CaptureMap?,
                dirty: [PixelRect]?, time: TimeInterval, generation: Int = 0, windows: WindowSnapshot? = nil) {
        self.display = display; self.status = status; self.image = image; self.map = map; self.dirty = dirty; self.time = time
        self.generation = generation; self.windows = windows
    }
}

public enum DirtyRegions {
    /// The picture finder's window grid (section 5.1: each changed area is grown to it before use).
    public static let grid = 8

    /// Clips changed areas to the frame, grows each to the 8-pixel grid and merges rectangles that touch.
    public static func prepare(_ rects: [PixelRect], width: Int, height: Int) -> [PixelRect] {
        var out: [PixelRect] = rects.compactMap { r in
            guard r.w > 0, r.h > 0 else { return nil }
            let x0 = max(0, (r.x / grid) * grid), y0 = max(0, (r.y / grid) * grid)
            let x1 = min(width, ((r.maxX + grid - 1) / grid) * grid), y1 = min(height, ((r.maxY + grid - 1) / grid) * grid)
            guard x1 > x0, y1 > y0 else { return nil }
            return PixelRect(x: x0, y: y0, w: x1 - x0, h: y1 - y0)
        }
        // Merge rectangles that overlap or touch, until none do.
        var merged = true
        while merged {
            merged = false
            outer: for i in out.indices {
                for j in out.indices where j > i && touches(out[i], out[j]) {
                    out[i] = out[i].union(out[j]); out.remove(at: j); merged = true
                    break outer
                }
            }
        }
        return out.sorted { ($0.y, $0.x) < ($1.y, $1.x) }
    }

    static func touches(_ a: PixelRect, _ b: PixelRect) -> Bool {
        a.x <= b.maxX && b.x <= a.maxX && a.y <= b.maxY && b.y <= a.maxY
    }
}

/// Holds at most one frame per display while the judging queue is busy. A newer frame replaces the
/// pixels, but changed areas are added together, so a change in a dropped frame is still judged.
/// Nothing the detector was meant to judge is dropped silently (SD-110).
public struct FrameMailbox: Sendable {
    private var pending: CapturedFrame?
    public init() {}

    public var isEmpty: Bool { pending == nil }

    public mutating func offer(_ f: CapturedFrame) {
        guard var old = pending else { pending = f; return }
        // Changed areas and pixels from different streams never mix. A frame from a newer stream (a restart) replaces
        // the waiting one outright; a late frame from an older, stopped stream never replaces a newer stream's frame.
        if f.generation < old.generation { return }
        if f.generation > old.generation { pending = f; return }
        let dirty: [PixelRect]?
        if let a = old.dirty, let b = f.dirty, old.map?.pixelWidth == f.map?.pixelWidth, old.map?.pixelHeight == f.map?.pixelHeight {
            dirty = a + b
        } else {
            dirty = nil  // sizes differ or one says "everything": judge the whole frame
        }
        // The newest status wins only if it protects at least as much as the waiting one, or it is a complete frame
        // with pixels: an idle or started frame never replaces pixels still waiting to be judged, and only new pixels
        // replace a frame that covers the display (blank, suspended, stopped).
        if (f.status == .complete && f.image != nil) || f.status.protectiveRank >= old.status.protectiveRank {
            old.status = f.status
            old.image = f.image
            old.map = f.map
            old.windows = f.windows
        }
        old.display = f.display
        old.dirty = dirty
        old.time = f.time
        pending = old
    }

    /// The frame waiting, without taking it.
    public var peek: CapturedFrame? { pending }

    public mutating func take() -> CapturedFrame? {
        defer { pending = nil }
        return pending
    }
}

/// Frames waiting to be judged: one mailbox per display, taken in turn. The judging queue takes one frame at a time
/// and gives every display, and every other piece of work (a display change, a fault), its turn in between, so a
/// display whose screen never stops changing (a video, an animation) can never keep another display's frames waiting.
/// Thread-safe: capture queues offer, the judging queue takes, the main thread reads how long frames have waited.
public final class FrameQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var boxes: [UInt32: FrameMailbox] = [:]
    /// Displays with a frame waiting, in the order they get their turn.
    private var turn: [UInt32] = []
    /// When each display's waiting frame (the oldest change not yet judged) arrived.
    private var since: [UInt32: TimeInterval] = [:]
    private var scheduled = false
    private var isOpen = false

    public init() {}

    /// Starts taking frames.
    public func open() { lock.withLock { isOpen = true } }

    /// Stops taking frames and drops every frame waiting.
    public func close() {
        lock.withLock { isOpen = false; boxes = [:]; turn = []; since = [:] }
    }

    /// Adds a frame. Returns true when the caller must schedule a drain on the judging queue (none is scheduled).
    public func offer(_ f: CapturedFrame, now: TimeInterval) -> Bool {
        lock.withLock {
            guard isOpen else { return false }
            let id = f.display.id
            if boxes[id]?.isEmpty ?? true {
                turn.append(id)
                since[id] = now
            }
            boxes[id, default: FrameMailbox()].offer(f)
            if scheduled { return false }
            scheduled = true
            return true
        }
    }

    /// The next frame, from the display whose turn it is. Returns nil, and marks the drain finished, when no frame waits.
    public func next() -> CapturedFrame? {
        lock.withLock {
            while !turn.isEmpty {
                let id = turn.removeFirst()
                if let f = boxes[id]?.take() { since[id] = nil; return f }
            }
            scheduled = false
            return nil
        }
    }

    /// How long each display's oldest unjudged frame has waited.
    public func waiting(now: TimeInterval) -> [UInt32: TimeInterval] {
        lock.withLock { since.mapValues { now - $0 } }
    }

    /// What frames that have waited at least `after` would show unjudged: per display, the changed areas of its waiting
    /// frame (global points), or the whole display when they cannot be told (see `unjudgedAreas`).
    public func waitingChanges(now: TimeInterval, after: TimeInterval) -> UnjudgedChanges {
        lock.withLock {
            var out = UnjudgedChanges()
            for (id, s) in since where now - s >= after {
                guard let f = boxes[id]?.peek else { continue }
                if let a = Self.unjudgedAreas(f) { if !a.isEmpty { out.areas[id] = a } } else { out.whole.insert(id) }
            }
            return out
        }
    }

    /// The areas a frame shows that have not been judged: none for a frame that says nothing changed; its changed areas
    /// for a complete frame with a usable map; nil (the whole display) for anything else.
    public static func unjudgedAreas(_ f: CapturedFrame) -> [CGRect]? {
        switch f.status {
        case .idle, .started: return []
        case .blank, .suspended, .stopped: return nil
        case .complete:
            guard let img = f.image, let map = f.map, let dirty = f.dirty else { return nil }
            return DirtyRegions.prepare(dirty, width: img.width, height: img.height).map(map.toGlobal)
        }
    }
}

/// Changes waiting to be judged, for covering them meanwhile: displays to cover whole, and areas to cover on others.
public struct UnjudgedChanges: Equatable, Sendable {
    public var whole: Set<UInt32> = []
    public var areas: [UInt32: [CGRect]] = [:]
    public init() {}
    public var isEmpty: Bool { whole.isEmpty && areas.isEmpty }
}
