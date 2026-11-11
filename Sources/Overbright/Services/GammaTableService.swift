import CoreGraphics

final class GammaTableService {
    private struct Table {
        var red: [CGGammaValue]
        var green: [CGGammaValue]
        var blue: [CGGammaValue]
        let sampleCount: UInt32
    }

    private let capacity: UInt32 = 256
    private var baseline: Table?
    private var displayID: CGDirectDisplayID?
    private(set) var appliedFactor: Float = 1

    var hasBaseline: Bool {
        baseline != nil && displayID != nil
    }

    var baselineDisplayIsOnline: Bool {
        guard let displayID else { return false }
        return CGDisplayIsOnline(displayID) != 0
    }

    func captureBaseline(displayID: CGDirectDisplayID) -> Bool {
        if baseline != nil || self.displayID != nil {
            return self.displayID == displayID && baseline != nil
        }

        var red = [CGGammaValue](repeating: 0, count: Int(capacity))
        var green = red
        var blue = red
        var sampleCount: UInt32 = 0

        let result = CGGetDisplayTransferByTable(
            displayID,
            capacity,
            &red,
            &green,
            &blue,
            &sampleCount
        )
        guard result == .success, sampleCount == capacity else { return false }

        baseline = Table(
            red: red,
            green: green,
            blue: blue,
            sampleCount: sampleCount
        )
        self.displayID = displayID
        appliedFactor = 1
        return true
    }

    @discardableResult
    func apply(factor proposed: Float) -> Bool {
        guard var table = baseline, let displayID else { return false }
        let factor = BoostLevel(proposed).factor

        for index in table.red.indices {
            table.red[index] *= factor
            table.green[index] *= factor
            table.blue[index] *= factor
        }

        let result = CGSetDisplayTransferByTable(
            displayID,
            table.sampleCount,
            &table.red,
            &table.green,
            &table.blue
        )
        guard result == .success else { return false }
        appliedFactor = factor
        return true
    }

    func appearsApplied(tolerance: Float = 0.025) -> Bool {
        guard let baseline, let displayID else { return false }

        var red = [CGGammaValue](repeating: 0, count: Int(capacity))
        var green = red
        var blue = red
        var sampleCount: UInt32 = 0
        guard CGGetDisplayTransferByTable(
            displayID,
            capacity,
            &red,
            &green,
            &blue,
            &sampleCount
        ) == .success,
        sampleCount == baseline.sampleCount,
        let expectedRed = baseline.red.last,
        let expectedGreen = baseline.green.last,
        let expectedBlue = baseline.blue.last,
        let actualRed = red.prefix(Int(sampleCount)).last,
        let actualGreen = green.prefix(Int(sampleCount)).last,
        let actualBlue = blue.prefix(Int(sampleCount)).last else {
            return false
        }

        return abs(actualRed - expectedRed * appliedFactor) <= tolerance &&
            abs(actualGreen - expectedGreen * appliedFactor) <= tolerance &&
            abs(actualBlue - expectedBlue * appliedFactor) <= tolerance
    }

    @discardableResult
    func restore() -> Bool {
        guard var baseline, let displayID else { return true }
        let result = CGSetDisplayTransferByTable(
            displayID,
            baseline.sampleCount,
            &baseline.red,
            &baseline.green,
            &baseline.blue
        )
        guard result == .success else { return false }
        appliedFactor = 1
        return matchesBaseline()
    }

    @discardableResult
    func restore(to replacementDisplayID: CGDirectDisplayID) -> Bool {
        guard var baseline else { return true }
        let result = CGSetDisplayTransferByTable(
            replacementDisplayID,
            baseline.sampleCount,
            &baseline.red,
            &baseline.green,
            &baseline.blue
        )
        guard result == .success else { return false }
        displayID = replacementDisplayID
        appliedFactor = 1
        return matchesBaseline()
    }

    func matchesBaseline(tolerance: Float = 0.025) -> Bool {
        guard let baseline, let displayID,
              let current = Self.readTable(displayID: displayID, capacity: capacity),
              current.sampleCount == baseline.sampleCount else {
            return false
        }

        for index in baseline.red.indices {
            if abs(current.red[index] - baseline.red[index]) > tolerance ||
                abs(current.green[index] - baseline.green[index]) > tolerance ||
                abs(current.blue[index] - baseline.blue[index]) > tolerance {
                return false
            }
        }
        return true
    }

    func discardBaseline() {
        baseline = nil
        displayID = nil
        appliedFactor = 1
    }

    static func restoreColorSyncDefaults() {
        CGDisplayRestoreColorSyncSettings()
    }

    static func readEndpoint(displayID: CGDirectDisplayID) -> Float? {
        readTable(displayID: displayID, capacity: 256)?.red.last
    }

    private static func readTable(
        displayID: CGDirectDisplayID,
        capacity: UInt32
    ) -> Table? {
        var red = [CGGammaValue](repeating: 0, count: Int(capacity))
        var green = red
        var blue = red
        var sampleCount: UInt32 = 0
        guard CGGetDisplayTransferByTable(
            displayID,
            capacity,
            &red,
            &green,
            &blue,
            &sampleCount
        ) == .success,
        sampleCount == capacity else {
            return nil
        }
        return Table(
            red: red,
            green: green,
            blue: blue,
            sampleCount: sampleCount
        )
    }
}
