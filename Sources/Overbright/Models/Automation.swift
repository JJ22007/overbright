import Foundation

/// `lowBatteryOff`: end the boost when the battery runs low, so the brightest
/// setting is not what drains the last of it.
enum LowBattery {
    static let range: ClosedRange<Double> = 5...95

    struct Reading: Equatable {
        /// Charge, 0-100.
        var percent: Double
        /// Running on the battery (not on the power adapter).
        var onBattery: Bool
    }

    /// Turn the boost off on the reading that crosses the threshold (or on
    /// unplugging below it, or at the first reading), and only then: if the
    /// user turns the boost back on while the battery stays low, it stays on.
    static func shouldTurnOff(previous: Reading?, current: Reading, threshold: Double, boosted: Bool) -> Bool {
        guard boosted, current.onBattery, current.percent <= threshold else { return false }
        guard let previous else { return true }
        return !previous.onBattery || previous.percent > threshold
    }
}

/// `toggleShortcut`: a global key combination that switches the boost, such
/// as "ctrl+opt+cmd+b". Registered through Carbon's hot keys, so it needs no
/// Accessibility permission.
struct Shortcut: Equatable {
    /// macOS virtual key code.
    var keyCode: UInt32
    /// Carbon modifier flags (cmdKey, shiftKey, optionKey, controlKey).
    var modifiers: UInt32

    static let command: UInt32 = 1 << 8
    static let shift: UInt32 = 1 << 9
    static let option: UInt32 = 1 << 11
    static let control: UInt32 = 1 << 12

    private static let modifierNames: [String: UInt32] = [
        "cmd": command, "command": command, "⌘": command,
        "shift": shift, "⇧": shift,
        "opt": option, "option": option, "alt": option, "⌥": option,
        "ctrl": control, "control": control, "⌃": control
    ]

    private static let keyCodes: [String: UInt32] = {
        var codes: [String: UInt32] = [
            "a": 0x00, "s": 0x01, "d": 0x02, "f": 0x03, "h": 0x04, "g": 0x05, "z": 0x06, "x": 0x07,
            "c": 0x08, "v": 0x09, "b": 0x0B, "q": 0x0C, "w": 0x0D, "e": 0x0E, "r": 0x0F, "y": 0x10,
            "t": 0x11, "1": 0x12, "2": 0x13, "3": 0x14, "4": 0x15, "6": 0x16, "5": 0x17, "9": 0x19,
            "7": 0x1A, "8": 0x1C, "0": 0x1D, "o": 0x1F, "u": 0x20, "i": 0x22, "p": 0x23, "l": 0x25,
            "j": 0x26, "k": 0x28, "n": 0x2D, "m": 0x2E, "space": 0x31
        ]
        let functionKeys: [UInt32] = [0x7A, 0x78, 0x63, 0x76, 0x60, 0x61, 0x62, 0x64, 0x65, 0x6D,
                                      0x67, 0x6F, 0x69, 0x6B, 0x71, 0x6A, 0x40, 0x4F, 0x50, 0x5A]
        for (index, code) in functionKeys.enumerated() { codes["f\(index + 1)"] = code }
        return codes
    }()

    /// Parses "ctrl+opt+cmd+b". Needs exactly one key and at least one of
    /// Command, Control or Option, so it never takes an ordinary key away.
    static func parse(_ text: String) -> Shortcut? {
        let parts = text.lowercased().split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) }
        var modifiers: UInt32 = 0
        var key: UInt32?
        for part in parts where !part.isEmpty {
            if let flag = modifierNames[part] {
                modifiers |= flag
            } else if let code = keyCodes[part], key == nil {
                key = code
            } else {
                return nil
            }
        }
        guard let key, modifiers & (command | control | option) != 0 else { return nil }
        return Shortcut(keyCode: key, modifiers: modifiers)
    }
}
