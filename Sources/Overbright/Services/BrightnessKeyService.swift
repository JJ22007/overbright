import AppKit
import ApplicationServices
import Carbon.HIToolbox
import OSLog

@MainActor
final class BrightnessKeyService {
    typealias Handler = @MainActor (
        BrightnessKeyDirection,
        _ fineGrained: Bool
    ) -> Bool

    /// Brightness media keys arrive as system-defined events. Control+F1/F2 can
    /// also arrive as plain F1/F2 key codes, depending on the keyboard and the
    /// "Use F1, F2, etc. keys as standard function keys" setting, so key-down
    /// and key-up are watched too. Only Control+F1/F2 is ever acted on; every
    /// other key passes through untouched.
    private static let eventMask = CGEventMask(1 << 14) |
        CGEventMask(1 << CGEventType.keyDown.rawValue) |
        CGEventMask(1 << CGEventType.keyUp.rawValue)
    private let logger = Logger(subsystem: AppInfo.bundleID, category: "Keys")

    private let handler: Handler
    /// Control+F1/F2. Return false to let macOS have the key.
    var externalHandler: Handler?
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var keySequence = BrightnessKeySequence()

    /// Mirrors `brightnessKeys` in the config. While false, `start()` does nothing.
    var isEnabled = true {
        didSet {
            if !isEnabled { stop() }
        }
    }

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    var isTrusted: Bool {
        AXIsProcessTrusted()
    }

    var isRunning: Bool {
        guard let eventTap else { return false }
        return CGEvent.tapIsEnabled(tap: eventTap)
    }

    @discardableResult
    static func requestAccessibilityPermission() -> Bool {
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions(
            [promptKey: true] as CFDictionary
        )
    }

    @discardableResult
    func start() -> Bool {
        guard isEnabled else { return false }
        guard isTrusted else {
            stop()
            return false
        }

        if let eventTap {
            if CFMachPortIsValid(eventTap) {
                CGEvent.tapEnable(tap: eventTap, enable: true)
                if CGEvent.tapIsEnabled(tap: eventTap) {
                    return true
                }
            }
            stop()
        }

        let callback: CGEventTapCallBack = { _, eventType, event, context in
            guard let context else {
                return Unmanaged.passUnretained(event)
            }
            let service = Unmanaged<BrightnessKeyService>
                .fromOpaque(context)
                .takeUnretainedValue()
            return MainActor.assumeIsolated {
                service.process(eventType: eventType, event: event)
            }
        }

        guard let newTap = CGEvent.tapCreate(
            // Intercept brightness media keys before macOS' OSD sees key-down.
            // At the session tap the system can show its HUD first, then miss the
            // swallowed key-up and leave that HUD pinned on screen indefinitely.
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: Self.eventMask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            return false
        }

        guard let source = CFMachPortCreateRunLoopSource(
            kCFAllocatorDefault,
            newTap,
            0
        ) else {
            CFMachPortInvalidate(newTap)
            return false
        }

        eventTap = newTap
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: newTap, enable: true)
        let running = CGEvent.tapIsEnabled(tap: newTap)
        if !running {
            stop()
        }
        return running
    }

    func stop() {
        keySequence = BrightnessKeySequence()
        if let runLoopSource {
            CFRunLoopRemoveSource(
                CFRunLoopGetMain(),
                runLoopSource,
                .commonModes
            )
        }
        if let eventTap {
            CFMachPortInvalidate(eventTap)
        }
        runLoopSource = nil
        eventTap = nil
    }

    private func process(
        eventType: CGEventType,
        event: CGEvent
    ) -> Unmanaged<CGEvent>? {
        let passThrough = Unmanaged.passUnretained(event)

        if eventType == .tapDisabledByTimeout ||
            eventType == .tapDisabledByUserInput {
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return passThrough
        }

        if eventType == .keyDown || eventType == .keyUp {
            return processFunctionKey(eventType: eventType, event: event)
        }

        guard let systemEvent = NSEvent(cgEvent: event),
              let mediaKey = BrightnessMediaKeyEvent.decode(
                subtype: Int(systemEvent.subtype.rawValue),
                data1: systemEvent.data1
              ) else {
            return passThrough
        }

        if mediaKey.phase != .keyDown {
            if mediaKey.phase == .keyUp,
               keySequence.consumeRelease(code: mediaKey.keyCode) {
                return nil
            }
            return passThrough
        }

        let modifiers = systemEvent.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
        let optionHeld = modifiers.contains(.option)
        let shiftHeld = modifiers.contains(.shift)
        if modifiers.contains(.control) {
            let handled = externalHandler?(mediaKey.direction, optionHeld && shiftHeld) ?? false
            logger.info("Control+brightness key \(mediaKey.direction == .increase ? "up" : "down", privacy: .public) handled=\(handled)")
            keySequence.recordDown(code: mediaKey.keyCode, consumed: handled)
            return handled ? nil : passThrough
        }
        if optionHeld && !shiftHeld {
            keySequence.recordDown(code: mediaKey.keyCode, consumed: false)
            return passThrough
        }

        let handled = handler(mediaKey.direction, optionHeld && shiftHeld)
        keySequence.recordDown(code: mediaKey.keyCode, consumed: handled)
        if handled {
            return nil
        }

        return passThrough
    }

    /// Control+F1/F2 delivered as function-key codes rather than media keys.
    private func processFunctionKey(eventType: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let passThrough = Unmanaged.passUnretained(event)
        let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
        let direction: BrightnessKeyDirection
        switch keyCode {
        case kVK_F1: direction = .decrease
        case kVK_F2: direction = .increase
        default: return passThrough
        }
        // Distinct from the media key codes (2 and 3) so the two paths never
        // swallow each other's key-up.
        let sequenceCode = 1000 + keyCode

        if eventType == .keyUp {
            return keySequence.consumeRelease(code: sequenceCode) ? nil : passThrough
        }
        let flags = event.flags
        guard flags.contains(.maskControl), !flags.contains(.maskCommand) else {
            return passThrough
        }
        let fine = flags.contains(.maskAlternate) && flags.contains(.maskShift)
        let handled = externalHandler?(direction, fine) ?? false
        logger.info("Control+F\(keyCode == kVK_F1 ? 1 : 2, privacy: .public) key code handled=\(handled)")
        keySequence.recordDown(code: sequenceCode, consumed: handled)
        return handled ? nil : passThrough
    }
}
