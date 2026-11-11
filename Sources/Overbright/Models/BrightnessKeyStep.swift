import Foundation

enum BrightnessKeyDirection: Equatable {
    case increase
    case decrease
}

enum BrightnessKeyStep {
    static let defaultCoarse: Float = 1.0 / 16.0
    static let defaultFine: Float = 1.0 / 64.0

    /// Set from `keyStep` and `fineKeyStep` in the config.
    static var coarse: Float = defaultCoarse
    static var fine: Float = defaultFine

    static func nextBoostLevel(
        from current: Float,
        direction: BrightnessKeyDirection,
        fineGrained: Bool
    ) -> BoostLevel {
        let step = fineGrained ? fine : coarse
        // Steps are counted from 100%, so any step size lands on 100% exactly.
        let position = (current - BoostLevel.minimum) / step
        let epsilon: Float = 0.0001

        let targetPosition: Float
        switch direction {
        case .increase:
            targetPosition = floor(position + epsilon) + 1
        case .decrease:
            targetPosition = ceil(position - epsilon) - 1
        }
        return BoostLevel(BoostLevel.minimum + targetPosition * step)
    }
}
