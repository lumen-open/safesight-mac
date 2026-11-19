// SPDX-License-Identifier: Apache-2.0
// The watcher's capture layer (chapter 05, section 5.1): ScreenCaptureKit display streams at full capture
// resolution, 8-bit BGRA in sRGB, no cursor, no audio, with the watcher's own windows left out so the detector
// keeps seeing what lies under a cover. Which streams run, and when, is decided by the stream scheduler
// (SafeSightMacWatcher/Streams.swift); this file is its ScreenCaptureKit backend.
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

/// Receives frames, on each stream's own serial queue.
public protocol CaptureSink: AnyObject, Sendable {
    /// A frame, tagged with its stream's generation. A frame that could not be read arrives as a complete frame
    /// with no pixels, in order with the others, and covers its display whole until a later frame is judged.
    func capture(_ frame: CapturedFrame)
}

public enum ScreenRecordingPermission {
    /// Whether this process may capture the screen. Asks nothing and shows nothing.
    public static var granted: Bool { CGPreflightScreenCaptureAccess() }
    /// Asks macOS to show its own permission prompt (the owner grants it in System Settings).
    @discardableResult public static func request() -> Bool { CGRequestScreenCaptureAccess() }
}

/// ScreenCaptureKit, as the stream scheduler sees it.
public struct ScreenCaptureBackend: CaptureBackend {
    let sink: CaptureSink
    let ownPID: pid_t

    public init(sink: CaptureSink, ownPID: pid_t = getpid()) { self.sink = sink; self.ownPID = ownPID }

    public func list() async throws -> any CaptureListing {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        return ScreenCaptureListing(content: content, sink: sink, ownPID: ownPID)
    }
}

enum ScreenCaptureFailure: Error { case notListed, ownWindowsNotListed }

/// One ScreenCaptureKit content list: its displays, and the app's own windows to leave out of every stream.
struct ScreenCaptureListing: CaptureListing, @unchecked Sendable {
    let content: SCShareableContent
    let sink: CaptureSink
    let ownPID: pid_t

    var displays: [UInt32] { content.displays.map(\.displayID) }

    func open(_ id: UInt32, generation: Int, stoppedByItself: @escaping @Sendable () -> Void) async throws -> any CaptureStream {
        guard let display = content.displays.first(where: { $0.displayID == id }) else { throw ScreenCaptureFailure.notListed }
        // The app's own windows (the covers) must be left out, or the stream would see the covers instead of what they hide.
        guard let own = CaptureExclusion.own(content.applications, pid: { $0.processID }, ownPID: ownPID) else {
            throw ScreenCaptureFailure.ownWindowsNotListed
        }
        let s = DisplayStream(display: display, excluding: own, sink: sink, generation: generation, stoppedByItself: stoppedByItself)
        try await s.start()
        return s
    }
}

/// One running display stream.
final class DisplayStream: NSObject, SCStreamOutput, SCStreamDelegate, CaptureStream, @unchecked Sendable {
    let display: SCDisplay
    let filter: SCContentFilter
    let sink: CaptureSink
    let queue: DispatchQueue
    /// Every frame of this stream carries it.
    let generation: Int
    private let stoppedByItself: @Sendable () -> Void
    private let lock = NSLock()
    private var ended = false
    private var stream: SCStream?

    init(display: SCDisplay, excluding own: [SCRunningApplication], sink: CaptureSink, generation: Int,
         stoppedByItself: @escaping @Sendable () -> Void) {
        self.display = display
        // Excluded: the watcher itself (its cover windows). Nothing else is excluded.
        self.filter = SCContentFilter(display: display, excludingApplications: own, exceptingWindows: [])
        self.sink = sink
        self.generation = generation
        self.stoppedByItself = stoppedByItself
        self.queue = DispatchQueue(label: "safesightmac.capture.\(display.displayID)", qos: .userInitiated)
    }

    /// True the first time: the stream ends once, by `close` or by itself.
    private func end() -> Bool { lock.withLock { defer { ended = true }; return !ended } }

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

    func close() async {
        _ = end()
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
        // The window list goes with the pixels, so covers are placed on the windows this frame shows.
        sink.capture(CapturedFrame(display: desc, status: .complete, image: img, map: map,
                                   dirty: meta.dirtyPixels(width: w, height: h), time: now, generation: generation,
                                   windows: WindowList.snapshot()))
    }

    // MARK: SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        // Any stop is "capture not ok" for this display: it is covered whole until a new stream's frame is judged.
        // Frames of this stream still waiting to be judged never lower that cover (the generation is retired).
        if end() { stoppedByItself() }
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
