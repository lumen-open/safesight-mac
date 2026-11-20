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

    /// Other builds of the Testing edition that are running: the same identifier with or without `.lab` before
    /// `.testing` (a lab build and a normal one both register ⌃⌥⌘Q). Only identifiers are compared; none is kept.
    public static func otherTestingCopies(ownID: String?, ownPID: pid_t, running: [(id: String?, pid: pid_t)]) -> [pid_t] {
        guard let base = ownID.flatMap(testingBase) else { return [] }
        return running.filter { $0.pid != ownPID && $0.id.flatMap(testingBase) == base }.map(\.pid)
    }

    /// `x.testing` and `x.lab.testing` both give `x`; any other identifier gives nil.
    static func testingBase(_ id: String) -> String? {
        if id.hasSuffix(".lab.testing") { return String(id.dropLast(".lab.testing".count)) }
        if id.hasSuffix(".testing") { return String(id.dropLast(".testing".count)) }
        return nil
    }

    /// Whether another build of the Testing edition is running now (it may be the one holding ⌃⌥⌘Q).
    public static func anotherTestingCopyRunning() -> Bool {
        let running = NSWorkspace.shared.runningApplications.map { (id: $0.bundleIdentifier, pid: $0.processIdentifier) }
        return !otherTestingCopies(ownID: Bundle.main.bundleIdentifier, ownPID: ProcessInfo.processInfo.processIdentifier, running: running).isEmpty
    }

    /// The same question, asked of the running apps.
    public static func anotherCopyRunning() -> Bool {
        let id = Bundle.main.bundleIdentifier
        let pids = id.map { NSRunningApplication.runningApplications(withBundleIdentifier: $0).map(\.processIdentifier) } ?? []
        return anotherCopyRunning(bundleID: id, ownPID: ProcessInfo.processInfo.processIdentifier, running: pids)
    }
}
