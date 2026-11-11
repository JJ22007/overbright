import Foundation

/// One brightness scale for the built-in display, 0–160%.
///
/// 0–100% is the system backlight, exactly as macOS's own slider. Above 100%
/// the backlight stays at full and the Overbright boost takes over. With the
/// Accessibility permission, F1/F2 move along this one scale and Overbright
/// shows the only indicator; without it, macOS keeps the keys.
enum BuiltInBrightnessScale {
    /// The indicator's bar always has this many segments.
    static let segmentCount = 16

    /// The top of the scale for a display that can boost, in percent.
    static var top: Double { (Double(BoostLevel.cap) * 10000).rounded() / 100 }

    /// The current position: the boost level while boosting, otherwise the
    /// backlight.
    static func percent(backlight: Float, boost: BoostLevel, boosting: Bool) -> Double {
        if boosting { return Double(boost.factor) * 100 }
        return min(max(Double(backlight), 0), 1) * 100
    }

    /// One key press. Steps are counted from 0, so 100% is always a step and a
    /// fine step never skips it. `top` is 100 on a display that cannot boost.
    static func next(
        from current: Double,
        direction: BrightnessKeyDirection,
        step: Double,
        top: Double
    ) -> Double {
        let clamped = min(max(current, 0), top)
        guard step > 0 else { return clamped }
        let position = clamped / step
        let epsilon = 0.0001
        let target: Double
        switch direction {
        case .increase: target = (floor(position + epsilon) + 1) * step
        case .decrease: target = (ceil(position - epsilon) - 1) * step
        }
        return min(max(target, 0), top)
    }

    /// What a position means: a backlight value (0...1) and, above 100%, a
    /// boost level.
    static func split(_ percent: Double) -> (backlight: Float, boost: Float?) {
        if percent > 100.0001 {
            return (1, Float(percent / 100))
        }
        return (Float(max(percent, 0) / 100), nil)
    }

    /// How full each of the indicator's segments is, 0...1, for a scale from
    /// 0 to `top`.
    static func segmentFills(percent: Double, top: Double) -> [Double] {
        let span = top / Double(segmentCount)
        return (0..<segmentCount).map { index in
            min(max((percent - Double(index) * span) / span, 0), 1)
        }
    }

    /// A boost only makes sense on top of a full backlight. When macOS or the
    /// user lowers the backlight clearly below full while boosted (automatic
    /// brightness, Control Center), the boost ends instead of staying on top of
    /// a dimmer backlight.
    static let fullBacklightThreshold: Float = 0.95

    static func backlightDropEndsBoost(previous: Float, current: Float) -> Bool {
        current < previous - 0.001 && current < fullBacklightThreshold
    }
}

/// How the boost turns EDR headroom into brighter ordinary content.
///
/// macOS drives the panel's backlight up to its peak (1600 nits on a 14"/16"
/// MacBook Pro) as soon as anything on screen asks for EDR, and normally scales
/// ordinary content back down so it looks unchanged.
///
/// - `.classic` (up to macOS 27.1): the scaling is applied after the gamma
///   table, so a table above 1.0 lifts ordinary content into the headroom.
///   160% is a table endpoint of about 1.6.
/// - `.overlay` (macOS 27.2 and later): the gamma table no longer changes the
///   emitted light at all, and a table that is installed when EDR starts stops
///   macOS's scaling, so white jumps to the full backlight. Measured with a
///   camera. Instead a full-screen EDR layer multiplies everything under it by
///   the boost level (1.0-1.6) and no table is ever written.
enum BoostMethod: String, CaseIterable {
    case classic
    case overlay

    /// The method for a macOS version, used when the config says "auto".
    static func automatic(major: Int, minor: Int) -> BoostMethod {
        (major, minor) >= (27, 2) ? .overlay : .classic
    }
}

/// macOS 27.2 draws ordinary white about 9% dimmer once the backlight has
/// reached its EDR peak (MacBook Pro; measured with a camera: ×1.08 reads just
/// under the standard white, ×1.10 just over). While the backlight is still
/// ramping up it does not, so the correction has to follow the backlight: none
/// during the ramp, then eased in over `duration` as the backlight arrives.
/// macOS starts dimming as the backlight reaches its peak and a change to the
/// layer takes about 0.15 s to show, so the correction starts a little before
/// the peak (the ramp's last ~70 ms).
struct EDRWhiteCorrection {
    static let full: Double = 1.09
    static let delay: Double = 0
    static let duration: Double = 0.25
    static let nearPeak: Double = 0.93

    /// Whether the backlight counts as (about to be) at its peak. Without a
    /// known peak, a backlight well above any standard level counts.
    static func isAtPeak(panelNits: Double, peakNits: Double?) -> Bool {
        if let peakNits { return panelNits >= peakNits * nearPeak }
        return panelNits >= 1450
    }

    /// The correction `elapsed` seconds after the backlight got near its peak,
    /// or 1 while it has not.
    static func value(sincePeak elapsed: Double?) -> Double {
        guard let elapsed, elapsed >= delay else { return 1 }
        let progress = min((elapsed - delay) / duration, 1)
        return 1 + (full - 1) * progress
    }
}
