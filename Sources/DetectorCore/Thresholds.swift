// SPDX-License-Identifier: Apache-2.0
// Vendored from the kestrel lab detector (v3-detector, commit 49ecdd9) under Apache-2.0.
// Per-model, per-band cut-offs. Loaded from thresholds.json (local false-alarm tuning, then the
// cloud run). Internal: nothing outside the module can read a cut-off or a score.
import Foundation

struct Cutoffs: Codable, Sendable, Equatable {
    /// Flag (cover) at or above this.
    var cover: Float
    /// Containment clears only at or below this (strict).
    var clean: Float
    /// Strike strength (both families must reach it).
    var strike: Float
    /// Inside a grid, a tile is covered at this lower level.
    var gridMember: Float
    /// Several tiles at or above this make the grid a hot context.
    var gridLow: Float
}

struct ThresholdTable: Codable, Sendable {
    var schema: String
    var models: [String: [String: Cutoffs]]   // model id -> band raw value -> cutoffs

    func cutoffs(model: String, band: Band) -> Cutoffs {
        let b = band == .under16 ? Band.b16 : band
        if let c = models[model]?[b.rawValue] { return c }
        return Self.fallback
    }

    /// Conservative defaults used only when a table lacks an entry.
    static let fallback = Cutoffs(cover: 0.5, clean: 0.05, strike: 0.9, gridMember: 0.35, gridLow: 0.2)

    static func load(_ url: URL) throws -> ThresholdTable {
        try JSONDecoder().decode(ThresholdTable.self, from: Data(contentsOf: url))
    }
}
