// SPDX-License-Identifier: Apache-2.0
// One copy at a time. Two copies (one left in Downloads, one in Applications) would each draw covers, fight over
// ⌃⌥⌘Q and confuse anyone trying to quit. A second copy finds the first and quits at once.
import AppKit

public enum SingleCopy {
    /// True when another process with the same bundle identifier is running.
    public static func anotherCopyRunning(bundleID: String?, ownPID: pid_t, running: [pid_t]) -> Bool {
        guard bundleID != nil else { return false }
        return running.contains { $0 != ownPID }
    }

    /// The same question, asked of the running apps.
    public static func anotherCopyRunning() -> Bool {
        let id = Bundle.main.bundleIdentifier
        let pids = id.map { NSRunningApplication.runningApplications(withBundleIdentifier: $0).map(\.processIdentifier) } ?? []
        return anotherCopyRunning(bundleID: id, ownPID: ProcessInfo.processInfo.processIdentifier, running: pids)
    }
}
