import Foundation

struct BoostLevel: Equatable {
    static let minimum: Float = 1.0
    static let maximum: Float = 1.60
    static let defaultValue: Float = 1.25

    /// The user's own ceiling (`maxLevel` in the config). Never above `maximum`,
    /// which stays the fixed reference for `BoostCalibration`.
    static var cap: Float = maximum {
        didSet { cap = cap.isFinite ? min(max(cap, minimum), maximum) : maximum }
    }

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
            (BoostLevel.maximum - BoostLevel.minimum)
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
