// SPDX-License-Identifier: Apache-2.0
// Vendored from the kestrel lab detector (v3-detector, commit 49ecdd9) under Apache-2.0.
// Video voting over frames, per tile. A single flagged frame covers at once (safety first);
// the cover is held for `holdFrames` clean frames before it lifts; a strike needs both families at
// strike strength in at least `strikeVotes` of the last `window` frames.
import Foundation
import Preprocess

final class VideoVoter {
    struct Track { var history: [TileOutcome] = []; var lastFlag: Int? = nil; var frame = 0 }
    private var tracks: [String: Track] = [:]
    let window = 6, strikeVotes = 3, holdFrames = 4

    static func key(_ windowID: UInt64, _ r: PixelRect) -> String { "\(windowID):\(r.x / 8):\(r.y / 8):\(r.w / 8):\(r.h / 8)" }

    /// Returns (holdCover, strike) for this tile after adding this frame's outcome.
    func vote(_ key: String, _ o: TileOutcome) -> (hold: Bool, strike: Bool) {
        var t = tracks[key] ?? Track()
        t.frame += 1
        t.history.append(o)
        if t.history.count > window { t.history.removeFirst() }
        if o.confirmed { t.lastFlag = t.frame }
        tracks[key] = t
        let hold = t.lastFlag.map { t.frame - $0 <= holdFrames } ?? false
        let strike = t.history.filter(\.strikeBoth).count >= strikeVotes
        return (hold, strike)
    }
}
