// SPDX-License-Identifier: Apache-2.0
// Loading the detector's models in the practice state (register SD-223 (b)): from a local models
// folder (inside the signed app for a shipped build), each file checked against the hash list sealed
// in the app before anything is loaded. Any failure means: do not load; the displays are covered whole.
import CryptoKit
import DetectorCore
import Foundation

public enum ModelCheckFailure: Error, Equatable, Sendable {
    case malformedList
    case missingFile(String)
    case hashMismatch(String)
    /// A file inside a model package that the list does not name.
    case unlistedFile(String)
    case loadFailed(String)
}

public enum WatcherModels {
    /// The hash list sealed in this build (models/watcher-models.sha256).
    public static var committedHashList: String { CommittedModelData.hashList }
    /// The cut-off table sealed in this build (models/thresholds.json).
    public static var committedThresholds: Data { Data(CommittedModelData.thresholdsJSON.utf8) }

    /// Parses "sha256  relative/path" lines.
    public static func parse(_ list: String) throws -> [(path: String, sha256: String)] {
        try list.split(separator: "\n").map { line in
            let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard parts.count == 2, parts[0].count == 64, parts[0].allSatisfy(\.isHexDigit) else { throw ModelCheckFailure.malformedList }
            let path = parts[1].trimmingCharacters(in: .whitespaces)
            guard !path.isEmpty, !path.hasPrefix("/"), !path.split(separator: "/").contains("..") else { throw ModelCheckFailure.malformedList }
            return (path, String(parts[0]).lowercased())
        }
    }

    /// Checks every listed file, and that each model package holds no file the list does not name.
    public static func verify(folder: URL, hashList: String = committedHashList) throws {
        let entries = try parse(hashList)
        guard !entries.isEmpty else { throw ModelCheckFailure.malformedList }
        for e in entries {
            let url = folder.appendingPathComponent(e.path)
            guard let h = sha256(of: url) else { throw ModelCheckFailure.missingFile(e.path) }
            guard h == e.sha256 else { throw ModelCheckFailure.hashMismatch(e.path) }
        }
        let listed = Set(entries.map(\.path))
        let packages = Set(entries.compactMap { e -> String? in
            guard let r = e.path.range(of: ".mlpackage/") else { return nil }
            return String(e.path[..<r.lowerBound]) + ".mlpackage"
        })
        for pkg in packages {
            let root = folder.appendingPathComponent(pkg).resolvingSymlinksInPath()
            guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else { continue }
            for case let u as URL in walker where (try? u.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                if u.lastPathComponent == ".DS_Store" { continue }
                let full = u.resolvingSymlinksInPath().path
                guard full.hasPrefix(root.path + "/") else { throw ModelCheckFailure.unlistedFile(full) }
                let rel = pkg + "/" + full.dropFirst(root.path.count + 1)
                if !listed.contains(rel) { throw ModelCheckFailure.unlistedFile(rel) }
            }
        }
    }

    /// Verifies, then loads the watcher's three models with the sealed cut-off table. `compiledInto` is where their
    /// compiled copies go (a `CompiledModelFolder`, removed when the app quits); nil leaves them in the temporary
    /// folder, where Core ML never removes them.
    public static func loadDetector(folder: URL, rule: DetectorRule, hashList: String = committedHashList,
                                    compiledInto: URL? = nil) throws -> Detector {
        try verify(folder: folder, hashList: hashList)
        do {
            let set = try ModelSet.watcher(directory: folder, bundleVersion: "practice-" + String(sha256(Data(hashList.utf8)).prefix(12)),
                                           compiledInto: compiledInto)
            var cfg = DetectorConfig(); cfg.rule = rule
            return try Detector(models: set, thresholdsJSON: committedThresholds, config: cfg)
        } catch {
            throw ModelCheckFailure.loadFailed(String(describing: type(of: error)))
        }
    }

    static func sha256(of url: URL) -> String? {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }
        var h = SHA256()
        while let chunk = try? fh.read(upToCount: 1 << 20), !chunk.isEmpty { h.update(data: chunk) }
        return h.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func sha256(_ d: Data) -> String { SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined() }
}
