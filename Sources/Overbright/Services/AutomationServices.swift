import AppKit
import Carbon.HIToolbox
import IOKit.ps

/// Reports battery changes (charge and power source) as `LowBattery.Reading`.
/// Macs without a battery never report.
@MainActor
final class BatteryMonitor {
    private var source: CFRunLoopSource?
    var onChange: ((LowBattery.Reading) -> Void)?

    func start() {
        guard source == nil else { return }
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let created = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let monitor = Unmanaged<BatteryMonitor>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { monitor.report() }
        }, context)?.takeRetainedValue() else { return }
        source = created
        CFRunLoopAddSource(CFRunLoopGetMain(), created, .defaultMode)
        report()
    }

    func stop() {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode) }
        source = nil
    }

    static func reading() -> LowBattery.Reading? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for item in list {
            guard let description = IOPSGetPowerSourceDescription(info, item)?.takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let current = description[kIOPSCurrentCapacityKey] as? Double,
                  let maximum = description[kIOPSMaxCapacityKey] as? Double, maximum > 0 else { continue }
            let state = description[kIOPSPowerSourceStateKey] as? String
            return LowBattery.Reading(percent: current / maximum * 100, onBattery: state == kIOPSBatteryPowerValue)
        }
        return nil
    }

    private func report() {
        if let reading = Self.reading() { onChange?(reading) }
    }
}

/// One global shortcut, through Carbon hot keys (no Accessibility needed).
@MainActor
final class ShortcutService {
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var registered: Shortcut?
    var onPress: (() -> Void)?

    /// Registers `shortcut`, or removes the current one for nil. Returns false
    /// if macOS refused it (another app may already use the combination).
    @discardableResult
    func register(_ shortcut: Shortcut?) -> Bool {
        guard shortcut != registered else { return true }
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = nil
        registered = nil
        guard let shortcut else { return true }
        installHandler()
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: OSType(0x4F42_5254), id: 1) // "OBRT"
        let status = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, id,
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else { return false }
        hotKey = ref
        registered = shortcut
        return true
    }

    private func installHandler() {
        guard handler == nil else { return }
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, _, context in
            guard let context else { return noErr }
            let service = Unmanaged<ShortcutService>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { service.onPress?() }
            return noErr
        }, 1, &type, context, &handler)
    }
}
