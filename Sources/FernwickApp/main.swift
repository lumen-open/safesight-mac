// SPDX-License-Identifier: Apache-2.0
// Fernwick Open, step 1: the cover-only app. A menu-bar app with no Dock icon. It adds no login item
// and installs nothing; it runs only when the owner starts it.
import AppKit

let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
