// SPDX-License-Identifier: Apache-2.0
// A display capture is opaque: its alpha bytes never darken what is judged.
import XCTest
@testable import Preprocess

final class OpaqueCaptureTests: XCTestCase {
    func testADisplayCaptureIsAlwaysOpaque() {
        // Two BGRA pixels with alpha 0 and 7, and row padding.
        let bgra: [UInt8] = [10, 20, 30, 0, 40, 50, 60, 7, 99, 99, 99, 99]
        let img = bgra.withUnsafeBufferPointer { RGBAImage.fromBGRA(width: 2, height: 1, bytesPerRow: 12, base: $0.baseAddress!) }
        XCTAssertEqual(img.pixels, [30, 20, 10, 255, 60, 50, 40, 255])
    }

    /// The vector copy gives exactly the bytes of the plain loop, for odd sizes, padded rows and every byte value
    /// (so a faster copy can never change what is judged).
    func testTheVectorCopyMatchesThePlainLoopByteForByte() {
        var g = XorShift32(seed: 41)
        for (w, h, pad) in [(1, 1, 0), (3, 5, 4), (17, 9, 12), (64, 33, 0), (257, 31, 60)] {
            let bpr = w * 4 + pad
            let bgra = (0..<(bpr * h)).map { _ in UInt8(truncatingIfNeeded: g.next()) }
            let fast = bgra.withUnsafeBufferPointer { RGBAImage.fromBGRA(width: w, height: h, bytesPerRow: bpr, base: $0.baseAddress!) }
            let plain = bgra.withUnsafeBufferPointer { RGBAImage.fromBGRAScalar(width: w, height: h, bytesPerRow: bpr, base: $0.baseAddress!) }
            XCTAssertEqual(fast.pixels, plain.pixels, "\(w)x\(h) pad \(pad)")
            XCTAssertEqual(fast.width, w); XCTAssertEqual(fast.height, h)
        }
    }
}
