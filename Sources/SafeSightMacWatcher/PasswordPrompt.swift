// SPDX-License-Identifier: Apache-2.0
// The one window left uncovered on purpose: macOS's own password prompt (the authorization dialog that asks for an
// administrator's name and password). An owner must always be able to type their password, even while the screen
// around the prompt is covered. It is a deliberate, permanent hole in the cover, so it is kept as narrow as it can be:
//
// - Which window. Only facts an ordinary app cannot set for itself count (`PromptOwners`, `ownerQualifies`): the
//   owning process's executable, read from the kernel by process identifier, must lie on the read-only system snapshot
//   macOS booted from and be the executable of Apple's SecurityAgent bundle; System Integrity Protection and
//   authenticated root must both be on (`SystemIntegrity`), so that snapshot is Apple's sealed one and no process can
//   inject code into SecurityAgent; the process must run as the owner's own user or as `_securityagent`; and its start
//   time must be the same before and after it was checked. A window's or an app's name is never read and never counts.
//   What this does not cover: an administrator can install an authorization plug-in (`/Library/Security/
//   SecurityAgentPlugins`, writable only by an administrator) and so run code inside SecurityAgent or its helper, and
//   that code could draw any window. SecurityAgent's helpers, which exist to host such plug-ins, are never exempt; an
//   owner who is not an administrator (as SafeSight's lock makes them) cannot install one. On top of that the window
//   itself must look like the prompt (`shapeQualifies`, `DisplayPipeline.promptHoles`): exactly at the level the
//   prompt was read at, fully opaque, no larger than a dialog, at most a quarter of its display, and wholly on it.
// - What is left clear. Only that window's own rectangle, less every window in front of it, only while it is in the
//   window list where the last look saw it, and never more of it than showed when it was judged (a window that stood in
//   front of it and went uncovers something never judged as the prompt: it is judged again first). The list is read
//   again once judging is done (a hole made again from it may only shrink), and just before every drawing of a hole
//   that cuts a cover, and while such a hole is open, 20 times a second, the same window (by number and owner) must
//   still stand at the same place (`PasswordPrompt.holeStillOpen`, `HoleGate.confirm`), so a hole closes in the first
//   drawing after its prompt goes. A hole that cuts no cover (nothing around the prompt is covered) only has its
//   backing drawn: nothing waits on it. A plain, opaque cover is drawn behind it, below its level
//   (`CoverLevel.behindPrompt`), never animated, at least as large as the hole, and the hole opens only on a drawing
//   after the window server shows that cover in place at full opacity (`HoleGate`, `BackingCheck`), so a see-through
//   or rounded part of the prompt never shows what lies behind.
// - Its own content is still judged. The prompt shows the requesting app's name and icon, and an app can choose that
//   icon (its own, or a picture it names when it asks), drawn at about 64 by 64 points. So the hole opens only once the
//   prompt's own pixels have been judged since it appeared or moved (it is judged first, with a small budget of its
//   own), and its own covers and blurs (a flagged picture in it) are drawn inside the hole like any window's. Once
//   open, a small change in it (typing, the caret) is covered block by block until judged, within the normal budget;
//   a large one (a quarter of it, or reaching a picture in it, its icon), a new request in the same window included,
//   closes the whole hole until it is judged again (`DisplayPipeline.promptCoverFirst`).
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
    /// The one bundle whose windows may be the prompt: Apple's SecurityAgent, which draws the authorization dialog (Touch
    /// ID for administrator rights included). Not its helpers (`com.apple.SecurityAgentHelper.*`, inside its bundle):
    /// they host third-party authorization plug-ins, whose code can draw any window. If the dialog turns out to be drawn
    /// by a helper on some macOS, it stays covered there (the lab log's `prompt` lines show which owner a level-1000
    /// window has). Not LocalAuthentication's own sheets (`coreautha`, which apps use for their own Touch ID checks), not
    /// `authorizationhost` (which draws nothing), and not the login window (above the covers already).
    public static let bundleIDs: Set<String> = ["com.apple.SecurityAgent"]

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
        /// True when the executable lies on the read-only system snapshot macOS booted from (`statfs`: the root file
        /// system, mounted read-only from a snapshot). That alone is not a seal: only with authenticated root and System
        /// Integrity Protection on (`SystemIntegrity.intact`, checked by `PromptOwners`) is it Apple's sealed volume, where
        /// nothing can be added or changed, so an app cannot put its own program there.
        public var onSealedSystemVolume: Bool
        /// The bundle identifier and executable name in the Info.plist of the bundle the executable sits in (its
        /// `Contents/MacOS` folder). On the sealed volume, that file is Apple's too (read only when it lies there).
        public var bundleID: String?
        public var bundleExecutable: String?

        public init(executablePath: String, uid: uid_t, startTime: UInt64, onSealedSystemVolume: Bool,
                    bundleID: String?, bundleExecutable: String?) {
            self.executablePath = executablePath; self.uid = uid; self.startTime = startTime
            self.onSealedSystemVolume = onSealedSystemVolume; self.bundleID = bundleID; self.bundleExecutable = bundleExecutable
        }
    }

    /// Whether a process is the one that draws the prompt: its executable is on the read-only system snapshot and is the
    /// executable of SecurityAgent's own bundle (`bundleIDs`), and it runs as one of `allowedUIDs` (the owner's own
    /// user, under which SecurityAgent runs in a login session, or `_securityagent`). `PromptOwners` also requires
    /// `SystemIntegrity.intact`.
    ///
    /// Why each part cannot be faked by an ordinary app: the path comes from the kernel for the running image; with
    /// authenticated root and System Integrity Protection on, the snapshot is read-only and cryptographically sealed, so
    /// no app can place or change a file there, and no process can inject code into one running from it (a path that
    /// only starts with "/System/" is not enough: `/System/Volumes/Data` is the writable data volume, and it fails here);
    /// the bundle's Info.plist sits on that same volume; the user comes from the kernel. A copy of SecurityAgent run from
    /// anywhere else, a program named SecurityAgent, or an app with that bundle identifier on the data volume all fail.
    public static func ownerQualifies(_ f: OwnerFacts, allowedUIDs: Set<uid_t>) -> Bool {
        guard f.onSealedSystemVolume, allowedUIDs.contains(f.uid), let id = f.bundleID, bundleIDs.contains(id),
              let exe = f.bundleExecutable, !exe.isEmpty, !exe.contains("/") else { return false }
        return f.executablePath.hasSuffix(".bundle/Contents/MacOS/" + exe)
    }
}

extension PasswordPrompt {
    /// Whether a hole a plan asks for may be drawn now, by the window list read just before the covers are drawn (the
    /// plan itself may come from a window list read well before, when its frame was taken for judging): the hole is one
    /// of `prompt`'s, and that same window (its number and owner: another window, even at the same place, was never
    /// judged) is still the prompt (its owner checked, its shape as `shapeQualifies` asks, wholly on its display) at
    /// exactly the rectangle it had; no window in front of it (the pointer and the window server's other small overlays
    /// excepted) reaches into the hole; and no window behind it sits at or above the backing's level
    /// (`CoverLevel.behindPrompt`) where it is. `ignoring` is this app's own windows. A list that cannot be read, or any
    /// doubt, is no.
    public static func holeStillOpen(_ hole: CGRect, of prompt: PromptFrame, display: CGRect, in snapshot: WindowSnapshot,
                                     ignoring: Set<Int32>) -> Bool {
        guard snapshot.readable, hole.hasArea, prompt.holes.contains(hole) else { return false }
        let others = snapshot.windows.filter { $0.shows && !ignoring.contains($0.ownerPID) && !$0.systemOverlay }
        guard let i = others.firstIndex(where: { $0.number == prompt.number && $0.ownerPID == prompt.ownerPID }) else { return false }
        let w = others[i]
        guard w.passwordPrompt, w.bounds == prompt.frame, w.bounds.contains(hole),
              shapeQualifies(layer: w.layer, bounds: w.bounds, alpha: w.alpha), fits(w.bounds, display: display) else { return false }
        if others[..<i].contains(where: { $0.bounds.intersection(hole).hasArea }) { return false }
        if others[(i + 1)...].contains(where: { $0.layer >= CoverLevel.behindPrompt && $0.bounds.intersects(w.bounds) }) { return false }
        return true
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
    let systemIntact: () -> Bool
    struct Key: Hashable { var number: UInt32; var pid: Int32 }
    /// Each window checked while it has been listed: its owner's start time when checked, and the answer.
    var known: [Key: (start: UInt64, prompt: Bool)] = [:]
    /// How many owner checks ran (for tests: a window is checked once per appearance).
    public private(set) var checks = 0
    private let lock = NSLock()

    public init(facts: @escaping Facts, startTime: @escaping (Int32) -> UInt64?, allowedUIDs: @escaping () -> Set<uid_t>,
                systemIntact: @escaping () -> Bool) {
        self.facts = facts; self.startTime = startTime; self.allowedUIDs = allowedUIDs; self.systemIntact = systemIntact
    }

    /// True only when this window's owner is the prompt's process (see `PasswordPrompt.ownerQualifies`), on a Mac with
    /// System Integrity Protection and authenticated root on (asked every time: a doubt is no).
    public func isPrompt(number: UInt32, pid: Int32) -> Bool {
        guard pid > 0, systemIntact(), let now = startTime(pid) else { return false }
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

/// Whether System Integrity Protection and authenticated root are on, as the kernel reports them
/// (`csr_get_active_config`, exported by libSystem; it needs no framework and works inside the App Sandbox, checked on
/// macOS 26). With either turned off, the system snapshot need not be Apple's sealed one, and code can be injected into
/// SecurityAgent, so no window is the prompt. A configuration that cannot be read counts as off.
public enum SystemIntegrity {
    /// True when the kernel's configuration was read and is exactly 0: System Integrity Protection fully on, authenticated
    /// root on, nothing relaxed. Any bit set, a bit unknown today included, is not intact.
    public static func intact(read: (UnsafeMutablePointer<UInt32>) -> Int32 = csrActiveConfig) -> Bool {
        var config: UInt32 = .max
        guard read(&config) == 0 else { return false }
        return config == 0
    }

    public static let csrActiveConfig: (UnsafeMutablePointer<UInt32>) -> Int32 = { csr_get_active_config($0) }
}

@_silgen_name("csr_get_active_config")
private func csr_get_active_config(_ config: UnsafeMutablePointer<UInt32>) -> Int32

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

    /// True when `path` lies on the root file system, mounted read-only from a snapshot (not by itself proof of a seal:
    /// `SystemIntegrity` adds that): the system volume
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
        // The bundle around the executable: <bundle>/Contents/MacOS/<executable>. Read only on the read-only system volume.
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
