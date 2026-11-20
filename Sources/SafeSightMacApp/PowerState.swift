// SPDX-License-Identifier: Apache-2.0
// What macOS says about power: on battery or not, Low Power Mode, and how hot the Mac is. Heard by notification only
// (no polling); the watcher's energy mode follows it (SafeSightMacWatcher/Energy.swift). Reads local system state only.
// The Testing edition links no IOKit (tools/check-testing-edition.sh): it follows Low Power Mode and heat only.
import Foundation
#if !SAFESIGHTMAC_TESTING
import IOKit.ps
#endif
import SafeSightMacWatcher

@MainActor
final class PowerState {
    private let changed: (EnergyMode) -> Void
    private var observers: [NSObjectProtocol] = []
    private var source: CFRunLoopSource?
    private(set) var mode = EnergyMode.full

    /// `changed` is called on the main thread with the mode now, and again whenever it changes.
    init(changed: @escaping (EnergyMode) -> Void) { self.changed = changed }

    static var onBattery: Bool {
        #if SAFESIGHTMAC_TESTING
        return false
        #else
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(blob)?.takeUnretainedValue() else { return false }
        return (type as String) == kIOPMBatteryPowerKey
        #endif
    }

    static func read() -> EnergyMode {
        let p = ProcessInfo.processInfo
        return EnergyMode.from(onBattery: onBattery, lowPowerMode: p.isLowPowerModeEnabled, thermal: p.thermalState)
    }

    func start() {
        guard observers.isEmpty else { return }
        let nc = NotificationCenter.default
        for name in [Notification.Name.NSProcessInfoPowerStateDidChange, ProcessInfo.thermalStateDidChangeNotification] {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.update() } })
        }
        #if !SAFESIGHTMAC_TESTING
        let me = Unmanaged.passUnretained(self).toOpaque()
        if let s = IOPSNotificationCreateRunLoopSource({ ctx in
            guard let ctx else { return }
            let me = Unmanaged<PowerState>.fromOpaque(ctx).takeUnretainedValue()
            MainActor.assumeIsolated { me.update() }
        }, me)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), s, .defaultMode)
            source = s
        }
        #endif
        mode = Self.read()
        changed(mode)
    }

    func stop() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        if let s = source { CFRunLoopRemoveSource(CFRunLoopGetMain(), s, .defaultMode); source = nil }
    }

    private func update() {
        let m = Self.read()
        guard m != mode else { return }
        mode = m
        changed(m)
    }
}
