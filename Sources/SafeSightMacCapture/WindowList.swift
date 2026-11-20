// SPDX-License-Identifier: Apache-2.0
// The window-list snapshot (section 5.5): window number, owner process, layer and bounds, in
// front-to-back order, with each window's opacity. Window titles are never read. A list that cannot be read, or that
// lists no window at all (a Mac always shows some: the menu bar, the desktop), is marked unreadable: the cover layer
// covers the display whole rather than treat the screen as empty.
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
            return WindowInfo(number: n, ownerPID: pid, layer: layer, bounds: bounds, alpha: alpha, systemOverlay: overlay)
        }
        return WindowSnapshot(windows: windows, time: now)
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
