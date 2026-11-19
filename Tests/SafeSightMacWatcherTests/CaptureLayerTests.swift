// SPDX-License-Identifier: Apache-2.0
// The capture layer's arithmetic: the per-frame map across scales, changed areas, the window split
// and the frame mailbox. Section 5.1's CI mark: every case maps a test rectangle to within 1 detail pixel.
import CoreGraphics
import Foundation
import Preprocess
import Testing
@testable import SafeSightMacWatcher

/// One recorded display shape: its global bounds, the frame metadata and the buffer size.
struct DisplayCase: CustomStringConvertible {
    let name: String
    let bounds: CGRect
    let scaleFactor: CGFloat
    var contentRect: CGRect? = nil
    var contentScale: CGFloat = 1
    var description: String { name }

    var map: CaptureMap {
        let cr = contentRect ?? CGRect(origin: .zero, size: bounds.size)
        let w = Int((cr.width * contentScale * scaleFactor).rounded()) + Int(cr.minX * scaleFactor * 2)
        let h = Int((cr.height * contentScale * scaleFactor).rounded()) + Int(cr.minY * scaleFactor * 2)
        return CaptureMap(displayBounds: bounds, contentRect: cr, contentScale: contentScale, scaleFactor: scaleFactor,
                          pixelWidth: w, pixelHeight: h)!
    }
}

let displayCases: [DisplayCase] = [
    DisplayCase(name: "built-in 1x at origin", bounds: CGRect(x: 0, y: 0, width: 1440, height: 900), scaleFactor: 1),
    DisplayCase(name: "Retina 2x at origin", bounds: CGRect(x: 0, y: 0, width: 1512, height: 982), scaleFactor: 2),
    DisplayCase(name: "external 1x to the right", bounds: CGRect(x: 1512, y: 0, width: 1920, height: 1080), scaleFactor: 1),
    DisplayCase(name: "external 2x to the left, above", bounds: CGRect(x: -2560, y: -400, width: 2560, height: 1440), scaleFactor: 2),
    DisplayCase(name: "rotated portrait 2x", bounds: CGRect(x: 1512, y: -300, width: 1080, height: 1920), scaleFactor: 2),
    DisplayCase(name: "scaled mode 3x", bounds: CGRect(x: 0, y: 900, width: 1280, height: 800), scaleFactor: 3),
    DisplayCase(name: "letterboxed content at 0.75", bounds: CGRect(x: 0, y: 0, width: 1600, height: 1000), scaleFactor: 2,
                contentRect: CGRect(x: 100, y: 0, width: 1600, height: 1000), contentScale: 0.75),
]

@Suite struct MappingTests {
    @Test(arguments: displayCases)
    func pixelToScreenAndBackWithinOnePixel(_ c: DisplayCase) throws {
        let m = c.map
        // A test rectangle in the middle of the content, in pixels.
        let px = PixelRect(x: m.pixelWidth / 3, y: m.pixelHeight / 4, w: 97, h: 61)
        let g = m.toGlobal(px)
        // Its global position follows the display's origin and the read scale, never an assumed 2.
        let pointsPerPixel = 1 / (c.scaleFactor * c.contentScale)
        let expectedX = c.bounds.minX + (CGFloat(px.x) / c.scaleFactor - (c.contentRect?.minX ?? 0)) / c.contentScale
        #expect(abs(g.minX - expectedX) <= pointsPerPixel)
        #expect(abs(g.width - CGFloat(px.w) * pointsPerPixel) < 1e-6)
        // Round trip: back to pixels, within 1 detail pixel on every edge, and never smaller.
        let back = try #require(m.toPixels(g))
        #expect(abs(back.x - px.x) <= 1 && abs(back.y - px.y) <= 1)
        #expect(abs(back.maxX - px.maxX) <= 1 && abs(back.maxY - px.maxY) <= 1)
        #expect(back.x <= px.x && back.y <= px.y && back.maxX >= px.maxX && back.maxY >= px.maxY)
        // The whole frame maps onto the content area inside the display bounds.
        let whole = m.toGlobal(PixelRect(x: Int((c.contentRect?.minX ?? 0) * c.scaleFactor), y: 0,
                                         w: Int((c.contentRect?.width ?? c.bounds.width) * c.contentScale * c.scaleFactor),
                                         h: Int((c.contentRect?.height ?? c.bounds.height) * c.contentScale * c.scaleFactor)))
        #expect(abs(whole.minX - c.bounds.minX) < 1e-6 && abs(whole.minY - c.bounds.minY) < 1e-6)
        #expect(abs(whole.width - c.bounds.width) < 1e-6 && abs(whole.height - c.bounds.height) < 1e-6)
    }

    @Test func aRetinaRectangleIsHalfItsPixelSizeInPoints() {
        let m = displayCases[1].map
        let g = m.toGlobal(PixelRect(x: 200, y: 100, w: 64, h: 64))
        #expect(g == CGRect(x: 100, y: 50, width: 32, height: 32))
    }

    @Test func unusableMetadataGivesNoMap() {
        let b = CGRect(x: 0, y: 0, width: 100, height: 100)
        #expect(CaptureMap(displayBounds: b, contentRect: b, contentScale: 1, scaleFactor: 0, pixelWidth: 100, pixelHeight: 100) == nil)
        #expect(CaptureMap(displayBounds: b, contentRect: b, contentScale: .nan, scaleFactor: 2, pixelWidth: 100, pixelHeight: 100) == nil)
        #expect(CaptureMap(displayBounds: b, contentRect: .zero, contentScale: 1, scaleFactor: 2, pixelWidth: 100, pixelHeight: 100) == nil)
    }

    @Test func cocoaFlipUsesThePrimaryHeight() {
        // A display above the primary has negative global y; in Cocoa it sits above the primary's top.
        let g = CGRect(x: 10, y: -400, width: 100, height: 50)
        let c = CoordinateSpace.toCocoa(g, primaryHeight: 900)
        #expect(c == CGRect(x: 10, y: 1250, width: 100, height: 50))
        #expect(CoordinateSpace.toGlobal(cocoa: c, primaryHeight: 900) == g)
    }

    @Test func canvasLayerSpaceIsDisplayLocalAndFlipped() {
        let display = CGRect(x: 1512, y: 0, width: 1920, height: 1080)
        let g = CGRect(x: 1612, y: 80, width: 200, height: 100)
        #expect(CoordinateSpace.toCanvasLayer(g, display: display) == CGRect(x: 100, y: 900, width: 200, height: 100))
    }

    @Test func snappingOnlyGrows() {
        let g = CGRect(x: 10.3, y: 20.7, width: 33.1, height: 0.2)
        let s = CoordinateSpace.snapOutward(g, pointsPerPixel: 0.5)
        #expect(s.contains(g))
        #expect(s == CGRect(x: 10, y: 20.5, width: 33.5, height: 0.5))
    }
}

@Suite struct DirtyRegionTests {
    @Test func changedAreasGrowToTheGridAndMerge() {
        let out = DirtyRegions.prepare([PixelRect(x: 3, y: 3, w: 2, h: 2), PixelRect(x: 9, y: 1, w: 3, h: 3),
                                        PixelRect(x: 100, y: 100, w: 1, h: 1)], width: 200, height: 200)
        // The first two touch once grown to the 8-pixel grid and merge.
        #expect(out == [PixelRect(x: 0, y: 0, w: 16, h: 8), PixelRect(x: 96, y: 96, w: 8, h: 8)])
    }

    @Test func changedAreasAreClippedToTheFrame() {
        let out = DirtyRegions.prepare([PixelRect(x: 195, y: -5, w: 30, h: 10), PixelRect(x: 300, y: 300, w: 4, h: 4)], width: 200, height: 100)
        #expect(out == [PixelRect(x: 192, y: 0, w: 8, h: 8)])
    }
}

@Suite struct WindowSplitTests {
    let display = DisplayDescriptor(id: 7, bounds: CGRect(x: 0, y: 0, width: 1000, height: 800))
    // Front to back: a small window in front of a large one; the watcher's own window is ignored.
    let snap = WindowSnapshot(windows: [
        WindowInfo(number: 99, ownerPID: 1, layer: 25, bounds: CGRect(x: 0, y: 0, width: 1000, height: 800)),   // own canvas
        WindowInfo(number: 2, ownerPID: 20, layer: 0, bounds: CGRect(x: 100, y: 100, width: 300, height: 200)),
        WindowInfo(number: 1, ownerPID: 10, layer: 0, bounds: CGRect(x: 0, y: 0, width: 600, height: 600)),
    ], time: 1)

    @Test func changedAreasGoToTheFrontMostWindow() {
        let parts = snap.split(changed: [CGRect(x: 200, y: 150, width: 400, height: 100)], display: display, ignoring: [1])
        #expect(parts.map(\.target) == [.window(number: 2, ownerPID: 20), .window(number: 1, ownerPID: 10)])
        #expect(parts[0].changed == [CGRect(x: 200, y: 150, width: 200, height: 100)])
        #expect(parts[1].changed.boundingBox == CGRect(x: 400, y: 150, width: 200, height: 100))
    }

    @Test func areasNoWindowCoversGoToTheDisplaySurface() {
        let parts = snap.split(changed: [CGRect(x: 700, y: 700, width: 50, height: 50)], display: display, ignoring: [1])
        #expect(parts.map(\.target) == [.surface(display: 7)])
    }

    @Test func visibleAreaExcludesWindowsInFront() throws {
        let vis = try #require(snap.visibleArea(of: .window(number: 1, ownerPID: 10), display: display, ignoring: [1]))
        let area = vis.reduce(0) { $0 + $1.width * $1.height }
        #expect(abs(area - CGFloat(600 * 600 - 300 * 200)) < 1e-6)
        #expect(!vis.contains { $0.intersects(CGRect(x: 101, y: 101, width: 298, height: 198)) })
    }

    @Test func aWindowOnTwoDisplaysIsSplitPerDisplay() {
        let left = DisplayDescriptor(id: 1, bounds: CGRect(x: 0, y: 0, width: 500, height: 500))
        let right = DisplayDescriptor(id: 2, bounds: CGRect(x: 500, y: 0, width: 500, height: 500))
        let s = WindowSnapshot(windows: [WindowInfo(number: 5, ownerPID: 3, layer: 0, bounds: CGRect(x: 400, y: 100, width: 200, height: 100))], time: 0)
        let l = s.visibleArea(of: .window(number: 5, ownerPID: 3), display: left, ignoring: [])
        let r = s.visibleArea(of: .window(number: 5, ownerPID: 3), display: right, ignoring: [])
        #expect(l == [CGRect(x: 400, y: 100, width: 100, height: 100)])
        #expect(r == [CGRect(x: 500, y: 100, width: 100, height: 100)])
    }

    @Test func contextIDsAreDistinct() {
        let ids = [JudgeTarget.window(number: 1, ownerPID: 2), .window(number: 2, ownerPID: 1), .surface(display: 1)].map(\.contextID)
        #expect(Set(ids).count == 3)
    }
}

@Suite struct MailboxTests {
    let d = DisplayDescriptor(id: 1, bounds: CGRect(x: 0, y: 0, width: 100, height: 100))
    func frame(_ status: FrameStatus, dirty: [PixelRect]?, t: Double) -> CapturedFrame {
        let m = CaptureMap(displayBounds: d.bounds, contentRect: d.bounds, contentScale: 1, scaleFactor: 1, pixelWidth: 100, pixelHeight: 100)
        return CapturedFrame(display: d, status: status, image: status == .complete ? RGBAImage(width: 100, height: 100, pixels: .init(repeating: UInt8(t), count: 40000)) : nil,
                             map: status == .complete ? m : nil, dirty: dirty, time: t)
    }

    @Test func droppedFramesKeepTheirChangedAreas() throws {
        var box = FrameMailbox()
        box.offer(frame(.complete, dirty: [PixelRect(x: 0, y: 0, w: 8, h: 8)], t: 1))
        box.offer(frame(.complete, dirty: [PixelRect(x: 50, y: 50, w: 8, h: 8)], t: 2))
        let taken = box.take()
        let f = try #require(taken)
        #expect(f.dirty?.count == 2)
        #expect(f.image?.pixels.first == 2, "the newest pixels are judged")
        #expect(box.isEmpty)
    }

    @Test func anIdleFrameNeverReplacesPixelsWaitingToBeJudged() throws {
        var box = FrameMailbox()
        box.offer(frame(.complete, dirty: [PixelRect(x: 0, y: 0, w: 8, h: 8)], t: 1))
        box.offer(frame(.idle, dirty: [], t: 2))
        let taken = box.take()
        let f = try #require(taken)
        #expect(f.status == .complete && f.image != nil)
    }

    @Test(arguments: [FrameStatus.blank, .suspended, .stopped])
    func onlyNewPixelsReplaceAFrameThatCoversTheDisplay(_ s: FrameStatus) throws {
        for later in [FrameStatus.idle, .started] {
            var box = FrameMailbox()
            box.offer(frame(s, dirty: [], t: 1))
            box.offer(frame(later, dirty: [], t: 2))
            #expect(box.take()?.status == s, "\(later) after \(s)")
        }
        var box = FrameMailbox()
        box.offer(frame(s, dirty: [], t: 1))
        box.offer(frame(.complete, dirty: nil, t: 2))
        let taken = box.take()
        let f = try #require(taken)
        #expect(f.status == .complete && f.image != nil)
    }

    @Test func aStartedFrameNeverReplacesPixelsWaitingToBeJudged() throws {
        var box = FrameMailbox()
        box.offer(frame(.complete, dirty: nil, t: 1))
        box.offer(frame(.started, dirty: [], t: 2))
        let taken = box.take()
        let f = try #require(taken)
        #expect(f.status == .complete && f.image != nil)
    }

    @Test func aBlankFrameAfterAContentFrameWins() throws {
        var box = FrameMailbox()
        box.offer(frame(.complete, dirty: nil, t: 1))
        box.offer(frame(.blank, dirty: [], t: 2))
        let taken = box.take()
        #expect(taken?.status == .blank)
    }
}
