// SPDX-License-Identifier: Apache-2.0
// ⌃⌥⌘Q, the Testing edition's emergency quit: the shortcut as written, the key found by what is printed on it in
// any layout, and the whole path from a hot-key event to the quit action. No key is pressed and nothing is shown:
// the hot-key event is made in the test and sent to the app's own event target. The registration test uses an
// unlikely combination (⌃⌥⇧⌘F19), held for a moment only.
import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Testing
@testable import SafeSightMacCore
@testable import SafeSightMacTestingEdition

@MainActor @Suite(.serialized) struct EmergencyQuitTests {
    init() { _ = NSApplication.shared }

    @Test func theShortcutIsControlOptionCommandQ() {
        let q = EmergencyQuit.Shortcut.quit
        #expect(q.character == "q")
        #expect(q.modifiers == UInt32(controlKey | optionKey | cmdKey), "no Shift: three keys and Q")
        #expect(q.fallbackKeyCode == UInt32(kVK_ANSI_Q))
        #expect(q.display == "⌃⌥⌘Q")
        #expect(AppText.testingKeys == [q.display], "the line names the shortcut that is registered")
        #expect(AppText.testingLine.contains(q.display))
    }

    /// Sends a hot-key event with `id` to the app's event target, as macOS does when a registered shortcut is pressed.
    func press(_ id: EventHotKeyID) -> OSStatus {
        var event: EventRef?
        guard CreateEvent(nil, OSType(kEventClassKeyboard), UInt32(kEventHotKeyPressed), 0, EventAttributes(kEventAttributeNone), &event) == noErr,
              let event else { return OSStatus(eventInternalErr) }
        defer { ReleaseEvent(event) }
        var hk = id
        let set = SetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                    MemoryLayout<EventHotKeyID>.size, &hk)
        guard set == noErr else { return set }
        return SendEventToEventTarget(event, GetApplicationEventTarget())
    }

    @Test func pressingTheShortcutRunsTheQuitAndNothingElseDoes() throws {
        var quits = 0
        // A character no layout types, so the fallback key, F19, is used.
        let odd = EmergencyQuit.Shortcut(character: "\u{E000}", modifiers: UInt32(controlKey | optionKey | shiftKey | cmdKey),
                                         fallbackKeyCode: UInt32(kVK_F19))
        let e = EmergencyQuit(shortcut: odd, id: 77) { quits += 1 }
        let state = e.register()
        defer { e.unregister() }
        #expect(state == .registered(keyCode: UInt32(kVK_F19)))
        #expect(e.state.works)
        // Evidence for the docs: a process with no Accessibility permission (as on CI) still registers it. Processes
        // started from a terminal that has the permission inherit it, so a local run shows nothing either way.
        print("EmergencyQuit: registered while AXIsProcessTrusted() == \(AXIsProcessTrusted())")

        #expect(press(e.hotKeyID) == noErr)
        #expect(quits == 1, "the shortcut's own event runs the quit")
        #expect(press(EventHotKeyID(signature: e.hotKeyID.signature, id: 78)) == OSStatus(eventNotHandledErr))
        #expect(press(EventHotKeyID(signature: 0x41424344, id: 77)) == OSStatus(eventNotHandledErr))
        #expect(quits == 1, "another app's or another shortcut's event does nothing")

        e.unregister()
        #expect(e.state == .notRegistered)
    }

    @Test func aShortcutAlreadyTakenIsReportedNotClaimed() throws {
        let odd = EmergencyQuit.Shortcut(character: "\u{E000}", modifiers: UInt32(controlKey | optionKey | shiftKey | cmdKey),
                                         fallbackKeyCode: UInt32(kVK_F18))
        let first = EmergencyQuit(shortcut: odd, id: 90) {}
        let second = EmergencyQuit(shortcut: odd, id: 91) {}
        defer { first.unregister(); second.unregister() }
        guard first.register().works else { Issue.record("could not register the test shortcut: \(first.state)"); return }
        // Registered exclusively: a second registration of the same keys is refused, and says so.
        let s = second.register()
        #expect(!s.works)
        #expect(s == .failed(OSStatus(eventHotKeyExistsErr)))
        // What the app then shows never names the shortcut.
        #expect(!AppText.testingLine(shortcut: false).contains("⌃⌥⌘Q"))
        #expect(AppText.testingPieces(shortcut: false).allSatisfy { !$0.isKey })
    }

    /// A copy that asked while something else held the shortcut (an older copy still ending after an update) gets it
    /// once that lets go, by asking again; the report says why it did not have it meanwhile.
    @Test func aShortcutTakenAtLaunchIsHadOnceItIsFree() {
        let odd = EmergencyQuit.Shortcut(character: "\u{E000}", modifiers: UInt32(controlKey | optionKey | shiftKey | cmdKey),
                                         fallbackKeyCode: UInt32(kVK_F17))
        let first = EmergencyQuit(shortcut: odd, id: 92) {}
        let second = EmergencyQuit(shortcut: odd, id: 93) {}
        defer { first.unregister(); second.unregister() }
        guard first.register().works else { Issue.record("could not register the test shortcut: \(first.state)"); return }
        #expect(!second.register().works)
        #expect(ShortcutStatus.from(second.state, otherCopyRunning: false) == .takenByAnotherApp)
        #expect(ShortcutStatus.from(second.state, otherCopyRunning: true) == .takenByAnotherCopy)
        #expect(!second.retryIfNeeded(), "still held")
        first.unregister()
        #expect(second.retryIfNeeded(), "free now: had on the next try")
        #expect(second.state.works)
        #expect(!second.retryIfNeeded(), "nothing to do once it works")
        #expect(ShortcutStatus.from(second.state, otherCopyRunning: false) == .registered)
    }

    @Test func theReportSaysWhyTheShortcutIsNotThisCopys() {
        #expect(ShortcutStatus.from(.notRegistered, otherCopyRunning: false) == .notYet)
        #expect(ShortcutStatus.from(.failed(-50), otherCopyRunning: true) == .failed(-50), "another error is not blamed on anyone")
        #expect(ShortcutStatus.registered.reportText == "registered")
        #expect(ShortcutStatus.takenByAnotherCopy.reportText.contains("another copy"))
        #expect(ShortcutStatus.takenByAnotherApp.reportText.contains("another app"))
        #expect(ShortcutStatus.failed(-50).reportText.contains("-50"))
        #expect(!ShortcutStatus.notYet.reportText.contains("another"))
    }

    @Test func registeringAgainForANewLayoutReplacesTheOldRegistration() {
        let odd = EmergencyQuit.Shortcut(character: "\u{E000}", modifiers: UInt32(controlKey | optionKey | shiftKey | cmdKey),
                                         fallbackKeyCode: UInt32(kVK_F17))
        let e = EmergencyQuit(shortcut: odd, id: 95) {}
        defer { e.unregister() }
        #expect(e.register().works)
        #expect(e.register().works, "the old registration is removed first, so the new one is not refused as taken")
        #expect(e.followLayout() == false, "the layout has not changed")
    }
}
