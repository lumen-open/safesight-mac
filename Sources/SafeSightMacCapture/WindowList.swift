// SPDX-License-Identifier: Apache-2.0
// The window-list snapshot (section 5.5): window number, owner process, layer and bounds, in
// front-to-back order, with each window's opacity. Window titles are never read. A list that cannot be read, or that
// lists no window at all (a Mac always shows some: the menu bar, the desktop), is marked unreadable: the cover layer
// covers the display whole rather than treat the screen as empty.
// macOS's own password prompt is marked when, and only when, its owner passes `PasswordPrompt`'s checks (by process,
// never by name), checked once per appearance of the window (`PromptOwners`).
import CoreGraphics
import SafeSightMacWatcher
import Foundation

public enum WindowList {
    public static func snapshot() -> WindowSnapshot {
        let now = ProcessInfo.processInfo.systemUptime
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]], !list.isEmpty else {
            return .unreadable(time: now)
        }
        var ownerIsWindowServer: [Int32: Bool] = [:]
        let windows: [WindowInfo] = list.compactMap { d in
            guard let n = d[kCGWindowNumber as String] as? UInt32 ?? (d[kCGWindowNumber as String] as? Int).flatMap({ UInt32(exactly: $0) }),
                  let pid = d[kCGWindowOwnerPID as String] as? Int32 ?? (d[kCGWindowOwnerPID as String] as? Int).flatMap({ Int32(exactly: $0) }),
                  let b = d[kCGWindowBounds as String] as? NSDictionary, let bounds = CGRect(dictionaryRepresentation: b as CFDictionary)
            else { return nil }
            let layer = d[kCGWindowLayer as String] as? Int ?? 0
            let alpha = (d[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1
            // Only a small window at the cursor's level is asked about, once per owner per read.
            var overlay = false
            if layer == WindowInfo.cursorLevel, WindowInfo.isSystemOverlay(layer: layer, bounds: bounds, ownerIsWindowServer: true) {
                let ws = ownerIsWindowServer[pid] ?? Self.runsAsWindowServer(pid)
                ownerIsWindowServer[pid] = ws
                overlay = WindowInfo.isSystemOverlay(layer: layer, bounds: bounds, ownerIsWindowServer: ws)
            }
            // Only a window shaped like the prompt (its level, opaque, dialog-sized) has its owner checked.
            let prompt = PasswordPrompt.shapeQualifies(layer: layer, bounds: bounds, alpha: alpha)
                && promptOwners.isPrompt(number: n, pid: pid)
            return WindowInfo(number: n, ownerPID: pid, layer: layer, bounds: bounds, alpha: alpha, systemOverlay: overlay,
                              passwordPrompt: prompt)
        }
        promptOwners.keep(only: Set(windows.map { PromptOwners.WindowKey(number: $0.number, pid: $0.ownerPID) }))
        return WindowSnapshot(windows: windows, time: now)
    }

    /// The prompt checks, with the real facts from the kernel and the file system.
    static let promptOwners = PromptOwners(facts: SystemProcessFacts.read, startTime: SystemProcessFacts.startTime,
                                           allowedUIDs: { promptUIDs })
    static let promptUIDs = SystemProcessFacts.promptUIDs()

    /// For the lab event log: whether each prompt-shaped window's owner passed each check (yes/no only: no name, no path).
    public static func promptCheck() -> String {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return "prompt=unreadable" }
        let shaped = list.compactMap { d -> String? in
            guard let pid = (d[kCGWindowOwnerPID as String] as? Int).flatMap({ Int32(exactly: $0) }),
                  (d[kCGWindowLayer as String] as? Int) == PasswordPrompt.level else { return nil }
            let b = (d[kCGWindowBounds as String] as? NSDictionary).flatMap { CGRect(dictionaryRepresentation: $0 as CFDictionary) } ?? .null
            let alpha = (d[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1
            guard let f = try? SystemProcessFacts.read(pid) else { return "L1000 shape=\(PasswordPrompt.shapeQualifies(layer: 1000, bounds: b, alpha: alpha)) facts=none" }
            return "L1000 shape=\(PasswordPrompt.shapeQualifies(layer: 1000, bounds: b, alpha: alpha)) sealed=\(f.onSealedSystemVolume) "
                + "bundle=\(f.bundleID.map { PasswordPrompt.bundleIDs.contains($0) } ?? false) uid=\(promptUIDs.contains(f.uid)) "
                + "owner=\(PasswordPrompt.ownerQualifies(f, allowedUIDs: promptUIDs))"
        }
        return "prompt=[" + shaped.joined(separator: ",") + "]"
    }

    /// The user the window server runs as (`_windowserver`), looked up by that account's name in the system's user
    /// list. Nil if it cannot be read: then no window counts as the window server's.
    static let windowServerUID: uid_t? = {
        guard let pw = getpwnam("_windowserver") else { return nil }
        return pw.pointee.pw_uid
    }()

    /// The user a process runs as, from the kernel's process table (no name is read). Nil if it cannot be read.
    static func uid(of pid: Int32) -> uid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size == MemoryLayout<kinfo_proc>.stride, info.kp_proc.p_pid == pid else { return nil }
        return info.kp_eproc.e_ucred.cr_uid
    }

    /// True only when the process is known to run as the window server's own user. Any doubt is false.
    static func runsAsWindowServer(_ pid: Int32) -> Bool {
        guard pid > 0, let ws = windowServerUID, ws != 0, let u = uid(of: pid) else { return false }
        return u == ws
    }

    /// For the lab event log: the window server's user, and whether the lookups work here (inside the sandbox).
    public static func overlayCheck() -> String {
        "windowServerUID=\(windowServerUID.map { String($0) } ?? "nil") selfUID=\(uid(of: getpid()).map { String($0) } ?? "nil")"
    }
}
