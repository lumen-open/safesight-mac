// SPDX-License-Identifier: Apache-2.0
// Vendored from the kestrel lab detector (v3-detector, commit 49ecdd9) under Apache-2.0.
import CryptoKit
import Foundation
import XCTest
@testable import Preprocess

final class VectorTests: XCTestCase {
    func testAllVectorsBitExact() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../spec/vectors/vectors.json").standardized
        let doc = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        XCTAssertEqual(doc["spec"] as? String, PreprocessSpec.version)
        let vectors = doc["vectors"] as! [[String: Any]]
        var passed = 0
        for v in vectors {
            let input = v["input"] as! [String: Any]
            let img = Preprocessor.generateInput(kind: input["kind"] as! String, width: input["w"] as! Int, height: input["h"] as! Int,
                                                 seed: UInt32(input["seed"] as! Int))
            let r = v["rect"] as! [Int]
            let js = (v["jitterSeed"] as? Int).map { UInt32($0) }
            let out = try Preprocessor.run(img, rect: PixelRect(x: r[0], y: r[1], w: r[2], h: r[3]), side: v["side"] as! Int, jitterSeed: js)
            let sha = SHA256.hash(data: Data(out)).map { String(format: "%02x", $0) }.joined()
            if sha == v["sha256"] as! String { passed += 1 } else { XCTFail("\(v["name"]!): \(Array(out.prefix(16)))") }
        }
        print("swift preprocess: \(passed)/\(vectors.count) vectors bit-exact")
        XCTAssertEqual(passed, vectors.count)
    }
}
