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
}
