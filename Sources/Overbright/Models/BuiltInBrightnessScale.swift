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
///
/// - `.direct` (default on macOS 27.2 and later): no layer and no table. The
///   panel's backlight is driven past standard white directly, through the
///   framebuffer's nits cap and level (`DirectPanelService`). Nothing is drawn
///   on screen, so Spaces and Mission Control transitions, which draw the
///   overlay as a white sheet, are unaffected.
enum BoostMethod: String, CaseIterable {
    case classic
    case overlay
    case direct

    /// The method for a macOS version, used when the config says "auto".
    static func automatic(major: Int, minor: Int) -> BoostMethod {
        (major, minor) >= (27, 2) ? .direct : .classic
    }
}

/// The arithmetic of the direct method, in nits.
///
/// `standard` is the panel's standard white right now: the framebuffer's nits
/// cap, which macOS sets for ordinary content (600 on a 14" MacBook Pro, more
/// in bright surroundings). A boost level multiplies it, up to `ceiling`
/// (`maxNits` in the config, 1000 by default: what the panel holds across the
/// whole screen; above that its own thermal limit pulls the backlight down
/// within seconds, measured at 1300, and macOS overrides 1600 at once).
enum DirectPanel {
    static let defaultCeiling: Double = 1000
    static let ceilingRange: ClosedRange<Double> = 700...1300

    static func targetNits(standard: Double, level: Float, ceiling: Double) -> Double? {
        guard standard.isFinite, standard > 50, level.isFinite, ceiling.isFinite else { return nil }
        return min(standard * Double(max(level, 1)), max(ceiling, standard))
    }

    /// The top of the scale: the ceiling over standard white, as a level
    /// (1000 / 600 = 1.66). nil when there is no room above standard.
    static func maximumLevel(standard: Double, ceiling: Double) -> Float? {
        guard standard.isFinite, standard > 50, ceiling.isFinite else { return nil }
        let level = (ceiling / standard * 100).rounded(.down) / 100
        return level > 1.05 ? min(Float(level), BoostLevel.absoluteMaximum) : nil
    }

    /// What to do once macOS has replaced the boost and its values have
    /// settled. A new cap at full backlight is macOS choosing a new standard
    /// white (ambient light, up or down): follow it and put the boost back.
    /// A backlight below standard white is the user dimming: leave it to the
    /// controller. The new standard is decided before that comparison, so a
    /// darker room (720 to 600 nits) is not mistaken for dimming.
    struct Settled: Equatable {
        var reapply: Bool
        var newStandard: Double?
    }

    /// What to write when the boost ends (or after a crash). The cap goes back
    /// to standard white: what macOS reports now if it is believable, else the
    /// cap saved before the boost. The level is only lowered, to that standard,
    /// and only while it is above it: a level at or below standard is macOS's
    /// own (the user dimmed, or macOS already took over) and is left alone.
    /// A level saved before the boost is never written back: it can be a value
    /// caught in the middle of a macOS ramp (160 nits was seen), and writing it
    /// back left the panel there.
    static func restore(savedCap: Double?, systemStandard: Double?, currentLevel: Double?,
                        peak: Double?) -> (cap: Double, level: Double?)? {
        let limit = (peak ?? .infinity) * PanelSupport.edrCapShare
        func believable(_ value: Double?) -> Double? {
            guard let value, value.isFinite, value > 50, value < limit else { return nil }
            return value
        }
        guard let standard = believable(systemStandard) ?? believable(savedCap) else { return nil }
        guard let currentLevel, currentLevel.isFinite, currentLevel > standard + 1 else { return (standard, nil) }
        return (standard, standard)
    }

    static func settled(cap: Double, level: Double, writtenCap: Double?, standard: Double?,
                        ceiling: Double, peak: Double?) -> Settled {
        var effectiveStandard = standard ?? 0
        var newStandard: Double?
        if let writtenCap, abs(cap - writtenCap) > 1, cap > 50, cap < ceiling,
           cap < (peak ?? .infinity) * PanelSupport.edrCapShare {
            newStandard = cap
            effectiveStandard = cap
        }
        guard level >= effectiveStandard * 0.95 else { return Settled(reapply: false, newStandard: nil) }
        return Settled(reapply: true, newStandard: newStandard)
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
