// SPDX-License-Identifier: Apache-2.0
// The Testing edition's emergency shortcut: ⌃⌥⌘Q quits it from anywhere, whichever app is in front, even when a
// cover hides the whole screen.
//
// It is a Carbon hot key (RegisterEventHotKey). macOS's window server matches the key press and tells this app
// that its own shortcut was pressed; the app never reads the keyboard, so it needs no Accessibility or Input
// Monitoring permission, and the call is allowed inside the App Sandbox. It is registered exclusively: if another
// app already holds it exclusively, macOS refuses (checked with two processes on macOS 26), and the app then names
// no shortcut anywhere. An app that registered it without exclusivity gets it too, and a shortcut set in System
// Settings or a key remapper can take it first; neither can be seen from here, so the menu always offers Quit.
//
// The key is found by what is printed on it, in the keyboard layout in use (KeyLayout): on an AZERTY keyboard
// the Q key sits where QWERTY has A, and a fixed key code would miss it.
import Carbon.HIToolbox
import Foundation

@MainActor
public final class EmergencyQuit {
    /// A shortcut: the letter printed on the key, and Carbon modifier flags.
    public struct Shortcut: Equatable, Sendable {
        public var character: Character
        public var modifiers: UInt32
        /// The key code to use when the layout cannot be read: where the letter sits on a US keyboard.
        public var fallbackKeyCode: UInt32

        public init(character: Character, modifiers: UInt32, fallbackKeyCode: UInt32) {
            self.character = character; self.modifiers = modifiers; self.fallbackKeyCode = fallbackKeyCode
        }

        /// ⌃⌥⌘Q.
        public static let quit = Shortcut(character: "q", modifiers: UInt32(controlKey | optionKey | cmdKey),
                                          fallbackKeyCode: UInt32(kVK_ANSI_Q))

        /// As the Mac writes it: ⌃ ⌥ ⇧ ⌘, then the key.
        public var display: String {
            var s = ""
            if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
            if modifiers & UInt32(optionKey) != 0 { s += "⌥" }
            if modifiers & UInt32(shiftKey) != 0 { s += "⇧" }
            if modifiers & UInt32(cmdKey) != 0 { s += "⌘" }
            return s + String(character).uppercased()
        }
    }

    public enum State: Equatable, Sendable {
        case notRegistered
        case registered(keyCode: UInt32)
        /// macOS refused it; `eventHotKeyExistsErr` (-9878) means another app holds it.
        case failed(OSStatus)

        public var works: Bool { if case .registered = self { return true } else { return false } }
    }

    public let shortcut: Shortcut
    public private(set) var state: State = .notRegistered
    /// The layout the shortcut was registered for, to notice a change.
    public private(set) var layoutID: String?
    let hotKeyID: EventHotKeyID
    private let action: () -> Void
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?

    /// `action` runs on the main thread when the shortcut is pressed. `id` tells several shortcuts apart.
    public init(shortcut: Shortcut = .quit, id: UInt32 = 1, action: @escaping () -> Void) {
        self.shortcut = shortcut
        self.hotKeyID = EventHotKeyID(signature: Self.signature, id: id)
        self.action = action
    }

    deinit {
        if let k = hotKey { UnregisterEventHotKey(k) }
        if let h = handler { RemoveEventHandler(h) }
    }

    /// "SSMT": SafeSight Mac Testing.
    static let signature: OSType = "SSMT".utf8.reduce(0) { $0 << 8 | OSType($1) }

    /// Registers the shortcut for the current keyboard layout, replacing an earlier registration. Main thread.
    @discardableResult
    public func register() -> State {
        unregister()
        if handler == nil {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            var ref: EventHandlerRef?
            let s = InstallEventHandler(GetApplicationEventTarget(), emergencyQuitHandler, 1, &spec,
                                        Unmanaged.passUnretained(self).toOpaque(), &ref)
            guard s == noErr else { state = .failed(s); return state }
            handler = ref
        }
        layoutID = KeyLayout.currentLayoutID()
        let code = KeyLayout.keyCode(for: shortcut.character) ?? shortcut.fallbackKeyCode
        var ref: EventHotKeyRef?
        let s = RegisterEventHotKey(code, shortcut.modifiers, hotKeyID, GetApplicationEventTarget(),
                                    OptionBits(kEventHotKeyExclusive), &ref)
        if s == noErr, let ref {
            hotKey = ref
            state = .registered(keyCode: code)
        } else {
            state = .failed(s)
        }
        return state
    }

    /// Registers again when the shortcut is not this copy's (registration failed, or was refused because something
    /// held it then: an older copy still ending after an update, say). True when that changed whether it works. Cheap:
    /// one call, made every few seconds while it does not work.
    @discardableResult
    public func retryIfNeeded() -> Bool {
        guard !state.works else { return false }
        return register().works
    }

    /// Registers again if the keyboard layout changed since the last registration (the Q key may have moved).
    @discardableResult
    public func followLayout() -> Bool {
        guard KeyLayout.currentLayoutID() != layoutID else { return false }
        register()
        return true
    }

    public func unregister() {
        if let k = hotKey { UnregisterEventHotKey(k) }
        hotKey = nil
        if case .registered = state { state = .notRegistered }
    }

    /// Called by the handler for every hot-key press this app receives; true when it was this shortcut.
    func handle(_ id: EventHotKeyID) -> Bool {
        guard id.signature == hotKeyID.signature, id.id == hotKeyID.id else { return false }
        action()
        return true
    }
}

/// The Carbon handler: a plain function, handed the shortcut's object as its user data.
private func emergencyQuitHandler(_ call: EventHandlerCallRef?, _ event: EventRef?, _ userData: UnsafeMutableRawPointer?) -> OSStatus {
    guard let event, let userData else { return OSStatus(eventNotHandledErr) }
    var id = EventHotKeyID()
    let s = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &id)
    guard s == noErr else { return s }
    // Carbon delivers hot-key events on the main thread.
    let handled = MainActor.assumeIsolated { Unmanaged<EmergencyQuit>.fromOpaque(userData).takeUnretainedValue().handle(id) }
    return handled ? noErr : OSStatus(eventNotHandledErr)
}
