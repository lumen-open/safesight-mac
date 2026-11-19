// SPDX-License-Identifier: Apache-2.0
// `safesightmac-harness vanish`: checks that a process's covers go the moment it ends, however it ends.
//
// Covers are the app's own windows (CoverPanel), and the window server removes every window of a process when the
// process ends. This shows it with a real cover window: a child copy of the harness makes one, keeps it fully
// transparent, one point square and far off every display (nothing is seen and nothing is captured), and prints
// its window number. The parent finds that window in the window list (numbers and owners only, no titles, no
// pixels), ends the child, and times how long the window lingers:
// - "killed": SIGKILL, as abrupt as a crash, with no chance to tidy up;
// - "quit": the child ends itself normally.
// No crash report is made (SIGKILL is not a crash). Prints one JSON line; exits 1 if a window outlives its process.
import AppKit
import Foundation
import SafeSightMacCover

enum Vanish {
    static func child() -> Never {
        MainActor.assumeIsolated {
            let app = NSApplication.shared
            app.setActivationPolicy(.prohibited)   // no Dock icon, no menu
            let w = CoverDrawing.coverWindowForLifetimeCheck(frame: CGRect(x: -30000, y: -30000, width: 1, height: 1))
            w.alphaValue = 0
            w.orderFrontRegardless()
            print(w.windowNumber)
            fflush(stdout)
        }
        // Ends itself when the parent closes our input ("quit"); the parent may kill it first ("killed").
        _ = FileHandle.standardInput.readDataToEndOfFile()
        exit(0)
    }

    static func windowExists(_ number: Int) -> Bool {
        let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
        return list.contains { ($0[kCGWindowNumber as String] as? Int) == number }
    }

    /// Waits up to `limit` seconds for `condition`; returns the seconds it took, or nil.
    static func wait(_ limit: TimeInterval, _ condition: () -> Bool) -> TimeInterval? {
        let start = Date()
        while Date().timeIntervalSince(start) < limit {
            if condition() { return Date().timeIntervalSince(start) }
            usleep(5_000)
        }
        return condition() ? Date().timeIntervalSince(start) : nil
    }

    /// One child: made, found, ended by `end`; returns (found, seconds until its window was gone or nil).
    static func trial(_ end: (Process, Pipe) -> Void) -> (found: Bool, gone: TimeInterval?) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        p.arguments = ["vanish", "--child"]
        let input = Pipe(), output = Pipe()
        p.standardInput = input
        p.standardOutput = output
        do { try p.run() } catch { return (false, nil) }
        var line = Data()
        while !line.contains(UInt8(ascii: "\n")) {
            let d = output.fileHandleForReading.availableData
            if d.isEmpty { break }
            line.append(d)
        }
        guard let n = Int(String(decoding: line, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)),
              wait(2, { windowExists(n) }) != nil else {
            p.terminate(); return (false, nil)
        }
        end(p, input)
        p.waitUntilExit()
        return (true, wait(2, { !windowExists(n) }))
    }

    static func run() -> Never {
        let killed = trial { p, _ in kill(p.processIdentifier, SIGKILL) }
        let quit = trial { _, input in try? input.fileHandleForWriting.close() }
        func ms(_ t: TimeInterval?) -> Any { t.map { Int(($0 * 1000).rounded()) } ?? NSNull() }
        let ok = killed.found && quit.found && killed.gone != nil && quit.gone != nil
        let line: [String: Any] = ["check": "covers vanish with their process", "ok": ok,
                                   "killed": ["windowFound": killed.found, "goneAfterMs": ms(killed.gone)],
                                   "quit": ["windowFound": quit.found, "goneAfterMs": ms(quit.gone)]]
        print(String(data: try! JSONSerialization.data(withJSONObject: line, options: [.sortedKeys]), encoding: .utf8)!)
        exit(ok ? 0 : 1)
    }
}
