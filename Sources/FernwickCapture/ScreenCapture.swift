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
import FernwickWatcher
import Foundation
import Preprocess
import ScreenCaptureKit

/// Receives frames and faults. Called on each stream's own serial queue.
public protocol CaptureSink: AnyObject, Sendable {
    func capture(_ frame: CapturedFrame)
    /// A display that cannot be captured. The cover layer covers it whole.
    func captureFault(display: UInt32, cause: FaultCause)
    /// The full list of active displays after discovery or a change.
    func captureDisplays(_ displays: [DisplayDescriptor])
}

public enum ScreenRecordingPermission {
    /// Whether this process may capture the screen. Asks nothing and shows nothing.
    public static var granted: Bool { CGPreflightScreenCaptureAccess() }
    /// Asks macOS to show its own permission prompt (the owner grants it in System Settings).
    @discardableResult public static func request() -> Bool { CGRequestScreenCaptureAccess() }
}

/// Owns the display streams. Start, stop and rebuild are serialised on one actor.
public actor ScreenCapture {
    private let sink: CaptureSink
    private let ownPID: pid_t
    private var streams: [UInt32: DisplayStream] = [:]

    public init(sink: CaptureSink, ownPID: pid_t = getpid()) {
        self.sink = sink; self.ownPID = ownPID
    }

    public var runningDisplays: [UInt32] { Array(streams.keys) }

    /// Discovers every active display and starts one stream for each. Any display that cannot be
    /// streamed is reported as a fault, so it is covered whole.
    public func start() async {
        await stop()
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            for id in Self.activeDisplayIDs() { sink.captureFault(display: id, cause: .noPermissionOrNoContent) }
            sink.captureDisplays(Self.activeDisplayIDs().map { DisplayDescriptor(id: $0, bounds: CGDisplayBounds($0)) })
            return
        }
        // The active set: ScreenCaptureKit's list, cross-checked with CoreGraphics. A display in either list counts.
        let scIDs = Set(content.displays.map(\.displayID))
        let allIDs = scIDs.union(Self.activeDisplayIDs()).sorted()
        sink.captureDisplays(allIDs.map { DisplayDescriptor(id: $0, bounds: CGDisplayBounds($0)) })
        let own = content.applications.filter { $0.processID == ownPID }
        for id in allIDs {
            guard let display = content.displays.first(where: { $0.displayID == id }) else {
                sink.captureFault(display: id, cause: .noStream); continue
            }
            let s = DisplayStream(display: display, excluding: own, sink: sink)
            do {
                try await s.start()
                streams[id] = s
            } catch {
                sink.captureFault(display: id, cause: .noStream)
            }
        }
    }

    public func stop() async {
        let old = streams
        streams = [:]
        for s in old.values { await s.stop() }
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
    private var stream: SCStream?

    init(display: SCDisplay, excluding own: [SCRunningApplication], sink: CaptureSink) {
        self.display = display
        // Excluded: the watcher itself (its cover windows). Nothing else is excluded.
        self.filter = SCContentFilter(display: display, excludingApplications: own, exceptingWindows: [])
        self.sink = sink
        self.queue = DispatchQueue(label: "fernwick.capture.\(display.displayID)", qos: .userInitiated)
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
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let info = attachments.first else {
            sink.captureFault(display: id, cause: .badFrameMetadata); return
        }
        let meta = FrameMetadata(info)
        guard meta.status == .complete else {
            sink.capture(CapturedFrame(display: desc, status: meta.status, image: nil, map: nil, dirty: [], time: now))
            return
        }
        guard let pb = CMSampleBufferGetImageBuffer(sb) else { sink.captureFault(display: id, cause: .badFrameMetadata); return }
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        guard CVPixelBufferGetPixelFormatType(pb) == kCVPixelFormatType_32BGRA,
              let base = CVPixelBufferGetBaseAddress(pb)?.assumingMemoryBound(to: UInt8.self) else {
            sink.captureFault(display: id, cause: .badFrameMetadata); return
        }
        // The map is rebuilt from this frame's own metadata (never cached).
        let map = meta.map(displayBounds: bounds, pixelWidth: w, pixelHeight: h)
        // The detector copies the pixels it needs; the buffer is released as soon as this returns.
        let img = RGBAImage.fromBGRA(width: w, height: h, bytesPerRow: CVPixelBufferGetBytesPerRow(pb), base: base)
        sink.capture(CapturedFrame(display: desc, status: .complete, image: img, map: map,
                                   dirty: meta.dirtyPixels(width: w, height: h), time: now))
    }

    // MARK: SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        // Any stop is "capture not ok" for this display: it is covered whole until judged again.
        sink.captureFault(display: display.displayID, cause: .streamStopped)
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
        if let d = info[.contentRect] { contentRect = CGRect(dictionaryRepresentation: d as! CFDictionary) }
        contentScale = (info[.contentScale] as? NSNumber).map { CGFloat($0.doubleValue) }
        scaleFactor = (info[.scaleFactor] as? NSNumber).map { CGFloat($0.doubleValue) }
        if let arr = info[.dirtyRects] as? [Any] {
            dirtyRects = arr.compactMap { CGRect(dictionaryRepresentation: $0 as! CFDictionary) }
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
