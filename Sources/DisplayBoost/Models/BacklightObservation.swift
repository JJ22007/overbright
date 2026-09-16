import Foundation

/// Brightness is not user intent: ambient-light adjustment also changes it.
/// Accept every valid backlight level; only unreadable values need a grace period.
struct BacklightObservation {
    enum Decision: Equatable { case ready, pending, unavailable }
    private var uncertainSince: TimeInterval?

    mutating func reset() { uncertainSince = nil }

    mutating func observe(_ value: Float?, now: TimeInterval) -> Decision {
        let valid = value.flatMap { $0.isFinite && (0...1).contains($0) ? $0 : nil }
        if valid != nil {
            reset()
            return .ready
        }
        if uncertainSince == nil { uncertainSince = now }
        guard now - (uncertainSince ?? now) >= 1 else { return .pending }
        return .unavailable
    }
}
