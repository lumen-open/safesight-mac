// SPDX-License-Identifier: Apache-2.0
// The one window left uncovered on purpose: macOS's own password prompt (the authorization dialog that asks for an
// administrator's name and password). An owner must always be able to type their password, even while the screen
// around the prompt is covered. It is a deliberate, permanent hole in the cover, so it is kept as narrow as it can be:
//
// - Which window. Only facts an ordinary app cannot set for itself count (`PromptOwners`, `ownerQualifies`): the
//   owning process's executable, read from the kernel by process identifier, must lie on the sealed system volume and
//   be the executable of Apple's SecurityAgent bundle (or of its helper); the process must run as the owner's own user
//   or as `_securityagent`; and its start time must be the same before and after it was checked. A window's or an
//   app's name is never read and never counts. On top of that the window itself must look like the prompt
//   (`shapeQualifies`, `DisplayPipeline.promptHoles`): exactly at the level the prompt was read at, fully opaque, no
//   larger than a dialog, at most a quarter of its display, and wholly on that display.
// - What is left clear. Only that window's own rectangle, less every window in front of it, and only while it is in
//   the window list. A plain cover stays drawn behind it, below its level (`CoverLevel.behindPrompt`), so a see-through
//   or rounded part of the prompt never shows what lies behind.
// - Its own content is still judged. The prompt shows the requesting app's name and icon, and an app can choose that
//   icon (its own, or a picture it names when it asks), drawn at about 64 by 64 points. So the hole opens only once the
//   prompt's own pixels have been judged since it appeared (it is judged first, with a small budget of its own), and
//   its own covers and blurs (a flagged picture in it) are drawn inside the hole like any window's.
// - Any doubt covers, as today: an owner that cannot be read or checked, a process that changed, a window too large
//   or not opaque, another window at or above the backing level behind it, or a display that cannot be judged.
//
// Nothing else is exempt: no rule for "system windows" in general. A remote-desktop or virtual-machine window showing
// a prompt is an ordinary window of its app and is covered like any other.
import CoreGraphics
import Darwin
import Foundation

public enum PasswordPrompt {
    /// The window level macOS's authorization prompt was read at (macOS 26, on a test virtual Mac): 1000, below the
    /// covers. A prompt at any other level is not exempt.
    public static let level = 1000
    /// The largest prompt, in points on each side. The dialog was about 260 by 400 points on macOS 26 (its older layout,
    /// still in the system, is 443 by 210); this leaves room for larger text, never for a window the size of a screen.
    public static let maxWidth: CGFloat = 640
    public static let maxHeight: CGFloat = 720
    /// The largest share of its display a prompt may take.
    public static let maxShareOfDisplay: CGFloat = 0.25
    /// The bundles whose windows may be the prompt: Apple's SecurityAgent, which draws the authorization dialog (Touch ID
    /// for administrator rights included), and the helpers inside it, which may draw it for an older plug-in. Not
    /// LocalAuthentication's own sheets (`coreautha`, which apps use for their own Touch ID checks), not
    /// `authorizationhost` (which draws nothing), and not the login window (above the covers already).
    public static let bundleIDs: Set<String> = ["com.apple.SecurityAgent", "com.apple.SecurityAgentHelper.arm64",
                                                "com.apple.SecurityAgentHelper.x86_64"]

    /// The window's own facts from the window list, checked before anything is asked about its owner: exactly at the
    /// prompt's level, fully opaque (a window at less than full opacity shows what is behind it), and no larger than
    /// a dialog. Any app can set these for its own window: they only narrow the rule, they never prove anything.
    public static func shapeQualifies(layer: Int, bounds: CGRect, alpha: Double) -> Bool {
        guard layer == level, alpha.isFinite, alpha >= 0.999 else { return false }
        guard bounds.minX.isFinite, bounds.minY.isFinite, bounds.width.isFinite, bounds.height.isFinite else { return false }
        return bounds.width > 0 && bounds.height > 0 && bounds.width <= maxWidth && bounds.height <= maxHeight
    }

    /// Whether a prompt-shaped window fits its display: wholly on it, and no more than `maxShareOfDisplay` of it.
    public static func fits(_ bounds: CGRect, display: CGRect) -> Bool {
        guard display.width > 0, display.height > 0, display.contains(bounds) else { return false }
        return bounds.width * bounds.height <= maxShareOfDisplay * display.width * display.height
    }

    /// What the kernel and the file system say about a window's owning process. Every field comes from the system by
    /// process identifier or by the executable's path, never from a name the process gives itself.
    public struct OwnerFacts: Equatable, Sendable {
        /// The executable the process runs, from the kernel (`proc_pidpath`).
        public var executablePath: String
        /// The user the process runs as, from the kernel's process table.
        public var uid: uid_t
        /// When the process started (microseconds), from the kernel's process table: a reused process identifier has
        /// another.
        public var startTime: UInt64
        /// True when the executable lies on the sealed, read-only system volume that macOS booted from (`statfs`: the
        /// root file system, mounted read-only from its sealed snapshot). Nothing can be added or changed there while
        /// System Integrity Protection is on, so an app cannot put its own program there.
        public var onSealedSystemVolume: Bool
        /// The bundle identifier and executable name in the Info.plist of the bundle the executable sits in (its
        /// `Contents/MacOS` folder). On the sealed volume, that file is Apple's too.
        public var bundleID: String?
        public var bundleExecutable: String?

        public init(executablePath: String, uid: uid_t, startTime: UInt64, onSealedSystemVolume: Bool,
                    bundleID: String?, bundleExecutable: String?) {
            self.executablePath = executablePath; self.uid = uid; self.startTime = startTime
            self.onSealedSystemVolume = onSealedSystemVolume; self.bundleID = bundleID; self.bundleExecutable = bundleExecutable
        }
    }

    /// Whether a process is the one that draws the prompt: its executable is on the sealed system volume and is the
    /// executable of one of `bundleIDs`, and it runs as one of `allowedUIDs` (the owner's own user, under which
    /// SecurityAgent runs in a login session, or `_securityagent`).
    ///
    /// Why each part cannot be faked by an ordinary app: the path comes from the kernel for the running image; the
    /// sealed volume is read-only and cryptographically sealed, so no app can place or change a file there (a path
    /// that only starts with "/System/" is not enough: `/System/Volumes/Data` is the writable data volume, and it fails
    /// here); the bundle's Info.plist sits on that same volume; the user comes from the kernel. A copy of SecurityAgent
    /// run from anywhere else, a program named SecurityAgent, or an app with that bundle identifier on the data volume
    /// all fail.
    public static func ownerQualifies(_ f: OwnerFacts, allowedUIDs: Set<uid_t>) -> Bool {
        guard f.onSealedSystemVolume, allowedUIDs.contains(f.uid), let id = f.bundleID, bundleIDs.contains(id),
              let exe = f.bundleExecutable, !exe.isEmpty, !exe.contains("/") else { return false }
        return f.executablePath.hasSuffix(".bundle/Contents/MacOS/" + exe) || f.executablePath.hasSuffix(".xpc/Contents/MacOS/" + exe)
    }
}

/// Which windows are the prompt, checked once each time a window appears and kept only while it stays in the window
/// list. The facts are read by `facts` (`SystemProcessFacts.read` in the app; injected in tests). Nothing is kept by
/// process identifier alone: a window is known by its number and its owner's identifier and start time, and a window
/// that leaves the list and comes back is checked again. A check that throws, or facts that changed while it ran,
/// count as "not the prompt". Thread-safe.
public final class PromptOwners: @unchecked Sendable {
    public typealias Facts = (Int32) throws -> PasswordPrompt.OwnerFacts
    let facts: Facts
    let startTime: (Int32) -> UInt64?
    let allowedUIDs: () -> Set<uid_t>
    struct Key: Hashable { var number: UInt32; var pid: Int32 }
    /// Each window checked while it has been listed: its owner's start time when checked, and the answer.
    var known: [Key: (start: UInt64, prompt: Bool)] = [:]
    /// How many owner checks ran (for tests: a window is checked once per appearance).
    public private(set) var checks = 0
    private let lock = NSLock()

    public init(facts: @escaping Facts, startTime: @escaping (Int32) -> UInt64?, allowedUIDs: @escaping () -> Set<uid_t>) {
        self.facts = facts; self.startTime = startTime; self.allowedUIDs = allowedUIDs
    }

    /// True only when this window's owner is the prompt's process (see `PasswordPrompt.ownerQualifies`).
    public func isPrompt(number: UInt32, pid: Int32) -> Bool {
        guard pid > 0, let now = startTime(pid) else { return false }
        let key = Key(number: number, pid: pid)
        lock.lock(); let seen = known[key]; lock.unlock()
        if let seen, seen.start == now { return seen.prompt }
        let f: PasswordPrompt.OwnerFacts?
        do { f = try facts(pid) } catch { f = nil }
        // Read again after the check: a process that ended (and an identifier given to another) in between never counts.
        let after = startTime(pid)
        let ok = f.map { PasswordPrompt.ownerQualifies($0, allowedUIDs: allowedUIDs()) && $0.startTime == now } == true && after == now
        lock.lock(); known[key] = (now, ok); checks += 1; lock.unlock()
        return ok
    }

    /// Forgets every window not in `listed` (number and owner): a window that went and comes back is checked again.
    public func keep(only listed: Set<WindowKey>) {
        lock.lock(); known = known.filter { listed.contains(WindowKey(number: $0.key.number, pid: $0.key.pid)) }; lock.unlock()
    }

    public struct WindowKey: Hashable, Sendable {
        public var number: UInt32, pid: Int32
        public init(number: UInt32, pid: Int32) { self.number = number; self.pid = pid }
    }
}

/// The real facts about a process, from the kernel and the file system: `proc_pidpath`, the kernel's process table and
/// `statfs`, and the Info.plist of the bundle around the executable. No name is read from the process, no framework
/// for code signatures is linked (the Testing app may not link Security.framework: `tools/check-testing-edition.sh`),
/// and no path is written into the program. All of these work inside the App Sandbox (checked with an ad hoc signed,
/// sandboxed tool on macOS 26).
public enum SystemProcessFacts {
    public enum Failure: Error { case noPath, noProcess, noVolume }

    /// The executable a process runs, from the kernel.
    public static func executablePath(_ pid: Int32) -> String? {
        var buf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let n = proc_pidpath(pid, &buf, UInt32(buf.count))
        guard n > 0 else { return nil }
        return String(cString: buf)
    }

    /// The process's user and start time (microseconds), from the kernel's process table. Nil if it cannot be read.
    public static func process(_ pid: Int32) -> (uid: uid_t, start: UInt64)? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard pid > 0, sysctl(&mib, 4, &info, &size, nil, 0) == 0, size == MemoryLayout<kinfo_proc>.stride, info.kp_proc.p_pid == pid
        else { return nil }
        let t = info.kp_proc.p_starttime
        guard t.tv_sec > 0 else { return nil }
        return (info.kp_eproc.e_ucred.cr_uid, UInt64(t.tv_sec) * 1_000_000 + UInt64(max(0, t.tv_usec)))
    }

    public static func startTime(_ pid: Int32) -> UInt64? { process(pid)?.start }

    /// True when `path` lies on the root file system, mounted read-only from its sealed snapshot: the system volume
    /// macOS booted from. The data volume (`/System/Volumes/Data`, and everything firmlinked into it, such as
    /// `/Applications` or `/Library`) is another, writable file system, and fails.
    public static func onSealedSystemVolume(_ path: String) -> Bool {
        var f = statfs(), root = statfs()
        guard statfs(path, &f) == 0, statfs("/", &root) == 0 else { return false }
        let need = UInt32(MNT_RDONLY) | UInt32(MNT_ROOTFS) | UInt32(MNT_SNAPSHOT)
        return f.f_flags & need == need && root.f_flags & need == need
            && f.f_fsid.val.0 == root.f_fsid.val.0 && f.f_fsid.val.1 == root.f_fsid.val.1
    }

    /// Everything `PasswordPrompt.ownerQualifies` needs about a process. Throws when the process cannot be read.
    public static func read(_ pid: Int32) throws -> PasswordPrompt.OwnerFacts {
        guard let p = process(pid) else { throw Failure.noProcess }
        guard let path = executablePath(pid), path.hasPrefix("/") else { throw Failure.noPath }
        let sealed = onSealedSystemVolume(path)
        // The bundle around the executable: <bundle>/Contents/MacOS/<executable>. Read only on the sealed volume.
        var id: String?, exe: String?
        let url = URL(fileURLWithPath: path)
        let contents = url.deletingLastPathComponent().deletingLastPathComponent()
        if sealed, url.deletingLastPathComponent().lastPathComponent == "MacOS", contents.lastPathComponent == "Contents",
           onSealedSystemVolume(contents.appendingPathComponent("Info.plist").path),
           let info = NSDictionary(contentsOf: contents.appendingPathComponent("Info.plist")) {
            id = info["CFBundleIdentifier"] as? String
            exe = info["CFBundleExecutable"] as? String
        }
        return PasswordPrompt.OwnerFacts(executablePath: path, uid: p.uid, startTime: p.start, onSealedSystemVolume: sealed,
                                         bundleID: id, bundleExecutable: exe)
    }

    /// The users SecurityAgent runs as: the owner's own (in a login session) and `_securityagent` (looked up in the
    /// system's user list; left out if it cannot be read).
    public static func promptUIDs() -> Set<uid_t> {
        var s: Set<uid_t> = [getuid()]
        if let pw = getpwnam("_securityagent") { s.insert(pw.pointee.pw_uid) }
        return s.filter { $0 != 0 }
    }
}
