// SPDX-License-Identifier: Apache-2.0
// The practice-state signal (SD-223 (a)) and the model check (SD-223 (b)).
import Darwin
import Foundation
import Testing
@testable import SafeSightMacWatcher

#if !SAFESIGHTMAC_TESTING
/// A fake launch folder: names and owners, or a failure.
struct FakeFolder: LaunchFolderProbe {
    var entries: [String: uid_t] = [:]
    var folderMissing = false
    var folderUnreadable = false
    var ownerUnreadable: Set<String> = []

    func names(in folder: String) throws -> [String] {
        if folderMissing { throw CocoaError(.fileReadNoSuchFile) }
        if folderUnreadable { throw CocoaError(.fileReadNoPermission) }
        return Array(entries.keys)
    }
    func ownerUID(of path: String) throws -> uid_t {
        let name = (path as NSString).lastPathComponent
        if ownerUnreadable.contains(name) { throw POSIXError(.EACCES) }
        guard let u = entries[name] else { throw POSIXError(.ENOENT) }
        return u
    }
}

@Suite struct PracticeSignalTests {
    @Test func noKeeperLaunchFileIsThePracticeState() {
        let f = FakeFolder(entries: ["com.apple.something.plist": 0, "org.example.helper.plist": 0])
        #expect(PracticeState.read(probe: f) == .practice)
        #expect(PracticeState.read(probe: f).isPractice)
    }

    @Test(arguments: ["org.safesightmac.keeper.plist", "app.safesightmac.safesightmac.keeper.plist", "org.safesightmac.lab.keeper.plist", "ORG.SAFESIGHTMAC.KEEPER.PLIST"])
    func aRootOwnedKeeperLaunchFileEndsThePracticeState(_ name: String) {
        let f = FakeFolder(entries: [name: 0, "com.apple.other.plist": 0])
        #expect(PracticeState.read(probe: f) == .keeperInstalled(path: "/Library/LaunchDaemons/" + name))
        #expect(!PracticeState.read(probe: f).isPractice)
    }

    @Test func aKeeperNamedFileNotOwnedByRootIsNotAKeeper() {
        // Only root can place a file in the launch-daemon folder; an entry owned by anyone else is not
        // the root-owned launch file the signal names.
        #expect(PracticeState.read(probe: FakeFolder(entries: ["org.safesightmac.keeper.plist": 501])) == .practice)
    }

    @Test func similarNamesDoNotCount() {
        for n in ["org.safesightmac.keeper.plist.bak", "org.safesightmac.watcher.plist", "org.safesightmackeeper.plist", "keeper.plist"] {
            #expect(!PracticeState.isKeeperLaunchFile(n), "\(n)")
        }
    }

    @Test func anUnreadableFolderIsNotThePracticeState() {
        let s = PracticeState.read(probe: FakeFolder(folderUnreadable: true))
        #expect(!s.isPractice)
        if case .unknown = s {} else { Issue.record("expected unknown, got \(s)") }
    }

    @Test func anUnreadableOwnerIsNotThePracticeState() {
        let s = PracticeState.read(probe: FakeFolder(entries: ["org.safesightmac.keeper.plist": 0], ownerUnreadable: ["org.safesightmac.keeper.plist"]))
        #expect(!s.isPractice)
    }

    @Test func noLaunchDaemonFolderIsThePracticeState() {
        #expect(PracticeState.read(probe: FakeFolder(folderMissing: true)) == .practice)
    }

    @Test func theRealProbeReadsOwnersWithoutFollowingLinks() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("safesightmac-practice-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("org.safesightmac.keeper.plist")
        try Data("<plist/>".utf8).write(to: file)
        // Owned by the test's own (non-root) user: not a keeper.
        #expect(try SystemLaunchFolderProbe().ownerUID(of: file.path) == getuid())
        #expect(PracticeState.read(folder: dir.path) == (getuid() == 0 ? .keeperInstalled(path: file.path) : .practice))
        // A link to a root-owned file is judged by the link's own owner.
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createSymbolicLink(atPath: file.path, withDestinationPath: "/etc/hosts")
        #expect(try SystemLaunchFolderProbe().ownerUID(of: file.path) == getuid())
    }

    @Test func theRealLaunchDaemonFolderCanBeRead() {
        // Reading only: the folder is world-readable on macOS. Whatever it holds, the answer is one of the three.
        let s = PracticeState.read()
        switch s { case .practice, .keeperInstalled, .unknown: break }
    }
}

#endif

@Suite struct PracticeMenuTests {
    @Test func pauseIsAllowedOnlyInThePracticeState() {
        #expect(PracticePresentation(.practice).pauseAllowed)
        #expect(!PracticePresentation(.keeperInstalled(path: "/Library/LaunchDaemons/org.safesightmac.keeper.plist")).pauseAllowed)
        #expect(!PracticePresentation(.unknown(reason: "x")).pauseAllowed)
    }

    @Test func theMenuSaysPlainlyThereIsNoLock() {
        let p = PracticePresentation(.practice)
        #expect(p.title == "Practice: no lock")
        #expect(p.detail.contains("no lock"))
    }

    #if !SAFESIGHTMAC_TESTING
    @Test func theSignalFlowsFromTheFolderToTheMenu() {
        let with = PracticePresentation(PracticeState.read(probe: FakeFolder(entries: ["org.safesightmac.keeper.plist": 0])))
        let without = PracticePresentation(PracticeState.read(probe: FakeFolder(entries: ["com.apple.x.plist": 0])))
        #expect(!with.pauseAllowed && without.pauseAllowed)
    }
    #endif

    @Test func theTestingEditionAlwaysAllowsPauseAndSaysThereIsNoLock() {
        let t = PracticePresentation.testing
        #expect(t.pauseAllowed)
        #expect(t.title == "Testing edition: no lock")
        #expect(t.detail.contains("no lock") && t.detail.contains("installs nothing"))
    }
}

@Suite struct ModelCheckTests {
    func folder(_ files: [String: String]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("safesightmac-models-\(UUID().uuidString)")
        for (path, text) in files {
            let u = dir.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: u)
        }
        return dir
    }
    func list(_ files: [String: String]) -> String {
        files.keys.sorted().map { WatcherModels.sha256(Data(files[$0]!.utf8)) + "  " + $0 }.joined(separator: "\n")
    }
    let files = ["a/a.mlpackage/Manifest.json": "{}", "a/a.mlpackage/Data/model.mlmodel": "synthetic bytes one",
                 "b/b.mlpackage/Manifest.json": "{ }", "b/b.mlpackage/Data/weights.bin": "synthetic bytes two"]

    @Test func matchingFilesPass() throws {
        let dir = try folder(files); defer { try? FileManager.default.removeItem(at: dir) }
        try WatcherModels.verify(folder: dir, hashList: list(files))
    }

    @Test func aChangedFileIsRefused() throws {
        var changed = files; changed["b/b.mlpackage/Data/weights.bin"] = "synthetic bytes TWO"
        let dir = try folder(changed); defer { try? FileManager.default.removeItem(at: dir) }
        #expect(throws: ModelCheckFailure.hashMismatch("b/b.mlpackage/Data/weights.bin")) { try WatcherModels.verify(folder: dir, hashList: list(files)) }
    }

    @Test func aMissingFileIsRefused() throws {
        var fewer = files; fewer["a/a.mlpackage/Manifest.json"] = nil
        let dir = try folder(fewer); defer { try? FileManager.default.removeItem(at: dir) }
        #expect(throws: ModelCheckFailure.missingFile("a/a.mlpackage/Manifest.json")) { try WatcherModels.verify(folder: dir, hashList: list(files)) }
    }

    @Test func anExtraFileInsideAPackageIsRefused() throws {
        var more = files; more["a/a.mlpackage/Data/extra.bin"] = "x"
        let dir = try folder(more); defer { try? FileManager.default.removeItem(at: dir) }
        #expect(throws: ModelCheckFailure.unlistedFile("a/a.mlpackage/Data/extra.bin")) { try WatcherModels.verify(folder: dir, hashList: list(files)) }
    }

    @Test func aMalformedListIsRefused() {
        for bad in ["", "nothex  a/b", String(repeating: "a", count: 64) + "  /abs/path", String(repeating: "a", count: 64) + "  a/../b"] {
            #expect(throws: ModelCheckFailure.self) { try WatcherModels.verify(folder: URL(fileURLWithPath: "/nonexistent"), hashList: bad) }
        }
    }

    @Test func theSealedDataMatchesTheCommittedFiles() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../models").standardized
        let list = try String(contentsOf: root.appendingPathComponent("watcher-models.sha256"), encoding: .utf8)
        #expect(WatcherModels.committedHashList == list.trimmingCharacters(in: .newlines))
        let thr = try Data(contentsOf: root.appendingPathComponent("thresholds.json"))
        #expect(String(decoding: WatcherModels.committedThresholds, as: UTF8.self) == String(decoding: thr, as: UTF8.self).trimmingCharacters(in: .newlines))
        #expect(try WatcherModels.parse(list).count == 10, "three packages, three files each, and the bundle's manifest")
    }

    /// Local only: the lab build's converted models, cloned beside the committed manifest, match the sealed list.
    @Test func theLabBuildsConvertedModelsMatchTheSealedList() throws {
        guard let dir = try Bundles.stagedLab() else { return }   // not on CI
        defer { try? FileManager.default.removeItem(at: dir) }
        try WatcherModels.verify(folder: dir)
        _ = try WatcherModels.readManifest(folder: dir)
    }
}
