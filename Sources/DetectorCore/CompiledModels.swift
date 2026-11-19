// SPDX-License-Identifier: Apache-2.0
// The compiled copies of the Core ML model packages: made once, at a place named after what was compiled.
//
// Core ML compiles a model package before loading it. Left to itself it compiles into a new temporary folder every
// time, and its own cache for the compiled model (com.apple.e5rt.e5bundlecache, in the process's Caches folder) then
// grows by about 200 MB at every start, because that cache is kept per compiled model's path (found by an independent
// review, 19 November 2026: 2.0 GB for the lab harness). So a package is compiled once, into a folder named after a
// hash of the package's files, and every later run loads that same path, so Core ML's cache entry is reused too. An
// app made by tools/make-app.sh carries its models compiled already, at a fixed place, and never compiles.
//
// This is the one file that makes and moves files for the detector; tools/check-testing-edition.sh holds it to that.
import CoreML
import CryptoKit
import Foundation

public enum CompiledModels {
    /// Where compiled copies are kept: `compiled-models` in the process's Caches folder, under its bundle identifier
    /// or, for a tool without a bundle, its name. For a sandboxed app this is inside its container.
    public static var defaultRoot: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        let owner = Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName
        return caches.appendingPathComponent(owner, isDirectory: true).appendingPathComponent("compiled-models", isDirectory: true)
    }

    /// A staging folder left this long by a run that stopped while compiling is removed (seconds).
    static let stagingGrace: TimeInterval = 3600

    /// A name for a package's contents: SHA-256 over every file in it, its path inside the package and its bytes, in
    /// path order.
    public static func key(of package: URL) throws -> String {
        let root = package.resolvingSymlinksInPath()
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        var files: [(String, URL)] = []
        for case let u as URL in walker where (try? u.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
            let full = u.resolvingSymlinksInPath().path
            guard full.hasPrefix(root.path + "/") else { continue }
            files.append((String(full.dropFirst(root.path.count + 1)), u))
        }
        guard !files.isEmpty else { throw CocoaError(.fileReadNoSuchFile) }
        var h = SHA256()
        for (rel, url) in files.sorted(by: { $0.0 < $1.0 }) {
            h.update(data: Data(rel.utf8)); h.update(data: Data([0]))
            let fh = try FileHandle(forReadingFrom: url)
            defer { try? fh.close() }
            while let chunk = try fh.read(upToCount: 1 << 20), !chunk.isEmpty { h.update(data: chunk) }
            h.update(data: Data([0]))
        }
        return h.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// The compiled copy of `package`, compiling it the first time: `<root>/<key>/<name>.mlmodelc`. `key` names the
    /// copy (`key(of:)` when nil; the watcher passes one made from the hash list it has just checked the package
    /// against). A compiled model (`.mlmodelc`) is returned as it is. `compile` is Core ML's compiler (tests fake it).
    public static func compiled(_ package: URL, key: String? = nil, root: URL = defaultRoot,
                                compile: (URL) throws -> URL = { try MLModel.compileModel(at: $0) }) throws -> URL {
        if package.pathExtension == "mlmodelc" { return package }
        let k = try key ?? self.key(of: package)
        guard !k.isEmpty, !k.contains("/"), !k.hasPrefix(".") else { throw CocoaError(.fileWriteInvalidFileName) }
        let home = root.appendingPathComponent(k, isDirectory: true)
        let out = home.appendingPathComponent(package.deletingPathExtension().lastPathComponent + ".mlmodelc", isDirectory: true)
        if isFolder(out) { return out }

        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        sweepStaging(root)
        let made = try compile(package)   // into the temporary folder
        let staging = root.appendingPathComponent(".staging-" + UUID().uuidString, isDirectory: true)
        defer { try? fm.removeItem(at: staging) }
        do {
            try fm.createDirectory(at: staging, withIntermediateDirectories: false)
            try fm.moveItem(at: made, to: staging.appendingPathComponent(out.lastPathComponent, isDirectory: true))
        } catch {
            try? fm.removeItem(at: made)   // never left in the temporary folder
            throw error
        }
        // Into place in one step. If another run got there first, its copy is used and this one goes.
        if (try? fm.moveItem(at: staging, to: home)) == nil, !isFolder(out) { throw CocoaError(.fileWriteUnknown) }
        return out
    }

    static func isFolder(_ u: URL) -> Bool {
        var dir: ObjCBool = false
        return FileManager.default.fileExists(atPath: u.path, isDirectory: &dir) && dir.boolValue
    }

    /// Removes staging folders that a run left behind when it stopped while compiling.
    static func sweepStaging(_ root: URL) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: root.path) else { return }
        for name in names where name.hasPrefix(".staging-") {
            let u = root.appendingPathComponent(name)
            let made = (try? fm.attributesOfItem(atPath: u.path)[.modificationDate]) as? Date
            if let made, Date().timeIntervalSince(made) > stagingGrace { try? fm.removeItem(at: u) }
        }
    }
}
