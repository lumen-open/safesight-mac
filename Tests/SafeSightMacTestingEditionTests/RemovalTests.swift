// SPDX-License-Identifier: Apache-2.0
// "Remove SafeSight Mac Testing" clears the app's own settings and data inside its sandbox container, and nothing
// else: never through a symbolic link, never a folder macOS made, never outside the container. Run on a made-up
// container in a temporary folder.
import Foundation
import Testing
@testable import SafeSightMacTestingEdition

final class FakeSettings: SettingsDomains {
    var removed: [String] = []
    func removePersistentDomain(forName domainName: String) { removed.append(domainName) }
}

@Suite struct RemovalTests {
    let id = "org.example.safesightmac.testing"
    let fm = FileManager.default

    struct Place {
        let root: URL, home: URL, outside: URL
    }

    func file(_ url: URL, _ text: String = "synthetic") throws {
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    /// A container as macOS lays it out, with the app's data in it, links to the person's own folders, and files
    /// outside it that must survive.
    func makeContainer() throws -> Place {
        let root = fm.temporaryDirectory.appendingPathComponent("safesightmac-removal-\(UUID().uuidString)")
        let home = root.appendingPathComponent("Library/Containers/\(id)/Data")
        let outside = root.appendingPathComponent("outside")
        try file(outside.appendingPathComponent("Desktop/notes.txt"))
        try file(outside.appendingPathComponent("keep.txt"))
        try file(outside.appendingPathComponent("keep-too.txt"))
        try file(home.appendingPathComponent("Library/Preferences/\(id).plist"))
        try file(home.appendingPathComponent("Library/Preferences/com.apple.other.plist"))
        try file(home.appendingPathComponent("Library/Caches/com.apple.e5rt.e5bundlecache/model/program.bin"))
        try file(home.appendingPathComponent("Library/Caches/plain.txt"))
        try file(home.appendingPathComponent("Library/Saved Application State/\(id).savedState/windows.plist"))
        try file(home.appendingPathComponent("tmp/safesightmac-compiled-1/model.mlmodelc/weights.bin"))
        try fm.createDirectory(at: home.appendingPathComponent("Library/Application Support"), withIntermediateDirectories: true)
        // Links: the container's own link to the Desktop, a link straight in Caches, and one inside a folder there.
        try fm.createSymbolicLink(at: home.appendingPathComponent("Desktop"), withDestinationURL: outside.appendingPathComponent("Desktop"))
        try fm.createSymbolicLink(at: home.appendingPathComponent("Library/Caches/link"), withDestinationURL: outside.appendingPathComponent("keep.txt"))
        try fm.createDirectory(at: home.appendingPathComponent("Library/Caches/folder"), withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: home.appendingPathComponent("Library/Caches/folder/inner-link"), withDestinationURL: outside.appendingPathComponent("keep-too.txt"))
        return Place(root: root, home: home, outside: outside)
    }

    func exists(_ url: URL) -> Bool { (try? url.checkResourceIsReachable()) == true || fm.fileExists(atPath: url.path) }
    func linkExists(_ url: URL) -> Bool { (try? fm.destinationOfSymbolicLink(atPath: url.path)) != nil }

    @Test func itClearsTheAppsOwnDataAndSettings() throws {
        let p = try makeContainer()
        defer { try? fm.removeItem(at: p.root) }
        let settings = FakeSettings()
        let report = Removal.run(bundleID: id, home: p.home.path, settings: settings)

        #expect(settings.removed == [id], "its own settings domain, and no other")
        #expect(!report.onlySettings)
        #expect(!exists(p.home.appendingPathComponent("Library/Preferences/\(id).plist")))
        #expect(!exists(p.home.appendingPathComponent("Library/Caches/com.apple.e5rt.e5bundlecache")))
        #expect(!exists(p.home.appendingPathComponent("Library/Caches/plain.txt")))
        #expect(!exists(p.home.appendingPathComponent("Library/Saved Application State/\(id).savedState")))
        #expect(!exists(p.home.appendingPathComponent("tmp/safesightmac-compiled-1")))
        #expect(report.removed.contains("Library/Preferences/\(id).plist"))
        #expect(report.removed.contains("tmp/safesightmac-compiled-1"))
        // The folders themselves stay: macOS made them.
        for f in Removal.folders where f != "Library/HTTPStorages" && f != "Library/WebKit" && f != "Library/Cookies" {
            #expect(exists(p.home.appendingPathComponent(f)), "\(f) itself is kept")
        }
    }

    @Test func itNeverFollowsOrRemovesALinkAndNeverTouchesAnythingOutside() throws {
        let p = try makeContainer()
        defer { try? fm.removeItem(at: p.root) }
        let report = Removal.run(bundleID: id, home: p.home.path, settings: FakeSettings())
        // The person's own files, reached through links, are all still there.
        #expect(exists(p.outside.appendingPathComponent("Desktop/notes.txt")))
        #expect(exists(p.outside.appendingPathComponent("keep.txt")))
        #expect(exists(p.outside.appendingPathComponent("keep-too.txt")))
        // The container's link to the Desktop is not in a cleared folder; a link straight in Caches is left alone.
        #expect(linkExists(p.home.appendingPathComponent("Desktop")))
        #expect(linkExists(p.home.appendingPathComponent("Library/Caches/link")))
        #expect(report.leftAlone.contains("Library/Caches/link"))
        // Another app's settings in the container are not its own.
        #expect(exists(p.home.appendingPathComponent("Library/Preferences/com.apple.other.plist")))
    }

    @Test func aClearedFolderThatIsALinkIsLeftAlone() throws {
        let p = try makeContainer()
        defer { try? fm.removeItem(at: p.root) }
        // tmp replaced by a link to a folder outside: nothing in that folder may go.
        let tmp = p.home.appendingPathComponent("tmp")
        try fm.removeItem(at: tmp)
        try file(p.outside.appendingPathComponent("elsewhere/precious.txt"))
        try fm.createSymbolicLink(at: tmp, withDestinationURL: p.outside.appendingPathComponent("elsewhere"))
        Removal.run(bundleID: id, home: p.home.path, settings: FakeSettings())
        #expect(exists(p.outside.appendingPathComponent("elsewhere/precious.txt")))
        #expect(linkExists(tmp))
    }

    @Test(arguments: ["/Users/someone", "/Users/someone/Library", "/Users/someone/Library/Containers/Data", "/"])
    func outsideASandboxContainerOnlyTheSettingsGo(_ home: String) throws {
        let settings = FakeSettings()
        let report = Removal.run(bundleID: id, home: home, settings: settings)
        #expect(report.onlySettings)
        #expect(report.removed.isEmpty && report.leftAlone.isEmpty)
        #expect(settings.removed == [id])
    }

    @Test func theSystemsFoldersAreClearedOnlyWhenTheyAreTheAppsOwn() throws {
        let p = try makeContainer()
        defer { try? fm.removeItem(at: p.root) }
        // As the sandbox gives them: folders named after the bundle identifier. And a shared one, as outside it.
        let ownCache = p.root.appendingPathComponent("var/folders/xy/C/\(id)")
        let shared = p.root.appendingPathComponent("var/folders/xy/T")
        try file(ownCache.appendingPathComponent("com.apple.metal/shader.bin"))
        try file(shared.appendingPathComponent("someone-elses.tmp"))
        try fm.createSymbolicLink(at: ownCache.appendingPathComponent("link"), withDestinationURL: p.outside.appendingPathComponent("keep.txt"))
        let report = Removal.run(bundleID: id, home: p.home.path, settings: FakeSettings(), system: [ownCache.path + "/", shared.path])
        #expect(!exists(ownCache.appendingPathComponent("com.apple.metal")))
        #expect(exists(ownCache), "the folder itself stays")
        #expect(exists(shared.appendingPathComponent("someone-elses.tmp")), "a shared folder is never emptied")
        #expect(linkExists(ownCache.appendingPathComponent("link")) && exists(p.outside.appendingPathComponent("keep.txt")))
        #expect(report.removed.contains("com.apple.metal"))
    }

    @Test func thisProcessesSystemFoldersAreShared() {
        // A test run is not sandboxed: its folders are the shared ones (…/C/ and …/T/), so nothing in them is touched.
        #expect(!Removal.systemFolders().isEmpty)
        #expect(Removal.systemFolders().allSatisfy { URL(fileURLWithPath: $0).lastPathComponent.count == 1 })
    }

    @Test func anotherAppsContainerIsNeverEmptied() throws {
        // A home that is a sandbox container, but not this app's: nothing in it is removed.
        let root = fm.temporaryDirectory.appendingPathComponent("safesightmac-removal-other-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let other = root.appendingPathComponent("Library/Containers/com.example.someone-else/Data")
        try file(other.appendingPathComponent("Library/Caches/their-cache.db"))
        try file(other.appendingPathComponent("tmp/their-work.txt"))
        let report = Removal.run(bundleID: id, home: other.path, settings: FakeSettings())
        #expect(report.onlySettings)
        #expect(exists(other.appendingPathComponent("Library/Caches/their-cache.db")))
        #expect(exists(other.appendingPathComponent("tmp/their-work.txt")))
    }

    @Test func aRealHomeFolderOutsideAContainerIsNeverEmptied() throws {
        // A made-up home with the same layout, but not a container: nothing in it is removed.
        let root = fm.temporaryDirectory.appendingPathComponent("safesightmac-removal-home-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        try file(root.appendingPathComponent("Library/Caches/someone-else/cache.db"))
        try file(root.appendingPathComponent("tmp/work.txt"))
        let report = Removal.run(bundleID: id, home: root.path, settings: FakeSettings())
        #expect(report.onlySettings)
        #expect(exists(root.appendingPathComponent("Library/Caches/someone-else/cache.db")))
        #expect(exists(root.appendingPathComponent("tmp/work.txt")))
    }
}
