// SPDX-License-Identifier: Apache-2.0
// The models' compiled copies: one folder per running process, removed when it quits, and folders left by
// processes that ended without quitting removed at the next start. A folder in use is never removed, and nothing
// without the folder prefix is touched. Run in a temporary folder.
import Darwin
import Foundation
import Testing
@testable import SafeSightMacWatcher

@Suite struct CompiledModelsTests {
    let fm = FileManager.default

    func parent() throws -> URL {
        let u = fm.temporaryDirectory.appendingPathComponent("safesightmac-compiled-test-\(UUID().uuidString)")
        try fm.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    @Test func aFolderInUseIsKeptAndRemovedWhenItsOwnerQuits() throws {
        let p = try parent()
        defer { try? fm.removeItem(at: p) }
        let f = try CompiledModelFolder(parent: p)
        try Data("synthetic weights".utf8).write(to: f.url.appendingPathComponent("model.bin"))
        #expect(f.url.lastPathComponent.hasPrefix(CompiledModelFolder.prefix))
        #expect(CompiledModelFolder.sweep(parent: p).isEmpty, "its lock is held: in use")
        #expect(fm.fileExists(atPath: f.url.appendingPathComponent("model.bin").path))
        f.remove()
        #expect(!fm.fileExists(atPath: f.url.path))
        f.remove()   // twice is harmless
    }

    @Test func aFolderLeftByAnEndedProcessIsSweptAway() throws {
        let p = try parent()
        defer { try? fm.removeItem(at: p) }
        // As a crashed run leaves it: the folder and its lock file, with nobody holding the lock.
        let stale = p.appendingPathComponent(CompiledModelFolder.prefix + "stale")
        try fm.createDirectory(at: stale.appendingPathComponent("model.mlmodelc"), withIntermediateDirectories: true)
        try Data().write(to: stale.appendingPathComponent(CompiledModelFolder.lockName))
        // Or with no lock file at all, made long ago.
        let bare = p.appendingPathComponent(CompiledModelFolder.prefix + "bare")
        try fm.createDirectory(at: bare, withIntermediateDirectories: true)
        try fm.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -2 * CompiledModelFolder.unlockedGrace)], ofItemAtPath: bare.path)
        // A folder with no lock file yet, just made: its maker may be about to take its lock.
        let fresh = p.appendingPathComponent(CompiledModelFolder.prefix + "fresh")
        try fm.createDirectory(at: fresh, withIntermediateDirectories: true)
        let live = try CompiledModelFolder(parent: p)
        defer { live.remove() }
        let removed = Set(CompiledModelFolder.sweep(parent: p).map(\.lastPathComponent))
        #expect(removed == [stale.lastPathComponent, bare.lastPathComponent])
        #expect(fm.fileExists(atPath: live.url.path))
        #expect(fm.fileExists(atPath: fresh.path))
    }

    @Test func nothingWithoutThePrefixAndNoLinkIsEverTouched() throws {
        let p = try parent()
        defer { try? fm.removeItem(at: p) }
        let other = p.appendingPathComponent("someone-elses-model.mlmodelc")
        try fm.createDirectory(at: other, withIntermediateDirectories: true)
        let target = p.appendingPathComponent("elsewhere")
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: target.appendingPathComponent("keep.txt"))
        try fm.createSymbolicLink(at: p.appendingPathComponent(CompiledModelFolder.prefix + "link"), withDestinationURL: target)
        #expect(CompiledModelFolder.sweep(parent: p).isEmpty)
        #expect(fm.fileExists(atPath: other.path))
        #expect(fm.fileExists(atPath: target.appendingPathComponent("keep.txt").path))
    }
}
