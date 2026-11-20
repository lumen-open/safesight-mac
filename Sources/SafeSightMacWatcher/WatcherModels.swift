// SPDX-License-Identifier: Apache-2.0
// Loading the detector's models in the practice state (register SD-223 (b)): from a local models
// folder (inside the signed app for a shipped build), each file checked against the hash list sealed
// in the app before anything is loaded. Any failure means: do not load; the displays are covered whole.
//
// An app made by tools/make-app.sh carries its models compiled (`.mlmodelc`), so Core ML never compiles at a new
// place at every start (each new place grew Core ML's own cache by about 200 MB). make-app.sh checks the packages
// against the sealed list, compiles them, and lists every compiled file's hash in `compiled.sha256`, which begins with
// a stamp of the sealed list it compiled from. The app checks that stamp against its own sealed list, then every
// compiled file. Compiled output is not byte-for-byte repeatable (it carries the compiler's stamps), so its hashes
// can only be listed when the app is put together; the code signature covers that list as it covers the app.
import CryptoKit
import DetectorCore
import Foundation

public enum ModelCheckFailure: Error, Equatable, Sendable {
    case malformedList
    case missingFile(String)
    case hashMismatch(String)
    /// A file inside a model package that the list does not name.
    case unlistedFile(String)
    /// The compiled models' list was made from another sealed list than this build's.
    case compiledFromOtherList
    case loadFailed(String)
    /// The bundle's manifest (`bundle-manifest.json`) is missing from the sealed list, does not match it, cannot be
    /// read, or disagrees with the sealed list about which model files there are.
    case manifest(String)
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

    /// The list of the compiled models' files that make-app.sh writes into the app's models folder.
    public static let compiledListName = "compiled.sha256"

    /// A stamp of a hash list: SHA-256 of its entries, one `sha256  path` line each, in order.
    public static func stamp(of hashList: String) throws -> String {
        sha256(Data(try parse(hashList).map { "\($0.sha256)  \($0.path)\n" }.joined().utf8))
    }

    /// For each model package in a hash list, a name for its compiled copy, made from the package's entries (which
    /// were just checked, so the package is not read again to name it).
    public static func packageKeys(_ hashList: String) throws -> [String: String] {
        var lines: [String: String] = [:]
        for e in try parse(hashList) {
            guard let r = e.path.range(of: ".mlpackage/") else { continue }
            let pkg = String(e.path[..<r.lowerBound]) + ".mlpackage"
            lines[pkg, default: ""] += "\(e.sha256)  \(e.path[r.upperBound...])\n"
        }
        return lines.mapValues { sha256(Data($0.utf8)) }
    }

    /// Checks an app's compiled models: `compiled.sha256` must begin with `# from <stamp>` of `hashList`, and every
    /// compiled file must match it, with no file in a compiled model that it does not name.
    public static func verifyCompiled(folder: URL, hashList: String = committedHashList) throws {
        guard let text = try? String(contentsOf: folder.appendingPathComponent(compiledListName), encoding: .utf8) else {
            throw ModelCheckFailure.missingFile(compiledListName)
        }
        var lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        guard let first = lines.first, first.hasPrefix("# from ") else { throw ModelCheckFailure.malformedList }
        lines.removeFirst()
        guard String(first.dropFirst("# from ".count)).trimmingCharacters(in: .whitespaces) == (try stamp(of: hashList)) else {
            throw ModelCheckFailure.compiledFromOtherList
        }
        let list = lines.joined(separator: "\n")
        // Every sealed package has its compiled model in the list, so nothing is loaded that was not checked.
        let compiledPaths = try parse(list).map(\.path)
        for pkg in try packageKeys(hashList).keys {
            let compiled = String(pkg.dropLast(".mlpackage".count)) + ".mlmodelc/"
            guard compiledPaths.contains(where: { $0.hasPrefix(compiled) }) else { throw ModelCheckFailure.missingFile(compiled) }
        }
        try verify(folder: folder, hashList: list)
    }

    /// Checks every listed file, and that each model package (or compiled model) holds no file the list does not name.
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
            for ext in [".mlpackage", ".mlmodelc"] {
                if let r = e.path.range(of: ext + "/") { return String(e.path[..<r.lowerBound]) + ext }
            }
            return nil
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

    /// Reads the bundle's manifest from `folder` and checks it against the sealed list: the list must name it, the
    /// bytes read must match the list (the same bytes are then parsed, so nothing can change in between), and the
    /// model files the manifest names, with the manifest itself, must be exactly the sealed list's entries.
    public static func readManifest(folder: URL, hashList: String = committedHashList) throws -> ModelManifest {
        let entries = try parse(hashList)
        let name = ModelManifest.fileName
        guard let sealed = entries.first(where: { $0.path == name })?.sha256 else { throw ModelCheckFailure.manifest("the sealed list does not name \(name)") }
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(name)) else { throw ModelCheckFailure.missingFile(name) }
        guard sha256(data) == sealed else { throw ModelCheckFailure.hashMismatch(name) }
        let manifest: ModelManifest
        do { manifest = try ModelManifest.decode(data) } catch { throw ModelCheckFailure.manifest("\(error)") }
        var listed = Dictionary(entries.map { ($0.path, $0.sha256) }, uniquingKeysWith: { a, _ in a })
        listed[name] = nil
        let named = Dictionary(manifest.files.map { ($0.path, $0.sha256) }, uniquingKeysWith: { a, _ in a })
        guard named == listed else {
            let differ = Set(named.keys).symmetricDifference(listed.keys).union(named.keys.filter { listed[$0] != named[$0] })
            throw ModelCheckFailure.manifest("the manifest and the sealed list name different model files: \(differ.sorted().prefix(3).joined(separator: ", "))")
        }
        return manifest
    }

    /// Verifies, then loads the models the sealed manifest names with the sealed cut-off table: an app's compiled
    /// models, checked against its `compiled.sha256`, or packages, checked against the sealed list and compiled once
    /// each to a fixed place (DetectorCore's `CompiledModels`). The manifest is checked against the sealed list either
    /// way. Any failure throws, and the caller covers every display whole.
    public static func loadDetector(folder: URL, rule: DetectorRule, hashList: String = committedHashList) throws -> Detector {
        let compiled = FileManager.default.fileExists(atPath: folder.appendingPathComponent(compiledListName).path)
        if compiled {
            try verifyCompiled(folder: folder, hashList: hashList)
        } else {
            try verify(folder: folder, hashList: hashList)
        }
        let manifest = try readManifest(folder: folder, hashList: hashList)
        let uncut = manifest.modelsMissingCutoffs(in: committedThresholds)
        guard uncut.isEmpty else { throw ModelCheckFailure.manifest("the sealed cut-off table has no cut-offs for \(uncut.joined(separator: ", "))") }
        let keys = compiled ? [:] : try packageKeys(hashList)
        do {
            let set = try ModelSet.bundle(manifest, directory: folder, bundleVersion: "practice-" + String(sha256(Data(hashList.utf8)).prefix(12)),
                                          compiled: compiled, keys: keys)
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
