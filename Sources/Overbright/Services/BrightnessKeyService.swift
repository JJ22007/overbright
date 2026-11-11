import AppKit
import ApplicationServices

@MainActor
final class BrightnessKeyService {
    typealias Handler = @MainActor (
        BrightnessKeyDirection,
        _ fineGrained: Bool
    ) -> Bool

    private static let systemDefinedEventMask = CGEventMask(1 << 14)

    private let handler: Handler
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
            eventsOfInterest: Self.systemDefinedEventMask,
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
}
