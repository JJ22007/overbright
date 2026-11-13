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
    /// The HDR headroom kept on screen while the boost is on
    /// (`HeadroomHoldService`): that of a system banner on macOS 27, so a
    /// banner appearing or leaving changes nothing.
    static let heldHeadroom: Double = 1.2

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

    /// The backlight to write, given the cap macOS itself last set.
    ///
    /// While HDR content is on screen macOS raises its cap to standard white
    /// times a headroom and draws ordinary content that much darker, so
    /// ordinary white is the backlight divided by the headroom. (Measured on a
    /// 14" MacBook Pro, 27.2.1: with HDR open to the peak, a backlight written
    /// to 996 nits drew 5.7 W, less than the 6.8 W of standard white.) To keep
    /// ordinary white where the user set it, the backlight is therefore the
    /// wanted white times that headroom.
    ///
    /// `ceiling` bounds ordinary white; `hardCeiling` bounds the backlight
    /// itself. When macOS's own cap is already as high as that allows (HDR
    /// video), the answer is macOS's cap: nothing to add, and writing less
    /// would make the screen darker than without the boost.
    static func backlight(standard: Double, systemCap: Double, level: Float,
                          ceiling: Double, hardCeiling: Double) -> Double? {
        guard let white = targetNits(standard: standard, level: level, ceiling: ceiling),
              systemCap.isFinite, systemCap > 50, hardCeiling.isFinite else { return nil }
        let headroom = max(systemCap / standard, 1)
        return max(min(white * headroom, hardCeiling), systemCap)
    }

    /// Standard white once macOS has stopped changing its cap, now `systemCap`.
    /// (During its ramp the cap and the headroom both move, and nothing is
    /// decided or written: see `DirectPacer`.)
    ///
    /// A cap with no HDR headroom is standard white itself (macOS moves it
    /// with ambient light). A cap with headroom is standard white times that
    /// headroom. Without a headroom reading, a cap under the ceiling and well
    /// under the peak counts as standard white, as it did before the headroom
    /// was read.
    static func standard(previous: Double, systemCap: Double, headroom: Double?,
                         ceiling: Double, peak: Double?) -> Double {
        let edrCap = (peak ?? .infinity) * PanelSupport.edrCapShare
        guard systemCap.isFinite, systemCap > 50 else { return previous }
        guard let headroom, headroom.isFinite, headroom > 0 else {
            return systemCap < ceiling && systemCap < edrCap ? systemCap : previous
        }
        if headroom <= 1.02 { return systemCap < edrCap ? systemCap : previous }
        let standard = systemCap / headroom
        return standard > 50 ? standard : previous
    }

    /// Whether macOS is driving the backlight below what it allows: the user
    /// (or macOS) dimmed the display. That is left to the controller, which
    /// ends the boost; nothing is written over it.
    static func dimmed(level: Double, systemCap: Double, standard: Double) -> Bool {
        level < min(systemCap, standard) * 0.95
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
}

/// When the direct boost may write the backlight again after macOS wrote it.
///
/// macOS writes a ramp: the cap once per frame (8 ms) and the level every
/// 8–50 ms, for one to two seconds, whenever HDR content appears or leaves.
/// Writing the boost back after each of those steps makes the backlight
/// alternate between macOS's value and the boost's more than 200 times a
/// second (measured; the screen flashes). So the boost never answers a step:
/// it waits until macOS has left the backlight alone for `settle`, then writes
/// once.
///
/// If macOS takes the backlight again within `retakeWindow` of that write, it
/// was not done (a slow adjustment with long pauses), and the wait doubles, up
/// to `longestSettle`, so the two never settle into a slow alternation either.
/// A takeover later than that starts from `shortestSettle` again.
struct DirectPacer {
    static let shortestSettle: TimeInterval = 0.25
    static let longestSettle: TimeInterval = 4
    static let retakeWindow: TimeInterval = 2
    static let tolerance: Double = 0.02

    private(set) var settle = DirectPacer.shortestSettle
    private var lastCap: Double?
    private var lastLevel: Double?
    private var changedAt: TimeInterval = 0
    private var wroteAt: TimeInterval?
    private var wasOurs = false
    /// macOS has written values the boost has not answered yet.
    private(set) var pending = false

    /// One look at the panel. `written` is what the boost last wrote, nil
    /// while macOS's own values are left alone. True when the boost should be
    /// worked out and written now; the caller then reports `applied`.
    mutating func poll(cap: Double, level: Double, written: Double?, now: TimeInterval) -> Bool {
        let ours = written.map { abs(cap - $0) <= Self.tolerance && abs(level - $0) <= Self.tolerance } ?? false
        let changed = cap != lastCap || level != lastLevel
        lastCap = cap
        lastLevel = level
        defer { wasOurs = ours }
        if ours {
            pending = false
            return false
        }
        if wasOurs {
            // A takeover starts here.
            if let wroteAt, now - wroteAt < Self.retakeWindow {
                settle = min(settle * 2, Self.longestSettle)
            } else {
                settle = Self.shortestSettle
            }
        }
        if changed {
            pending = true
            changedAt = now
        }
        return pending && now - changedAt >= settle
    }

    /// The caller acted on a true `poll`. `wrote` is false when it found
    /// nothing to write (macOS's own backlight stands). `taken` is false when
    /// macOS did not take the write: it is tried again after another wait.
    mutating func applied(wrote: Bool, taken: Bool = true, now: TimeInterval) {
        if !taken {
            changedAt = now
            return
        }
        pending = false
        if wrote { wroteAt = now }
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
