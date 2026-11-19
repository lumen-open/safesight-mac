// SPDX-License-Identifier: Apache-2.0
// The Testing report window (Testing edition only): the report as selectable text, refreshed every two seconds, and a
// field for the helper's note. The helper copies it by hand; the app puts nothing on the clipboard and writes nothing.
#if SAFESIGHTMAC_TESTING
import AppKit
import CryptoKit
import SafeSightMacCore
import SafeSightMacCover
import SafeSightMacTestingEdition

@MainActor
final class TestingReportWindow: NSObject, NSTextFieldDelegate {
    private let window: NSWindow
    private let note = NSTextField()
    private let text = NSTextView()
    private var timer: Timer?
    private let make: (String) -> String

    /// `make` turns the note into the report text.
    init(make: @escaping (String) -> String) {
        self.make = make
        window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 600, height: 560), styleMask: [.titled, .closable, .resizable],
                          backing: .buffered, defer: false)
        super.init()
        window.title = AppText.testingReportTitle
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.level = CoverLevels.appAbove
        let v = NSView(frame: CGRect(x: 0, y: 0, width: 600, height: 560))
        let intro = NSTextField(wrappingLabelWithString: AppText.testingReportIntro)
        intro.frame = CGRect(x: 20, y: 480, width: 560, height: 64)
        let label = NSTextField(labelWithString: AppText.testingReportNoteLabel)
        label.frame = CGRect(x: 20, y: 450, width: 560, height: 20)
        note.frame = CGRect(x: 20, y: 384, width: 560, height: 60)
        note.cell?.wraps = true
        note.cell?.isScrollable = false
        note.delegate = self
        let scroll = NSScrollView(frame: CGRect(x: 20, y: 20, width: 560, height: 352))
        scroll.hasVerticalScroller = true
        scroll.autoresizingMask = [.width, .height]
        text.frame = CGRect(origin: .zero, size: scroll.contentSize)
        text.autoresizingMask = [.width]
        text.isEditable = false
        text.isSelectable = true
        text.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        scroll.documentView = text
        for s in [intro, label, note, scroll] as [NSView] { v.addSubview(s) }
        intro.autoresizingMask = [.width, .minYMargin]; label.autoresizingMask = [.width, .minYMargin]
        note.autoresizingMask = [.width, .minYMargin]
        window.contentView = v
    }

    func show() {
        refresh()
        timer?.invalidate()
        let t = Timer(timeInterval: 2, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.refresh() } }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        window.center()
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    func controlTextDidChange(_ obj: Notification) { refresh() }

    private func refresh() {
        guard window.isVisible || timer == nil else { timer?.invalidate(); timer = nil; return }
        text.string = make(note.stringValue)
    }

    /// The Mac and this build, read once.
    static func facts(shortcut: Bool) -> TestingFacts {
        let displays: [TestingFacts.Display] = NSScreen.screens.map { s in
            let id = (s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
            return .init(width: Int(s.frame.width), height: Int(s.frame.height), scale: Double(s.backingScaleFactor),
                         builtIn: CGDisplayIsBuiltin(id) != 0, mirrored: CGDisplayIsInMirrorSet(id) != 0)
        }
        let exe = Bundle.main.executablePath.flatMap { FileManager.default.contents(atPath: $0) }
        let exeSHA = exe.map { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() } ?? "unknown"
        let list = Bundle.main.resourceURL.flatMap { try? String(contentsOf: $0.appendingPathComponent("models/compiled.sha256"), encoding: .utf8) }
        let stamp = list?.split(separator: "\n").first.map { String($0.dropFirst("# from ".count)) } ?? "not compiled"
        return TestingFacts(macModel: TestingFacts.macModel(), macOS: ProcessInfo.processInfo.operatingSystemVersionString,
                            edition: BuildInfo.edition.rawValue, version: BuildInfo.version, executableSHA: exeSHA,
                            modelsStamp: stamp, displays: displays, shortcutRegistered: shortcut)
    }
}
#endif
