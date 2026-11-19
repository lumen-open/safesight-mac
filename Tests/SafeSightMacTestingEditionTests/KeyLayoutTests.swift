// SPDX-License-Identifier: Apache-2.0
// The Q of ⌃⌥⌘Q is found by what is printed on the key, in whichever layout is in use. Layouts are read, never
// selected: the person's own input settings are not changed. Main thread, as the input-source calls require.
import Carbon.HIToolbox
import Foundation
import Testing
@testable import SafeSightMacTestingEdition

@MainActor @Suite struct KeyLayoutTests {
    /// An installed layout's key table, read without selecting it.
    func layout(_ id: String) -> Data? {
        let filter = [kTISPropertyInputSourceID as String: id] as CFDictionary
        guard let list = TISCreateInputSourceList(filter, true)?.takeRetainedValue() as? [TISInputSource],
              let source = list.first,
              let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        return Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
    }

    @Test func theCurrentLayoutTypesQOnTheKeyFound() throws {
        let data = try #require(KeyLayout.currentLayoutData(), "every Mac has a keyboard layout")
        let code = try #require(KeyLayout.keyCode(for: "q", layout: data))
        #expect(KeyLayout.text(of: code, layout: data)?.lowercased() == "q")
        #expect(KeyLayout.keyCode(for: "q") == code)
    }

    @Test(arguments: [
        // Layout, and where its Q is on a US keyboard.
        ("com.apple.keylayout.US", UInt32(kVK_ANSI_Q)),
        ("com.apple.keylayout.French", UInt32(kVK_ANSI_A)),        // AZERTY: Q where QWERTY has A
        ("com.apple.keylayout.Belgian", UInt32(kVK_ANSI_A)),
        ("com.apple.keylayout.Dvorak", UInt32(kVK_ANSI_X)),        // Dvorak: Q where QWERTY has X
        ("com.apple.keylayout.DVORAK-QWERTYCMD", UInt32(kVK_ANSI_Q)), // QWERTY while ⌘ is held
        ("com.apple.keylayout.German", UInt32(kVK_ANSI_Q)),
    ])
    func qIsFoundWhereEachLayoutPutsIt(_ id: String, _ expected: UInt32) throws {
        guard let data = layout(id) else { return }   // not installed on this Mac: nothing to check
        #expect(KeyLayout.keyCode(for: "q", layout: data) == expected, "\(id)")
        #expect(KeyLayout.keyCode(for: "Q", layout: data) == expected, "case does not matter")
    }

    @Test func theLayoutsAboveShipWithMacOSSoNoneIsSkipped() {
        // Apple's keyboard layouts are part of macOS, selected or not: the AZERTY and Dvorak checks always run.
        for id in ["com.apple.keylayout.US", "com.apple.keylayout.French", "com.apple.keylayout.Dvorak"] {
            #expect(layout(id) != nil, "\(id)")
        }
    }

    @Test func aCharacterNoKeyTypesIsNotFound() throws {
        let data = try #require(KeyLayout.currentLayoutData())
        #expect(KeyLayout.keyCode(for: "\u{E000}", layout: data) == nil)
    }
}
