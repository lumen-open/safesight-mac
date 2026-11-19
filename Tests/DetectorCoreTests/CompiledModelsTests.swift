// SPDX-License-Identifier: Apache-2.0
// A model package is compiled once, to a place named after its contents, and that place is used again by every later
// run, so Core ML's own cache, kept per compiled model's place, stops growing at every start. Core ML's compiler is
// faked: these tests make no model and load none. Everything happens in a temporary folder.
import Foundation
import Testing
@testable import DetectorCore

@Suite struct CompiledModelsTests {
    let fm = FileManager.default

    func scratch() throws -> URL {
        let u = fm.temporaryDirectory.appendingPathComponent("safesightmac-compiled-models-test-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    /// A made-up package: `m/m.mlpackage` with two files of synthetic bytes.
    func package(in dir: URL, _ text: String = "synthetic weights") throws -> URL {
        let p = dir.appendingPathComponent("m/m.mlpackage", isDirectory: true)
        try fm.createDirectory(at: p.appendingPathComponent("Data/com.apple.CoreML"), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: p.appendingPathComponent("Data/com.apple.CoreML/model.mlmodel"))
        try Data("{}".utf8).write(to: p.appendingPathComponent("Manifest.json"))
        return p
    }

    /// Stands in for Core ML's compiler: makes `<tmp>/<name>_<uuid>.mlmodelc`, as Core ML does, and counts its calls.
    final class FakeCompiler: @unchecked Sendable {
        let tmp: URL
        var calls = 0
        var outputs: [URL] = []
        var during: (() -> Void)?
        init(tmp: URL) { self.tmp = tmp }
        func compile(_ package: URL) throws -> URL {
            calls += 1
            let out = tmp.appendingPathComponent(package.deletingPathExtension().lastPathComponent + "_\(UUID().uuidString).mlmodelc")
            try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            try Data("compiled".utf8).write(to: out.appendingPathComponent("coremldata.bin"))
            outputs.append(out)
            during?()
            return out
        }
    }

    @Test func aPackageIsCompiledOnceAndItsPlaceIsUsedAgain() throws {
        let dir = try scratch(); defer { try? fm.removeItem(at: dir) }
        let pkg = try package(in: dir), root = dir.appendingPathComponent("cache"), fake = FakeCompiler(tmp: dir)
        let first = try CompiledModels.compiled(pkg, root: root, compile: fake.compile)
        #expect(first.lastPathComponent == "m.mlmodelc")
        #expect(first.deletingLastPathComponent().lastPathComponent == (try CompiledModels.key(of: pkg)), "named after the contents")
        #expect(fm.fileExists(atPath: first.appendingPathComponent("coremldata.bin").path))
        #expect(fake.outputs.allSatisfy { !fm.fileExists(atPath: $0.path) }, "nothing is left where the compiler put it")
        let second = try CompiledModels.compiled(pkg, root: root, compile: fake.compile)
        #expect(second == first, "the same place, run after run")
        #expect(fake.calls == 1, "compiled once")
        #expect(try fm.contentsOfDirectory(atPath: root.path).filter { $0.hasPrefix(".staging-") }.isEmpty)
    }

    @Test func theNameFollowsTheContents() throws {
        let dir = try scratch(); defer { try? fm.removeItem(at: dir) }
        let pkg = try package(in: dir)
        let k = try CompiledModels.key(of: pkg)
        #expect(k.count == 64)
        #expect(try CompiledModels.key(of: pkg) == k)
        try Data("synthetic weights, changed".utf8).write(to: pkg.appendingPathComponent("Data/com.apple.CoreML/model.mlmodel"))
        #expect(try CompiledModels.key(of: pkg) != k, "a changed package gets a new place, never the old copy")
    }

    @Test func aCompiledModelIsUsedAsItIs() throws {
        let fake = FakeCompiler(tmp: fm.temporaryDirectory)
        let compiled = URL(fileURLWithPath: "/nonexistent/x/x.mlmodelc")
        #expect(try CompiledModels.compiled(compiled, root: URL(fileURLWithPath: "/nonexistent/cache"), compile: fake.compile) == compiled)
        #expect(fake.calls == 0)
    }

    @Test func whenAnotherRunGetsThereFirstItsCopyIsUsed() throws {
        let dir = try scratch(); defer { try? fm.removeItem(at: dir) }
        let pkg = try package(in: dir), root = dir.appendingPathComponent("cache"), fake = FakeCompiler(tmp: dir)
        let key = try CompiledModels.key(of: pkg)
        let theirs = root.appendingPathComponent(key).appendingPathComponent("m.mlmodelc")
        // While this run compiles, another one puts its copy in place.
        fake.during = {
            try? FileManager.default.createDirectory(at: theirs, withIntermediateDirectories: true)
            try? Data("theirs".utf8).write(to: theirs.appendingPathComponent("coremldata.bin"))
        }
        let got = try CompiledModels.compiled(pkg, key: key, root: root, compile: fake.compile)
        #expect(got.path == theirs.path)
        #expect(try Data(contentsOf: theirs.appendingPathComponent("coremldata.bin")) == Data("theirs".utf8))
        #expect(try fm.contentsOfDirectory(atPath: root.path).filter { $0.hasPrefix(".staging-") }.isEmpty, "this run's copy is gone")
        #expect(fake.outputs.allSatisfy { !fm.fileExists(atPath: $0.path) })
    }

    @Test func aFailedCompileLeavesNothingBehind() throws {
        let dir = try scratch(); defer { try? fm.removeItem(at: dir) }
        let pkg = try package(in: dir), root = dir.appendingPathComponent("cache")
        struct Failed: Error {}
        #expect(throws: Failed.self) { try CompiledModels.compiled(pkg, root: root, compile: { _ in throw Failed() }) }
        #expect((try? fm.contentsOfDirectory(atPath: root.path))?.isEmpty ?? true)
    }

    @Test func stagingLeftByAStoppedRunIsSweptOnlyWhenOld() throws {
        let dir = try scratch(); defer { try? fm.removeItem(at: dir) }
        let pkg = try package(in: dir), root = dir.appendingPathComponent("cache"), fake = FakeCompiler(tmp: dir)
        let old = root.appendingPathComponent(".staging-old"), fresh = root.appendingPathComponent(".staging-fresh")
        try fm.createDirectory(at: old, withIntermediateDirectories: true)
        try fm.createDirectory(at: fresh, withIntermediateDirectories: true)
        try fm.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -2 * CompiledModels.stagingGrace)], ofItemAtPath: old.path)
        _ = try CompiledModels.compiled(pkg, root: root, compile: fake.compile)
        #expect(!fm.fileExists(atPath: old.path))
        #expect(fm.fileExists(atPath: fresh.path), "another run may still be compiling into it")
    }

    @Test(arguments: ["", "../escape", ".hidden", "a/b"])
    func aKeyThatIsNotAPlainNameIsRefused(_ key: String) throws {
        let dir = try scratch(); defer { try? fm.removeItem(at: dir) }
        let pkg = try package(in: dir), fake = FakeCompiler(tmp: dir)
        #expect(throws: (any Error).self) { try CompiledModels.compiled(pkg, key: key, root: dir.appendingPathComponent("cache"), compile: fake.compile) }
        #expect(fake.calls == 0)
    }
}
