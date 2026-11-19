// SPDX-License-Identifier: Apache-2.0
// Which key types a letter in the keyboard layout in use. A hot key is registered by key code, a place on the
// keyboard, but people press the key by what is printed on it: Q is not in the same place on QWERTY, AZERTY and
// Dvorak. The layout is read with the Text Input Sources calls, which need no permission and must be made on the
// main thread (macOS stops a process that makes them elsewhere).
import Carbon.HIToolbox
import Foundation

public enum KeyLayout {
    /// The ⌘ key's bit in the modifier state UCKeyTranslate takes. Some layouts ("Dvorak - QWERTY ⌘") change
    /// while ⌘ is held, so the letter is looked up as it types with ⌘ down.
    public static let commandState = UInt32(cmdKey >> 8) & 0xFF

    /// The current keyboard layout's identifier, such as "com.apple.keylayout.French".
    @MainActor public static func currentLayoutID() -> String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return nil }
        return Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
    }

    /// The current keyboard layout's key table, or nil when there is none to read.
    @MainActor public static func currentLayoutData() -> Data? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        return Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
    }

    /// The key code that types `character` in the current layout with ⌘ held, or nil.
    @MainActor public static func keyCode(for character: Character) -> UInt32? {
        currentLayoutData().flatMap { keyCode(for: character, layout: $0) }
    }

    /// The first key code (0 to 127) that types `character`, case aside, in `layout` with `state` held.
    public static func keyCode(for character: Character, layout: Data, state: UInt32 = commandState) -> UInt32? {
        let want = String(character).lowercased()
        for code in UInt32(0)..<128 where text(of: code, layout: layout, state: state)?.lowercased() == want {
            return code
        }
        return nil
    }

    /// What `code` types in `layout` with `state` held, or nil.
    public static func text(of code: UInt32, layout: Data, state: UInt32 = commandState) -> String? {
        layout.withUnsafeBytes { raw -> String? in
            guard let table = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return nil }
            var dead: UInt32 = 0
            var length = 0
            var chars = [UniChar](repeating: 0, count: 4)
            let s = UCKeyTranslate(table, UInt16(code), UInt16(kUCKeyActionDown), state, UInt32(LMGetKbdType()),
                                   OptionBits(kUCKeyTranslateNoDeadKeysMask), &dead, chars.count, &length, &chars)
            guard s == noErr, length > 0 else { return nil }
            return String(utf16CodeUnits: chars, count: length)
        }
    }
}
