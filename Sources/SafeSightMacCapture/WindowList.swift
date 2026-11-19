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
        let windows: [WindowInfo] = list.compactMap { d in
            guard let n = d[kCGWindowNumber as String] as? UInt32 ?? (d[kCGWindowNumber as String] as? Int).flatMap({ UInt32(exactly: $0) }),
                  let pid = d[kCGWindowOwnerPID as String] as? Int32 ?? (d[kCGWindowOwnerPID as String] as? Int).flatMap({ Int32(exactly: $0) }),
                  let b = d[kCGWindowBounds as String] as? NSDictionary, let bounds = CGRect(dictionaryRepresentation: b as CFDictionary)
            else { return nil }
            let layer = d[kCGWindowLayer as String] as? Int ?? 0
            let alpha = (d[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1
            return WindowInfo(number: n, ownerPID: pid, layer: layer, bounds: bounds, alpha: alpha)
        }
        return WindowSnapshot(windows: windows, time: now)
    }
}
