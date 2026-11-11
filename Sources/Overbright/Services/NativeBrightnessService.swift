import CoreGraphics
import Darwin

final class NativeBrightnessService {
    private typealias GetBrightness = @convention(c) (
        CGDirectDisplayID,
        UnsafeMutablePointer<Float>
    ) -> Int32
    private typealias SetBrightness = @convention(c) (
        CGDirectDisplayID,
        Float
    ) -> Int32
    private typealias NotifyBrightness = @convention(c) (
        CGDirectDisplayID,
        Double
    ) -> Void

    private let frameworkHandle: UnsafeMutableRawPointer?
    private let getBrightness: GetBrightness?
    private let setBrightness: SetBrightness?
    private let notifyBrightness: NotifyBrightness?

    init() {
        frameworkHandle = dlopen(
            "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices",
            RTLD_LAZY
        )
        getBrightness = Self.loadSymbol(
            "DisplayServicesGetBrightness",
            from: frameworkHandle,
            as: GetBrightness.self
        )
        setBrightness = Self.loadSymbol(
            "DisplayServicesSetBrightness",
            from: frameworkHandle,
            as: SetBrightness.self
        )
        notifyBrightness = Self.loadSymbol(
            "DisplayServicesBrightnessChanged",
            from: frameworkHandle,
            as: NotifyBrightness.self
        )
    }

    deinit {
        if let frameworkHandle {
            dlclose(frameworkHandle)
        }
    }

    func read(displayID: CGDirectDisplayID) -> Float? {
        guard let getBrightness else { return nil }
        var value: Float = 0
        guard getBrightness(displayID, &value) == 0 else { return nil }
        return value
    }

    @discardableResult
    func write(_ proposed: Float, displayID: CGDirectDisplayID) -> Bool {
        guard let setBrightness else { return false }
        let value = min(max(proposed, 0), 1)
        if let current = read(displayID: displayID), abs(current - value) < 0.001 {
            return true
        }
        guard setBrightness(displayID, value) == 0 else { return false }
        notifyBrightness?(displayID, Double(value))
        return true
    }

    private static func loadSymbol<T>(
        _ name: String,
        from handle: UnsafeMutableRawPointer?,
        as type: T.Type
    ) -> T? {
        guard let handle, let address = dlsym(handle, name) else { return nil }
        return unsafeBitCast(address, to: type)
    }
}
