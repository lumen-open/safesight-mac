// SPDX-License-Identifier: Apache-2.0
// The app's own menu (the menu bar icon's) under covers. A menu opens at the pop-up menu level, below the cover canvas,
// so under a whole-display cover it would open hidden. While it is open its windows are lifted to the app's own level,
// above the canvas, as the app's other windows are. And each opening builds its click handlers afresh: the last
// opening's are let go, never piled up.
import AppKit

@MainActor
public enum OwnMenus {
    /// Lifts every open menu window of this app above the cover canvas. Returns how many were lifted.
    @discardableResult
    public static func lift(_ windows: [NSWindow] = NSApp.windows, isMenu: @MainActor (NSWindow) -> Bool = { OwnMenus.isMenuWindow($0) }) -> Int {
        var n = 0
        for w in windows where isMenu(w) && w.level.rawValue < CoverLevels.appAbove.rawValue {
            w.level = CoverLevels.appAbove
            n += 1
        }
        return n
    }

    /// AppKit's own menu windows (their class names say so). Cover panels never count.
    public nonisolated static func isMenuWindow(_ w: NSWindow) -> Bool {
        guard !(w is CoverPanel) else { return false }
        return NSStringFromClass(type(of: w)).contains("Menu")
    }
}

/// Click handlers for menu items built in code, kept alive while their menu shows.
@MainActor
public final class MenuActions {
    private final class Target: NSObject {
        let action: () -> Void
        init(_ a: @escaping () -> Void) { action = a }
        @objc func fire() { action() }
    }
    private var targets: [Target] = []
    public init() {}

    /// How many handlers are kept now.
    public var count: Int { targets.count }

    /// Starts a new build of the menu: the last build's handlers are let go.
    public func begin() { targets.removeAll() }

    /// A menu item that runs `action` when chosen.
    public func item(_ title: String, _ action: @escaping () -> Void) -> NSMenuItem {
        let t = Target(action)
        targets.append(t)
        let i = NSMenuItem(title: title, action: #selector(Target.fire), keyEquivalent: "")
        i.target = t
        return i
    }
}
