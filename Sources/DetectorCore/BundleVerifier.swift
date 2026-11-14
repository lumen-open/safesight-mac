// SPDX-License-Identifier: Apache-2.0
// Vendored from the kestrel lab detector (v3-detector, commit 49ecdd9) under Apache-2.0.
// Verifies a signed model bundle before any model in it is loaded: the Ed25519 signature over the
// exact manifest bytes, then the SHA-256 of every listed file. Any failure means: do not load.
import CryptoKit
import Foundation

public enum BundleVerifier {
    public enum Failure: Error, Equatable { case missingFile(String), badSignature, hashMismatch(String), malformed }

    public struct Manifest: Decodable {
        public struct Entry: Decodable { public let path: String; public let sha256: String }
        public let format: String
        public let place: String
        public let version: String
        public let preprocess: String
        public let files: [Entry]
    }

    public static func verify(bundle dir: URL, publicKeyHex: String) throws -> Manifest {
        let mURL = dir.appendingPathComponent("manifest.json"), sURL = dir.appendingPathComponent("manifest.sig")
        guard let mbytes = try? Data(contentsOf: mURL), let sigHex = try? String(contentsOf: sURL, encoding: .utf8) else { throw Failure.missingFile("manifest") }
        guard let keyData = Data(hex: publicKeyHex), let sig = Data(hex: sigHex.trimmingCharacters(in: .whitespacesAndNewlines)),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData) else { throw Failure.malformed }
        guard key.isValidSignature(sig, for: mbytes) else { throw Failure.badSignature }
        guard let m = try? JSONDecoder().decode(Manifest.self, from: mbytes), m.format == "kestrel-bundle/1" else { throw Failure.malformed }
        for e in m.files {
            let u = dir.appendingPathComponent(e.path)
            guard let d = try? Data(contentsOf: u) else { throw Failure.missingFile(e.path) }
            let h = SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined()
            guard h == e.sha256 else { throw Failure.hashMismatch(e.path) }
        }
        return m
    }
}

extension Data {
    init?(hex: String) {
        guard hex.count % 2 == 0 else { return nil }
        var d = Data(capacity: hex.count / 2)
        var i = hex.startIndex
        while i < hex.endIndex {
            let j = hex.index(i, offsetBy: 2)
            guard let b = UInt8(hex[i..<j], radix: 16) else { return nil }
            d.append(b); i = j
        }
        self = d
    }
}
