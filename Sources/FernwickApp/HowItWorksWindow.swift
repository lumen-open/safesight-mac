// SPDX-License-Identifier: Apache-2.0
// The "How it works" screen: plain words and the honest promise. It sits above the covers, like every
// window of the app (SD-229), and draws no picture.
import AppKit
import FernwickCore
import FernwickCover

@MainActor
final class HowItWorksWindow {
    private let window: NSWindow

    init() {
        window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 520, height: 560), styleMask: [.titled, .closable],
                          backing: .buffered, defer: false)
        window.title = "How Fernwick Open works"
        window.isReleasedWhenClosed = false
        window.level = CoverLevels.appAbove
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        for p in AppText.howItWorksBody { stack.addArrangedSubview(Self.paragraph(p)) }
        let heading = Self.paragraph("The honest promise")
        heading.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        stack.addArrangedSubview(heading)
        stack.addArrangedSubview(Self.paragraph(AppText.honestPromise))
        let scroll = NSScrollView(frame: window.contentView!.bounds)
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true
        stack.frame = CGRect(x: 0, y: 0, width: 500, height: stack.fittingSize.height)
        scroll.documentView = stack
        window.contentView?.addSubview(scroll)
    }

    static func paragraph(_ s: String) -> NSTextField {
        let f = NSTextField(wrappingLabelWithString: s)
        f.preferredMaxLayoutWidth = 460
        f.isSelectable = true
        return f
    }

    func show() {
        window.center()
        window.orderFrontRegardless()
    }
}
