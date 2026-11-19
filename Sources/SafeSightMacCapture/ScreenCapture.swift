// SPDX-License-Identifier: Apache-2.0
// The watcher's capture layer (chapter 05, section 5.1): one ScreenCaptureKit display stream per
// active display, always at full capture resolution, 8-bit BGRA in sRGB, no cursor, no audio, with
// the watcher's own windows left out so the detector keeps seeing what lies under a cover.
//
// This file opens no network connection and links no networking API: no part both reads the screen
// and has network access. `tools/check-no-network.sh` enforces it.
import CoreGraphics
import CoreMedia
import CoreVideo
import SafeSightMacWatcher
import Foundation
import Preprocess
import ScreenCaptureKit

/// Receives frames and faults. Called on each stream's own serial queue, or from the capture actor.
public protocol CaptureSink: AnyObject, Sendable {
    /// A frame, tagged with its stream's generation. A frame that could not be read arrives as a complete frame
    /// with no pixels, in order with the others, and covers its display whole until a later frame is judged.
    func capture(_ frame: CapturedFrame)
    /// A display with no stream: none could be started, or its stream stopped (`generation`: that stream's, if any).
    /// The cover layer covers it whole, and frames from that stream never lower its cover again.
    func captureFault(display: UInt32, cause: FaultCause, generation: Int?)
    /// The displays ScreenCaptureKit listed at its last discovery. A cross-check only: which displays are covered, and
    /// how many are judged, is decided from the OS's own display lists, never from this list.
    func captureDisplays(_ ids: [UInt32])
}

public enum ScreenRecordingPermission {
    /// Whether this process may capture the screen. Asks nothing and shows nothing.
    public static var granted: Bool { CGPreflightScreenCaptureAccess() }
    /// Asks macOS to show its own permission prompt (the owner grants it in System Settings).
    @discardableResult public static func request() -> Bool { CGRequestScreenCaptureAccess() }
}

/// Owns the display streams. Start, top-up and stop are serialised on one actor; a start or top-up that resumes
/// after a newer start or stop began gives up and stops what it started, so no stream is ever left running unowned.
public actor ScreenCapture {
    private let sink: CaptureSink
    private let ownPID: pid_t
    private let generations: GenerationCounter
    private var streams: [UInt32: DisplayStream] = [:]
    /// Raised by every start and stop.
    private var epoch = 0
    /// Streams that stopped by themselves before they were kept (by serial number): never kept.
    private var stoppedEarly: Set<Int> = []
    private var serial = 0

    public init(sink: CaptureSink, ownPID: pid_t = getpid(), generations: GenerationCounter = GenerationCounter()) {
        self.sink = sink; self.ownPID = ownPID; self.generations = generations
    }

    public var runningDisplays: [UInt32] { Array(streams.keys) }

    /// Stops every stream, then starts one stream for each display, all of a new generation. `only`: the displays to
    /// stream (the judged displays, counted by the caller from the OS's own lists); nil streams every active display
    /// and every display ScreenCaptureKit lists that is not a mirror. Any display that cannot be streamed is reported
    /// as a fault, so it stays covered whole.
    public func start(only: Set<UInt32>? = nil) async {
        epoch += 1
        let mine = epoch
        await stopStreams()
        guard mine == epoch else { return }
        await addMissing(mine, only: only)
    }

    /// Starts a stream for each display that has none (one ScreenCaptureKit did not list yet, one whose stream
    /// stopped), leaving running streams alone.
    public func topUp(only: Set<UInt32>? = nil) async { await addMissing(epoch, only: only) }

    public func stop() async {
        epoch += 1
        await stopStreams()
    }

    private func stopStreams() async {
        let old = streams
        streams = [:]
        for s in old.values { await s.stop() }
    }

    /// A stream that stopped by itself is forgotten, so a top-up can start it again. One that stopped before it was
    /// kept is never kept.
    func forget(_ id: UInt32, _ s: DisplayStream) {
        if streams[id] === s { streams[id] = nil } else { stoppedEarly.insert(s.serial) }
    }

    private func addMissing(_ mine: Int, only: Set<UInt32>?) async {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            guard mine == epoch else { return }
            for id in (only.map { Array($0) } ?? Self.activeDisplayIDs()) where streams[id] == nil {
                sink.captureFault(display: id, cause: .noPermissionOrNoContent, generation: nil)
            }
            return
        }
        guard mine == epoch else { return }
        // Taken after the content list was read: every frame of these streams shows the displays as they are now.
        let generation = generations.next()
        let listed = content.displays.map(\.displayID)
        sink.captureDisplays(listed)
        // The displays asked for; by default every active display, and any display ScreenCaptureKit lists that does not
        // repeat an active one (a mirror shows its source's pixels, covers included, and needs no stream of its own).
        let active = Self.activeDisplayIDs()
        let wanted = only ?? Set(active).union(listed.filter { id in
            let source = CGDisplayMirrorsDisplay(id)
            return source == kCGNullDirectDisplay || !active.contains(source)
        })
        let own = content.applications.filter { $0.processID == ownPID }
        for id in wanted.sorted() where streams[id] == nil {
            // An attempt overtaken by a newer start or a stop reports nothing more.
            guard mine == epoch else { return }
            guard let display = content.displays.first(where: { $0.displayID == id }) else {
                // A display ScreenCaptureKit cannot see: covered whole for as long as it exists.
                sink.captureFault(display: id, cause: .noStream, generation: nil); continue
            }
            serial += 1
            let s = DisplayStream(display: display, excluding: own, sink: sink, generation: generation, serial: serial) { [weak self] stopped in
                Task { await self?.forget(id, stopped) }
            }
            do {
                try await s.start()
            } catch {
                guard mine == epoch else { return }
                sink.captureFault(display: id, cause: .noStream, generation: nil); continue
            }
            // A newer start or stop began while this one waited, or a top-up got here first: not needed. One that has
            // already stopped by itself is not kept either (its fault is reported; a top-up starts it again).
            guard mine == epoch, streams[id] == nil, !stoppedEarly.contains(s.serial) else {
                await s.stop()
                if mine != epoch { return }
                continue
            }
            streams[id] = s
        }
    }

    /// The displays CoreGraphics reports as active.
    public static func activeDisplayIDs() -> [UInt32] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
        return Array(ids.prefix(Int(count)))
    }
}

/// One running display stream.
final class DisplayStream: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let display: SCDisplay
    let filter: SCContentFilter
    let sink: CaptureSink
    let queue: DispatchQueue
    /// Every frame of this stream carries it.
    let generation: Int
    /// Tells this stream from others started for the same display.
    let serial: Int
    private let onStop: (DisplayStream) -> Void
    private var stream: SCStream?

    init(display: SCDisplay, excluding own: [SCRunningApplication], sink: CaptureSink, generation: Int, serial: Int,
         onStop: @escaping (DisplayStream) -> Void) {
        self.display = display
        // Excluded: the watcher itself (its cover windows). Nothing else is excluded.
        self.filter = SCContentFilter(display: display, excludingApplications: own, exceptingWindows: [])
        self.sink = sink
        self.generation = generation
        self.serial = serial
        self.onStop = onStop
        self.queue = DispatchQueue(label: "safesightmac.capture.\(display.displayID)", qos: .userInitiated)
    }

    static func configuration(for filter: SCContentFilter, displayID: CGDirectDisplayID) -> SCStreamConfiguration {
        let c = SCStreamConfiguration()
        // Full capture resolution, always: the source's size in pixels, never scaled down.
        let scale = CGFloat(filter.pointPixelScale)
        c.width = max(1, Int((filter.contentRect.width * scale).rounded()))
        c.height = max(1, Int((filter.contentRect.height * scale).rounded()))
        c.captureResolution = .best
        c.scalesToFit = false
        c.pixelFormat = kCVPixelFormatType_32BGRA
        c.colorSpaceName = CGColorSpace.sRGB
        c.captureDynamicRange = .SDR
        c.showsCursor = false
        c.capturesAudio = false
        // Not specified in the register: start at the display's own refresh interval (5.22, row 1).
        let hz = CGDisplayCopyDisplayMode(displayID)?.refreshRate ?? 0
        c.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(hz > 1 ? hz.rounded() : 60))
        return c
    }

    func start() async throws {
        let s = SCStream(filter: filter, configuration: Self.configuration(for: filter, displayID: display.displayID), delegate: self)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await s.startCapture()
        stream = s
    }

    func stop() async {
        guard let s = stream else { return }
        stream = nil
        try? await s.stopCapture()
    }

    // MARK: SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen else { return }
        let id = display.displayID
        let bounds = CGDisplayBounds(id)
        let desc = DisplayDescriptor(id: id, bounds: bounds)
        let now = ProcessInfo.processInfo.systemUptime
        // A frame that cannot be read goes through the same mailbox as the others, so it is acted on in order: the
        // display is covered whole until a later frame is judged.
        let unreadable = CapturedFrame(display: desc, status: .complete, image: nil, map: nil, dirty: nil, time: now, generation: generation)
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let info = attachments.first else {
            sink.capture(unreadable); return
        }
        let meta = FrameMetadata(info)
        guard meta.status == .complete else {
            sink.capture(CapturedFrame(display: desc, status: meta.status, image: nil, map: nil, dirty: [], time: now, generation: generation))
            return
        }
        guard let pb = CMSampleBufferGetImageBuffer(sb) else { sink.capture(unreadable); return }
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        guard CVPixelBufferGetPixelFormatType(pb) == kCVPixelFormatType_32BGRA,
              let base = CVPixelBufferGetBaseAddress(pb)?.assumingMemoryBound(to: UInt8.self) else {
            sink.capture(unreadable); return
        }
        // The map is rebuilt from this frame's own metadata (never cached).
        let map = meta.map(displayBounds: bounds, pixelWidth: w, pixelHeight: h)
        // The detector copies the pixels it needs; the buffer is released as soon as this returns.
        let img = RGBAImage.fromBGRA(width: w, height: h, bytesPerRow: CVPixelBufferGetBytesPerRow(pb), base: base)
        sink.capture(CapturedFrame(display: desc, status: .complete, image: img, map: map,
                                   dirty: meta.dirtyPixels(width: w, height: h), time: now, generation: generation))
    }

    // MARK: SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        // Any stop is "capture not ok" for this display: it is covered whole until a new stream's frame is judged.
        // Frames of this stream still waiting to be judged never lower that cover (the generation is retired).
        sink.captureFault(display: display.displayID, cause: .streamStopped, generation: generation)
        onStop(self)
    }
}

/// The per-frame metadata ScreenCaptureKit attaches, read into plain values.
struct FrameMetadata {
    var status: FrameStatus
    var contentRect: CGRect?
    var contentScale: CGFloat?
    var scaleFactor: CGFloat?
    var dirtyRects: [CGRect]?

    init(_ info: [SCStreamFrameInfo: Any]) {
        if let raw = info[.status] as? Int, let s = SCFrameStatus(rawValue: raw) {
            switch s {
            case .complete: status = .complete
            case .idle: status = .idle
            case .blank: status = .blank
            case .suspended: status = .suspended
            case .started: status = .started
            case .stopped: status = .stopped
            @unknown default: status = .blank
            }
        } else {
            status = .blank  // unreadable status: treat the display as not judged
        }
        // No forced casts: a crash here would leave the screen uncovered (step 1 has no shield).
        if let d = info[.contentRect] as? NSDictionary { contentRect = CGRect(dictionaryRepresentation: d as CFDictionary) }
        contentScale = (info[.contentScale] as? NSNumber).map { CGFloat($0.doubleValue) }
        scaleFactor = (info[.scaleFactor] as? NSNumber).map { CGFloat($0.doubleValue) }
        if let arr = info[.dirtyRects] as? [Any] {
            dirtyRects = arr.compactMap { ($0 as? NSDictionary).flatMap { CGRect(dictionaryRepresentation: $0 as CFDictionary) } }
        }
    }

    func map(displayBounds: CGRect, pixelWidth: Int, pixelHeight: Int) -> CaptureMap? {
        guard let cr = contentRect, let cs = contentScale, let sf = scaleFactor else { return nil }
        return CaptureMap(displayBounds: displayBounds, contentRect: cr, contentScale: cs, scaleFactor: sf,
                          pixelWidth: pixelWidth, pixelHeight: pixelHeight)
    }

    /// Changed areas in frame pixels (to be confirmed on hardware, ST-031). nil means "judge the whole frame".
    func dirtyPixels(width: Int, height: Int) -> [PixelRect]? {
        guard let d = dirtyRects else { return nil }
        return d.compactMap { r in
            let x0 = max(0, Int(r.minX.rounded(.down))), y0 = max(0, Int(r.minY.rounded(.down)))
            let x1 = min(width, Int(r.maxX.rounded(.up))), y1 = min(height, Int(r.maxY.rounded(.up)))
            return x1 > x0 && y1 > y0 ? PixelRect(x: x0, y: y0, w: x1 - x0, h: y1 - y0) : nil
        }
    }
}
