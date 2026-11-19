// SPDX-License-Identifier: Apache-2.0
// The "How it works" screen: plain words and the honest promise (HowItWorksView). It sits above the covers,
// like every window of the app (SD-229), and draws no picture. The title bar and scroller are the system's own;
// the ground and the words take the theme's colours and follow the appearance. In the Testing edition it opens
// with the edition's line.
import AppKit
import SafeSightMacCore
import SafeSightMacCover

@MainActor
final class HowItWorksWindow {
    private let window: NSWindow

    /// `shortcut`: whether ⌃⌥⌘Q is this copy's (Testing edition only).
    init(edition: Edition = BuildInfo.edition, shortcut: Bool = true) {
        let page = HowItWorksView.make(edition: edition, shortcut: shortcut)
        // As tall as the page, or as the screen allows; the rest scrolls.
        let room = (NSScreen.main?.visibleFrame.height ?? 800) - 80
        let size = CGSize(width: page.frame.width, height: min(page.frame.height, max(room, 480)))
        window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.titled, .closable],
                          backing: .buffered, defer: false)
        window.title = AppText.howItWorksWindowTitle(edition)
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.level = CoverLevels.appAbove
        window.titlebarAppearsTransparent = true
        window.backgroundColor = CoverTheme.dynamic(\.background)
        let scroll = NSScrollView(frame: CGRect(origin: .zero, size: size))
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.documentView = page
        window.contentView = scroll
    }

    func show() {
        window.center()
        window.orderFrontRegardless()
    }
}
