import Foundation

/// What Overbright reads about the built-in panel before a boost. Every value
/// comes from the running Mac, so nothing here is specific to one model.
struct PanelReadings: Equatable {
    /// A built-in display is online (false with the lid closed, or on a desktop Mac).
    var hasBuiltInDisplay: Bool
    /// `maximumPotentialExtendedDynamicRangeColorComponentValue` of the built-in
    /// screen: 1.0 on a display without EDR.
    var potentialHeadroom: Double
    /// The panel's physical peak, from the framebuffer's
    /// `limit_max_physical_brightness`. nil where there is no such framebuffer
    /// (Intel Macs) or the key is missing.
    var peakNits: Double?
    /// The framebuffer's `BLNitsCap` now: standard white, or the EDR peak while
    /// anything on screen (HDR video, another boost tool) holds EDR open.
    var capNits: Double?
    /// CoreBrightness `DisplayNitsKey`: standard white even while EDR is open.
    var systemStandardNits: Double?
    /// CoreBrightness `EDRHeadroom`: how far macOS has raised the cap above
    /// standard white for HDR content on screen (1.0 = none). A system banner
    /// on macOS 27 asks for 1.2; HDR video goes to the peak.
    var edrHeadroom: Double? = nil
}

/// Whether a Mac can boost, and how. All XDR MacBook Pros share the same
/// building blocks, but their numbers differ (standard white is 500 nits on
/// M1/M2, 600 on M3 and later, up to 1000 outdoors on M4 and later), so every
/// number is derived from `PanelReadings`, never from a model name.
enum PanelSupport {
    enum Reason: Equatable {
        case noBuiltInDisplay
        case noHeadroom
        case notXDR(peakNits: Double)
    }

    enum Verdict: Equatable {
        case supported
        case unsupported(Reason)
    }

    /// Below this the display has no EDR headroom at all.
    static let minimumHeadroom: Double = 1.05

    /// A Liquid Retina XDR panel peaks at 1600 nits. An ordinary LCD (MacBook
    /// Air, 13" MacBook Pro) peaks at 500 nits or so: driving it as if it were
    /// XDR is exactly what must never happen, so anything under this is refused.
    static let xdrMinimumPeak: Double = 1000

    /// The share of the peak a full-screen boost may ask for. The XDR panels'
    /// specification is 1000 nits sustained across the whole screen out of 1600
    /// (measured on a 14" MacBook Pro: 1000 held for a minute, 1300 sagged
    /// after ~10 s). A panel with another peak gets the same proportions.
    static let sustainedShare: Double = 1000.0 / 1600.0
    static let maximumShare: Double = 1300.0 / 1600.0

    /// While EDR is open macOS raises `BLNitsCap` towards the peak. A cap this
    /// close to the peak is not standard white.
    static let edrCapShare: Double = 0.9

    static func verdict(_ readings: PanelReadings) -> Verdict {
        guard readings.hasBuiltInDisplay else { return .unsupported(.noBuiltInDisplay) }
        guard readings.potentialHeadroom.isFinite,
              readings.potentialHeadroom > minimumHeadroom else { return .unsupported(.noHeadroom) }
        if let peak = readings.peakNits, peak < xdrMinimumPeak {
            return .unsupported(.notXDR(peakNits: peak))
        }
        return .supported
    }

    /// Standard white in nits: the cap, less the headroom macOS has opened
    /// for HDR content (a cap of 720 with a headroom of 1.2 is 600). Where the
    /// headroom cannot be read and EDR has raised the cap to the peak, macOS's
    /// own standard luminance. nil when it cannot be told.
    static func standardWhite(_ readings: PanelReadings) -> Double? {
        func valid(_ value: Double?) -> Double? {
            guard let value, value.isFinite, value > 50 else { return nil }
            return value
        }
        guard let cap = valid(readings.capNits) else { return nil }
        if let headroom = readings.edrHeadroom, headroom.isFinite, headroom > 1.02,
           let standard = valid(cap / headroom) {
            return standard
        }
        guard let peak = valid(readings.peakNits), cap >= peak * edrCapShare else { return cap }
        guard let system = valid(readings.systemStandardNits), system < peak * edrCapShare else { return nil }
        return system
    }

    /// The direct method can run: an XDR peak is known (so every write can be
    /// bounded by it) and standard white can be told.
    static func canDriveDirectly(_ readings: PanelReadings) -> Bool {
        guard verdict(readings) == .supported,
              let peak = readings.peakNits, peak >= xdrMinimumPeak else { return false }
        return standardWhite(readings) != nil
    }

    /// The direct method's ceiling: the configured `maxNits`, never more than
    /// `maximumShare` of this panel's peak.
    static func ceiling(configured: Double, peakNits: Double?) -> Double {
        guard let peak = peakNits, peak.isFinite, peak > 0 else { return configured }
        return min(configured, (peak * maximumShare).rounded(.down))
    }

    /// The highest value ever written to the framebuffer: the panel's peak.
    static func writeLimit(peakNits: Double?) -> Double? {
        guard let peak = peakNits, peak.isFinite, peak >= xdrMinimumPeak else { return nil }
        return peak
    }

    /// The methods to try, in order. On macOS 27.2 and later `classic` is never
    /// a fallback (there the gamma table makes white jump to the full backlight);
    /// it runs only when asked for. Before 27.2, `direct` and `overlay` are
    /// untested and run only when asked for, with `classic` behind them.
    static func methods(configured: BoostMethod?, major: Int, minor: Int) -> [BoostMethod] {
        let modern = (major, minor) >= (27, 2)
        let fallbacks: [BoostMethod] = modern ? [.direct, .overlay] : [.classic]
        var list: [BoostMethod] = []
        for method in [configured].compactMap({ $0 }) + fallbacks where !list.contains(method) {
            list.append(method)
        }
        if configured == .classic { return [.classic] }
        return list
    }
}

/// The one judgement `overbright report` makes: whether the direct boost the
/// app asked for is what the panel is driving now. Read-only; it never
/// changes the display.
enum BoostCheck: Equatable {
    case notBoosted
    case notDirect
    case reached
    case missed(panel: Double, target: Double)
    case unknown

    static let tolerance: Double = 5

    static func judge(boosted: Bool, method: String, targetNits: Double?, panelNits: Double?) -> BoostCheck {
        guard boosted else { return .notBoosted }
        guard method == "direct" else { return .notDirect }
        guard let targetNits, let panelNits, targetNits.isFinite, panelNits.isFinite else { return .unknown }
        return abs(panelNits - targetNits) <= tolerance ? .reached : .missed(panel: panelNits, target: targetNits)
    }
}
