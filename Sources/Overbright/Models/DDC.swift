import Foundation

/// DDC/CI packets for reading and writing one VCP feature (brightness is 0x10).
/// Pure byte arithmetic, covered by the logic tests. The I2C transport lives in
/// `Services/DDCService.swift`.
///
/// A packet travels from the host (source address 0x51) to the display
/// (I2C address 0x37, written as 0x6E). The transport sends 0x51 itself, so the
/// bytes here start at the length byte; the checksum still covers 0x6E and 0x51.
enum DDC {
    static let i2cAddress: UInt32 = 0x37
    static let hostAddress: UInt32 = 0x51
    static let brightness: UInt8 = 0x10

    /// "Get VCP feature" request.
    static func getRequest(code: UInt8) -> [UInt8] {
        sign([0x82, 0x01, code])
    }

    /// "Set VCP feature" request.
    static func setRequest(code: UInt8, value: UInt16) -> [UInt8] {
        sign([0x84, 0x03, code, UInt8(value >> 8), UInt8(value & 0xFF)])
    }

    /// Parses a "Get VCP feature" reply. Returns nil unless the reply is
    /// well-formed, answers `code`, reports success, and its checksum matches.
    static func parseReply(_ reply: [UInt8], code: UInt8) -> (current: UInt16, maximum: UInt16)? {
        guard reply.count >= 11,
              reply[0] == 0x6E,      // from the display
              reply[1] == 0x88,      // 8 data bytes follow
              reply[2] == 0x02,      // "Get VCP feature" reply
              reply[3] == 0x00,      // no error
              reply[4] == code else { return nil }
        let checksum = reply[0..<10].reduce(UInt8(0x50)) { $0 ^ $1 }
        guard checksum == reply[10] else { return nil }
        let maximum = UInt16(reply[6]) << 8 | UInt16(reply[7])
        let current = UInt16(reply[8]) << 8 | UInt16(reply[9])
        guard maximum > 0 else { return nil }
        return (min(current, maximum), maximum)
    }

    private static func sign(_ bytes: [UInt8]) -> [UInt8] {
        bytes + [bytes.reduce(UInt8(0x6E ^ 0x51)) { $0 ^ $1 }]
    }
}

/// Brightness arithmetic for external displays, in percent.
///
/// 0...100 is the display's own range. A backlight at 0 is still lit, so with
/// extra dimming the scale continues below zero, down to `extraDimMinimum`:
/// the backlight stays at 0 and the picture is darkened in software. It is the
/// mirror image of the built-in display's boost above 100%.
enum ExternalBrightness {
    /// Software dimming never goes fully black: below this the screen is unusable
    /// and the user could not see the menu to bring it back. The one exception
    /// is `dimShortcut`, whose next press brings it back (`DimAll.blackout`).
    static let softwareMinimum: Double = 10
    /// Lowest level with extra dimming: backlight 0 and the picture at 10%.
    static let extraDimMinimum: Double = -90

    static func clamp(_ level: Double, minimum: Double = 0) -> Double {
        level.isFinite ? min(max(level, minimum), 100) : 100
    }

    /// The lowest level a display can be set to.
    static func minimum(software: Bool, extraDimming: Bool) -> Double {
        if software { return softwareMinimum }
        return extraDimming ? extraDimMinimum : 0
    }

    /// Splits a level into what the display's backlight gets (0...100) and the
    /// gamma multiplier applied on top (1 unless the level is below zero).
    static func split(_ level: Double) -> (hardware: Double, factor: Float) {
        let level = clamp(level, minimum: extraDimMinimum)
        guard level < 0 else { return (level, 1) }
        return (0, Float((100 + level) / 100))
    }

    /// "60%", or "−40%" below zero.
    static func label(_ level: Double) -> String {
        let rounded = Int(level.rounded())
        return rounded < 0 ? "\u{2212}\(-rounded)%" : "\(rounded)%"
    }

    /// One key press. Steps are counted from 0, so any step size lands exactly
    /// on 0 and 100.
    static func next(
        from current: Double,
        direction: BrightnessKeyDirection,
        step: Double,
        minimum: Double = 0
    ) -> Double {
        guard step > 0 else { return clamp(current, minimum: minimum) }
        let position = clamp(current, minimum: minimum) / step
        let epsilon = 0.0001
        let target: Double
        switch direction {
        case .increase: target = (floor(position + epsilon) + 1) * step
        case .decrease: target = (ceil(position - epsilon) - 1) * step
        }
        return clamp(target, minimum: minimum)
    }

    /// Percent to a DDC value on the display's own scale.
    static func ddcValue(level: Double, maximum: UInt16) -> UInt16 {
        UInt16((clamp(level) / 100 * Double(maximum)).rounded())
    }

    static func level(ddcValue: UInt16, maximum: UInt16) -> Double {
        guard maximum > 0 else { return 100 }
        return clamp(Double(ddcValue) / Double(maximum) * 100)
    }

    /// Gamma multiplier for software dimming.
    static func softwareFactor(level: Double) -> Float {
        Float(max(clamp(level), softwareMinimum) / 100)
    }
}
