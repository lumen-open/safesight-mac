// SPDX-License-Identifier: Apache-2.0
// The window-list snapshot (section 5.5): window number, owner process, layer and bounds, in
// front-to-back order. Window titles are never read.
import CoreGraphics
import FernwickWatcher
import Foundation

public enum WindowList {
    public static func snapshot() -> WindowSnapshot {
        let now = ProcessInfo.processInfo.systemUptime
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else {
            return WindowSnapshot(windows: [], time: now)
        }
        let windows: [WindowInfo] = list.compactMap { d in
            guard let n = d[kCGWindowNumber as String] as? UInt32 ?? (d[kCGWindowNumber as String] as? Int).map(UInt32.init),
                  let pid = d[kCGWindowOwnerPID as String] as? Int32 ?? (d[kCGWindowOwnerPID as String] as? Int).map(Int32.init),
                  let b = d[kCGWindowBounds as String], let bounds = CGRect(dictionaryRepresentation: b as! CFDictionary)
            else { return nil }
            let layer = d[kCGWindowLayer as String] as? Int ?? 0
            return WindowInfo(number: n, ownerPID: pid, layer: layer, bounds: bounds)
        }
        return WindowSnapshot(windows: windows, time: now)
    }
}
