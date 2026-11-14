// SPDX-License-Identifier: Apache-2.0
// Vendored from the kestrel lab detector (v3-detector, commit 49ecdd9) under Apache-2.0.
// Verdict cache keyed by an exact hash of a tile's rendered pixels, its pass, and the model bundle
// version, so a scrolled or repeated thumbnail is never judged twice. It stores outcome flags,
// never scores. Only an exact pixel match reuses a verdict.
import CryptoKit
import Foundation
import Preprocess

struct TileOutcome: Sendable, Equatable {
    var flagA: Bool, flagB: Bool, strikeBoth: Bool, clean: Bool, gridMember: Bool, gridLow: Bool, forced: Bool
    /// One family flagged, the other did not.
    var disputed = false
    /// The referee was asked (only for disputes) and confirmed.
    var refereeRan = false, refereeFlag = false
    /// The covering decision: both families agree, or a dispute the referee confirmed (or the lab stand-in).
    var confirmed: Bool { forced || (flagA && flagB) || (disputed && refereeFlag) }
}

final class VerdictCache {
    private var store: [Data: TileOutcome] = [:]
    private var order: [Data] = []
    let capacity: Int
    private(set) var hits = 0, misses = 0
    init(capacity: Int = 50_000) { self.capacity = capacity }

    static func key(_ img: RGBAImage, _ r: PixelRect, pass: String, version: String) -> Data {
        var h = SHA256()
        h.update(data: Data("\(version)|\(pass)|\(r.w)x\(r.h)|".utf8))
        img.pixels.withUnsafeBytes { buf in
            for y in r.y..<r.maxY {
                let start = (y * img.width + r.x) * 4
                h.update(bufferPointer: UnsafeRawBufferPointer(rebasing: buf[start..<(start + r.w * 4)]))
            }
        }
        return Data(h.finalize().prefix(16))
    }

    func get(_ k: Data) -> TileOutcome? {
        if let v = store[k] { hits += 1; return v }
        misses += 1
        return nil
    }

    func removeAll() { store.removeAll(); order.removeAll() }

    func put(_ k: Data, _ v: TileOutcome) {
        if store[k] == nil { order.append(k) }
        store[k] = v
        if order.count > capacity { store[order.removeFirst()] = nil }
    }
}
