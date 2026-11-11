import Foundation

struct BoostLevel: Equatable {
    static let minimum: Float = 1.0
    static let defaultValue: Float = 1.25
    /// The top of the gamma (classic) method, the reference for `BoostCalibration`.
    static let classicMaximum: Float = 1.60
    /// A hard limit whatever a panel reports.
    static let absoluteMaximum: Float = 4.0

    /// The highest level this panel can show: measured from its EDR headroom
    /// with the overlay method (`PanelCeiling`), `classicMaximum` otherwise or
    /// until measured.
    static var maximum: Float = classicMaximum {
        didSet { maximum = maximum.isFinite ? min(max(maximum, minimum), absoluteMaximum) : classicMaximum }
    }

    /// The user's own ceiling (`maxLevel` in the config); `absoluteMaximum`
    /// for "auto", so the panel decides.
    static var userCap: Float = absoluteMaximum {
        didSet { userCap = userCap.isFinite ? min(max(userCap, minimum), absoluteMaximum) : absoluteMaximum }
    }

    /// The level nothing goes above: the panel's top or the user's, whichever is lower.
    static var cap: Float { min(userCap, maximum) }

    let factor: Float

    init(_ proposed: Float) {
        factor = proposed.isFinite ? min(max(proposed, Self.minimum), Self.cap) : Self.minimum
    }

    var percentage: Int {
        Int((factor * 100).rounded())
    }

    var normalizedSliderValue: Double {
        Double(factor)
    }
}

enum BoostCalibration {
    static let maximumEDRPipelineValue: Float = 16
    static let referenceEDR: Float = 3.2
    static let maximumBonusGamma: Float = 0.59

    static func gammaFactor(level: BoostLevel, currentEDR: Float) -> Float {
        guard currentEDR.isFinite, currentEDR > 1 else { return 1 }
        let boundedEDR = min(
            max(currentEDR, referenceEDR),
            maximumEDRPipelineValue
        )
        let availableBonus = maximumBonusGamma * (
            1 - (boundedEDR - referenceEDR) /
                (maximumEDRPipelineValue - referenceEDR)
        )
        let requestedFraction = (level.factor - BoostLevel.minimum) /
            (BoostLevel.classicMaximum - BoostLevel.minimum)
        return min(currentEDR, 1 + availableBonus * requestedFraction)
    }
}

enum BoostState: Equatable {
    case off
    case engaging
    case active
    case unavailable(String)

    var isRunning: Bool {
        switch self {
        case .engaging, .active:
            return true
        case .off, .unavailable:
            return false
        }
    }
}

struct BoostSnapshot: Equatable {
    let state: BoostState
    let level: BoostLevel
    let currentEDRHeadroom: Double
    let potentialEDRHeadroom: Double
}

/// The highest boost a panel can show with the overlay method. At the EDR peak
/// macOS reports a headroom (peak ÷ standard white; 2.67 on a 14" MacBook
/// Pro with a 600-nit standard white and a 1600-nit peak) and draws ordinary
/// white `EDRWhiteCorrection.full` dimmer, which the overlay makes up. What
/// is left is the boost: 2.67 ÷ 1.09 = 2.44 there.
enum PanelCeiling {
    static func level(headroom: Double, correction: Double = EDRWhiteCorrection.full) -> Float? {
        guard headroom.isFinite, correction > 0 else { return nil }
        let level = (headroom / correction * 100).rounded(.down) / 100
        guard level > 1.05 else { return nil }
        return min(Float(level), BoostLevel.absoluteMaximum)
    }
}
