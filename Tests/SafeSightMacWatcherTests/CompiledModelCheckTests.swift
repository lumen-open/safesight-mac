// SPDX-License-Identifier: Apache-2.0
// An app made by tools/make-app.sh carries its models compiled, with `compiled.sha256`: a stamp of the sealed list
// the packages were checked against, then every compiled file's hash. The app loads only what it checked: compiled
// models against that list, or packages against the sealed list, never a mix. Synthetic files in a temporary folder.
import Foundation
import Testing
@testable import DetectorCore
@testable import SafeSightMacWatcher

@Suite struct CompiledModelCheckTests {
    let fm = FileManager.default
    let packages = ["a/a.mlpackage/Manifest.json": "{}", "a/a.mlpackage/Data/model.mlmodel": "synthetic package one",
                    "b/b.mlpackage/Manifest.json": "{ }", "b/b.mlpackage/Data/weights.bin": "synthetic package two"]
    let compiled = ["a/a.mlmodelc/coremldata.bin": "compiled one", "a/a.mlmodelc/weights/weight.bin": "compiled weights one",
                    "b/b.mlmodelc/coremldata.bin": "compiled two"]

    func list(_ files: [String: String]) -> String {
        files.keys.sorted().map { WatcherModels.sha256(Data(files[$0]!.utf8)) + "  " + $0 }.joined(separator: "\n")
    }

    /// A models folder as make-app.sh leaves it: the compiled models and their list, stamped with `sealed`'s stamp.
    func appFolder(_ files: [String: String], sealed: String, stamp: String? = nil, listed: [String: String]? = nil) throws -> URL {
        let dir = fm.temporaryDirectory.appendingPathComponent("safesightmac-compiled-check-\(UUID().uuidString)")
        for (path, text) in files {
            let u = dir.appendingPathComponent(path)
            try fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: u)
        }
        let header = "# from " + (try stamp ?? WatcherModels.stamp(of: sealed))
        try Data((header + "\n" + list(listed ?? files) + "\n").utf8).write(to: dir.appendingPathComponent(WatcherModels.compiledListName))
        return dir
    }

    @Test func compiledModelsMadeFromTheSealedListPass() throws {
        let sealed = list(packages)
        let dir = try appFolder(compiled, sealed: sealed); defer { try? fm.removeItem(at: dir) }
        try WatcherModels.verifyCompiled(folder: dir, hashList: sealed)
    }

    @Test func compiledModelsMadeFromAnotherListAreRefused() throws {
        let sealed = list(packages)
        var other = packages; other["b/b.mlpackage/Data/weights.bin"] = "another model"
        let dir = try appFolder(compiled, sealed: list(other)); defer { try? fm.removeItem(at: dir) }
        #expect(throws: ModelCheckFailure.compiledFromOtherList) { try WatcherModels.verifyCompiled(folder: dir, hashList: sealed) }
    }

    @Test func aChangedOrExtraCompiledFileIsRefused() throws {
        let sealed = list(packages)
        var changed = compiled; changed["b/b.mlmodelc/coremldata.bin"] = "compiled TWO"
        let a = try appFolder(changed, sealed: sealed, listed: compiled); defer { try? fm.removeItem(at: a) }
        #expect(throws: ModelCheckFailure.hashMismatch("b/b.mlmodelc/coremldata.bin")) { try WatcherModels.verifyCompiled(folder: a, hashList: sealed) }
        var more = compiled; more["a/a.mlmodelc/extra.bin"] = "x"
        let b = try appFolder(more, sealed: sealed, listed: compiled); defer { try? fm.removeItem(at: b) }
        #expect(throws: ModelCheckFailure.unlistedFile("a/a.mlmodelc/extra.bin")) { try WatcherModels.verifyCompiled(folder: b, hashList: sealed) }
    }

    @Test func everySealedPackageMustHaveItsCompiledModel() throws {
        let sealed = list(packages)
        let fewer = compiled.filter { !$0.key.hasPrefix("b/") }
        let dir = try appFolder(fewer, sealed: sealed); defer { try? fm.removeItem(at: dir) }
        #expect(throws: ModelCheckFailure.missingFile("b/b.mlmodelc/")) { try WatcherModels.verifyCompiled(folder: dir, hashList: sealed) }
    }

    @Test func aListWithoutItsStampIsRefused() throws {
        let sealed = list(packages)
        let dir = try appFolder(compiled, sealed: sealed); defer { try? fm.removeItem(at: dir) }
        try Data(list(compiled).utf8).write(to: dir.appendingPathComponent(WatcherModels.compiledListName))
        #expect(throws: ModelCheckFailure.malformedList) { try WatcherModels.verifyCompiled(folder: dir, hashList: sealed) }
    }

    @Test func eachPackageGetsAStableNameForItsCompiledCopy() throws {
        let keys = try WatcherModels.packageKeys(list(packages))
        #expect(Set(keys.keys) == ["a/a.mlpackage", "b/b.mlpackage"])
        #expect(try WatcherModels.packageKeys(list(packages)) == keys)
        var other = packages; other["b/b.mlpackage/Data/weights.bin"] = "another model"
        let changed = try WatcherModels.packageKeys(list(other))
        #expect(changed["a/a.mlpackage"] == keys["a/a.mlpackage"] && changed["b/b.mlpackage"] != keys["b/b.mlpackage"])
    }

    @Test func theSealedListHasAStamp() throws {
        let s = try WatcherModels.stamp(of: WatcherModels.committedHashList)
        #expect(s.count == 64)
        // The same as tools/make-app.sh computes: each entry as "sha256  path" and a newline, hashed.
        let lines = try WatcherModels.parse(WatcherModels.committedHashList).map { "\($0.sha256)  \($0.path)\n" }.joined()
        #expect(s == WatcherModels.sha256(Data(lines.utf8)))
    }

    @Test func onlyWhatWasCheckedIsLoaded() {
        let d = URL(fileURLWithPath: "/models")
        #expect(ModelSet.locate("x/x.mlpackage", in: d, compiled: false).path == "/models/x/x.mlpackage")
        #expect(ModelSet.locate("x/x.fp32.mlpackage", in: d, compiled: true).path == "/models/x/x.fp32.mlmodelc")
    }
}
