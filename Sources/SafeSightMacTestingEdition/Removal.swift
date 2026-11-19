// SPDX-License-Identifier: Apache-2.0
// "Remove SafeSight Mac Testing": one click clears everything the app keeps, so that dragging it to the Trash
// leaves nothing of it behind but what macOS itself keeps (docs/TESTING-EDITION.md, "Removing it").
//
// What it keeps, all inside its sandbox container (…/Library/Containers/<id>/Data): its settings (only the detector
// mode, in Library/Preferences/<bundle id>.plist), the compiled models in tmp, the caches Core ML makes for them in
// Library/Caches, and any saved window state. The removal empties those folders and the settings, and nothing else:
// - only when the home folder is a sandbox container's Data folder; otherwise it removes the settings alone;
// - the folders themselves stay (macOS made them, and makes them again at the next start);
// - a symbolic link is never followed (a container holds links to the person's own folders): a link directly in
//   a cleared folder is left alone, and one inside a removed folder goes as a link, never what it points to.
import Darwin
import Foundation

/// The settings store, so tests can watch what is removed.
public protocol SettingsDomains: AnyObject {
    func removePersistentDomain(forName domainName: String)
}

extension UserDefaults: SettingsDomains {}

public enum Removal {
    /// The folders inside the container's Data folder whose contents are removed.
    public static let folders = ["Library/Caches", "Library/Application Support", "Library/Saved Application State",
                                 "Library/HTTPStorages", "Library/WebKit", "Library/Cookies", "tmp"]

    public struct Report: Equatable, Sendable {
        /// Paths removed, relative to the home folder.
        public var removed: [String] = []
        /// Entries left alone: symbolic links, and anything that could not be removed.
        public var leftAlone: [String] = []
        /// True when the home folder was not a sandbox container, so only the settings were removed.
        public var onlySettings = false
    }

    /// Removes the settings of `bundleID` and the contents of `folders` inside `home`.
    @discardableResult
    public static func run(bundleID: String, home: String = NSHomeDirectory(),
                           settings: SettingsDomains = UserDefaults.standard) -> Report {
        var report = Report()
        settings.removePersistentDomain(forName: bundleID)
        (settings as? UserDefaults)?.synchronize()
        guard Sandbox.containerID(ofHome: home) != nil else {
            report.onlySettings = true
            return report
        }
        let root = URL(fileURLWithPath: home, isDirectory: true).standardizedFileURL
        // The settings file itself, in case the settings store left it behind.
        let prefs = "Library/Preferences/\(bundleID).plist"
        if isPlainFile(root.appendingPathComponent(prefs).path) {
            remove(prefs, in: root, into: &report)
        }
        for folder in folders {
            let dir = root.appendingPathComponent(folder, isDirectory: true)
            guard isRealFolder(dir.path), let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { continue }
            for name in names.sorted() { remove(folder + "/" + name, in: root, into: &report) }
        }
        return report
    }

    static func remove(_ relative: String, in root: URL, into report: inout Report) {
        let path = root.appendingPathComponent(relative).path
        var st = stat()
        guard lstat(path, &st) == 0 else { return }
        if (st.st_mode & S_IFMT) == S_IFLNK { report.leftAlone.append(relative); return }
        // removeItem does not follow symbolic links inside a folder: it removes the links themselves.
        if (try? FileManager.default.removeItem(atPath: path)) != nil { report.removed.append(relative) }
        else { report.leftAlone.append(relative) }
    }

    static func isRealFolder(_ path: String) -> Bool {
        var st = stat()
        return lstat(path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFDIR
    }

    static func isPlainFile(_ path: String) -> Bool {
        var st = stat()
        return lstat(path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFREG
    }
}
