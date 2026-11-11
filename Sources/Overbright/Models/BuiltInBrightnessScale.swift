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

    /// The segment index (0-based) just above 100%, where the boost starts;
    /// nil when the scale ends at 100%.
    static func boostSegment(top: Double) -> Int? {
        guard top > 100.0001 else { return nil }
        return Int((100 / (top / Double(segmentCount))).rounded())
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
/// ordinary content back down so it looks unchanged. Where that scaling happens
/// differs between macOS versions:
///
/// - `.classic` (up to macOS 27.1): the scaling is applied after the gamma
///   table, so a table above 1.0 lifts ordinary content into the headroom.
///   160% is a table endpoint of about 1.6.
/// - `.panel` (macOS 27.2 and later): once an app sets a gamma table, the table
///   reaches the panel without that scaling. Ordinary white is then the panel's
///   full backlight, so the table must scale it down to the wanted brightness:
///   endpoint = wanted nits ÷ live panel nits, always at or below 1.0.
enum BoostMethod: String, CaseIterable {
    case classic
    case panel

    /// The method for a macOS version, used when the config says "auto".
    static func automatic(major: Int, minor: Int) -> BoostMethod {
        (major, minor) >= (27, 2) ? .panel : .classic
    }
}

/// Arithmetic for `.panel`: keep ordinary white at a target luminance while the
/// panel's backlight moves underneath it.
enum PanelCompensation {
    /// Never scale the picture below this; protects against a bad reading.
    static let minimumFactor: Float = 0.05

    /// Ordinary white for a boost level on top of the standard luminance.
    static func targetNits(standardNits: Double, level: Double) -> Double {
        standardNits * level
    }

    /// The gamma endpoint that turns `panelNits` of backlight into `targetNits`
    /// of white. Capped at 1.0: the table can only take light away, so a panel
    /// that is still ramping up simply shows its full backlight.
    static func factor(targetNits: Double, panelNits: Double) -> Float {
        guard targetNits.isFinite, panelNits.isFinite, panelNits > 0, targetNits > 0 else { return 1 }
        return Float(min(max(targetNits / panelNits, Double(minimumFactor)), 1))
    }

    /// Where the backlight will be `lead` seconds from now if it keeps ramping
    /// at the rate between two readings. macOS ramps the backlight
    /// exponentially (about 7% per 50 ms into EDR), so the rate is a ratio.
    /// Compensating for the predicted value instead of the last reading keeps
    /// white from overshooting while the ramp runs.
    static func predictedPanelNits(previous: Double, current: Double, interval: Double, lead: Double) -> Double {
        guard previous > 0, current > 0, interval > 0.001, lead > 0 else { return current }
        let rate = log(current / previous) / interval
        // Never extrapolate more than one reading's worth of change.
        let step = min(max(rate * lead, -abs(log(current / previous))), abs(log(current / previous)))
        return current * exp(step)
    }

    /// The estimated luminance of ordinary white while Overbright's table is
    /// installed: the backlight times the table's endpoint.
    static func whiteNits(panelNits: Double, gammaEndpoint: Double) -> Double {
        panelNits * min(max(gammaEndpoint, 0), 1)
    }

    /// The panel is back where it was before the boost, so the original table
    /// can go back. That is the standard backlight, or higher when another app
    /// was already showing EDR content before the boost and still is.
    static func isSettled(panelNits: Double, standardNits: Double, beforeBoostNits: Double? = nil) -> Bool {
        panelNits <= max(standardNits, beforeBoostNits ?? standardNits) * 1.01 + 0.5
    }

    /// Whether the backlight is still above the standard one when the original
    /// table goes back. Then macOS's own EDR scaling has to take over, which it
    /// only does for the system's table, not for one an app sets explicitly.
    static func needsSystemScaling(panelNits: Double, standardNits: Double) -> Bool {
        panelNits > standardNits * 1.01 + 0.5
    }
}
