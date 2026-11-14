// SPDX-License-Identifier: Apache-2.0
// The practice state (register SD-223). The watcher is in the practice state only while no
// root-owned keeper launch file exists on the Mac. That file cannot be removed by a standard user, so
// after Lock the watcher is never in the practice state, whatever starts it.
//
// The cover-only build of step 1 is the practice state shipped alone: no keeper, no shield, no fault
// ladder, no heartbeat, no updater. Quit is honoured, and pausing is allowed only because there is no
// lock. When the signal cannot be read, the watcher does not claim the practice state (it covers as
// usual and turns pause off): an unreadable signal never loosens anything.
import Darwin
import SafeSightMacCore
import Foundation

public enum PracticeSignal: Equatable, Sendable {
    /// No root-owned keeper launch file: the practice state.
    case practice
    /// A root-owned keeper launch file exists: not the practice state.
    case keeperInstalled(path: String)
    /// The check could not be completed: treated as not the practice state.
    case unknown(reason: String)

    public var isPractice: Bool { self == .practice }
}

/// What the signal needs from the file system, so the rule can be tested without touching it.
public protocol LaunchFolderProbe {
    /// Names in the folder. Throws `CocoaError(.fileReadNoSuchFile)` if the folder does not exist.
    func names(in folder: String) throws -> [String]
    /// The owner's user ID of the entry itself (not following a symbolic link).
    func ownerUID(of path: String) throws -> uid_t
}

/// The real file system: `lstat`, so a symbolic link is judged by its own owner.
public struct SystemLaunchFolderProbe: LaunchFolderProbe {
    public init() {}
    public func names(in folder: String) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder)
    }
    public func ownerUID(of path: String) throws -> uid_t {
        var st = stat()
        guard lstat(path, &st) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return st.st_uid
    }
}

public enum PracticeState {
    /// The system launch-daemon folder, where the keeper's launch file lives (register table 4e).
    public static let launchDaemonFolder = "/Library/LaunchDaemons"

    /// Whether a launch-file name is a keeper's. The identity file is not frozen yet, so the bundle
    /// identifier's reverse-domain prefix is not fixed: any `<rd>.safesightmac.keeper.plist`, release or lab
    /// (`<rd>.safesightmac.lab.keeper.plist`), counts (register 4e, table "The identity file" [P]).
    public static func isKeeperLaunchFile(_ name: String) -> Bool {
        let n = name.lowercased()
        return n.hasSuffix(".safesightmac.keeper.plist") || n.hasSuffix(".safesightmac.lab.keeper.plist")
            || n == "safesightmac.keeper.plist" || n == "safesightmac.lab.keeper.plist"
    }

    public static func read(probe: LaunchFolderProbe = SystemLaunchFolderProbe(), folder: String = launchDaemonFolder) -> PracticeSignal {
        let names: [String]
        do {
            names = try probe.names(in: folder)
        } catch let e as CocoaError where e.code == .fileReadNoSuchFile || e.code == .fileNoSuchFile {
            return .practice   // no launch-daemon folder at all, so no keeper launch file
        } catch {
            return .unknown(reason: "The launch-daemon folder could not be read.")
        }
        for name in names.sorted() where isKeeperLaunchFile(name) {
            let path = (folder as NSString).appendingPathComponent(name)
            do {
                if try probe.ownerUID(of: path) == 0 { return .keeperInstalled(path: path) }
                // Not root-owned: not a keeper launch file (only root can place one there).
            } catch {
                return .unknown(reason: "A keeper launch file's owner could not be read.")
            }
        }
        return .practice
    }
}

/// What the app's menu shows for the practice state, and whether pausing is allowed.
public struct PracticePresentation: Equatable, Sendable {
    public let title: String
    public let detail: String
    /// Pausing is allowed only in the practice state, because only then is there no lock.
    public let pauseAllowed: Bool

    public init(_ s: PracticeSignal) {
        switch s {
        case .practice:
            title = AppText.practiceTitle; detail = AppText.practiceDetail; pauseAllowed = true
        case .keeperInstalled:
            title = AppText.notPracticeTitle; detail = AppText.keeperFoundDetail; pauseAllowed = false
        case .unknown:
            title = AppText.notPracticeTitle; detail = AppText.practiceUnknownDetail; pauseAllowed = false
        }
    }
}
