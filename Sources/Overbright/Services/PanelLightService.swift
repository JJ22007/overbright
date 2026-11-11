import Foundation
import IOKit

/// Read-only measurements of the built-in panel's light.
///
/// - `panelNits`: the backlight macOS is driving right now, from the built-in
///   framebuffer's `IOMFBBrightnessLevel` (16.16 fixed point, in nits). It
///   follows every ramp in real time, including the climb to the EDR peak.
/// - `standardNits`: what macOS would drive ordinary white at without EDR, from
///   CoreBrightness's `DisplayNitsKey`. Read only; Overbright never writes
///   CoreBrightness.
///
/// Both are private interfaces. When either is missing, `isAvailable` is false
/// and the boost falls back to the classic method.
final class PanelLightService {
    private var framebuffer: io_registry_entry_t = 0
    private let brightnessClient: NSObject?
    private let copySelector = NSSelectorFromString("copyPropertyForKey:")

    init() {
        dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_LAZY)
        brightnessClient = (NSClassFromString("BrightnessSystemClient") as? NSObject.Type)?.init()
        framebuffer = Self.findBuiltInFramebuffer()
    }

    deinit {
        if framebuffer != 0 { IOObjectRelease(framebuffer) }
    }

    var isAvailable: Bool { panelNits != nil && standardNits != nil }

    var panelNits: Double? {
        if framebuffer == 0 { framebuffer = Self.findBuiltInFramebuffer() }
        guard framebuffer != 0,
              let value = IORegistryEntryCreateCFProperty(
                framebuffer, "IOMFBBrightnessLevel" as CFString, kCFAllocatorDefault, 0
              )?.takeRetainedValue() as? NSNumber else { return nil }
        let nits = value.doubleValue / 65536
        return nits.isFinite && nits > 0 ? nits : nil
    }

    /// The panel's physical peak (1600 nits on a MacBook Pro): a ramp never
    /// goes past it, so a prediction must not either.
    lazy var peakNits: Double? = {
        guard framebuffer != 0,
              let value = IORegistryEntryCreateCFProperty(
                framebuffer, "limit_max_physical_brightness" as CFString, kCFAllocatorDefault, 0
              )?.takeRetainedValue() as? NSNumber else { return nil }
        let nits = value.doubleValue / 65536
        return nits.isFinite && nits > 0 ? nits : nil
    }()

    var standardNits: Double? {
        guard let client = brightnessClient, client.responds(to: copySelector),
              let value = client.perform(copySelector, with: "DisplayNitsKey")?.takeRetainedValue() as? NSNumber
        else { return nil }
        let nits = value.doubleValue
        return nits.isFinite && nits > 0 ? nits : nil
    }

    /// The framebuffer that reports a backlight in nits. External displays
    /// report 1.0 (65536) or nothing, so the built-in one is the only match
    /// above a couple of nits.
    private static func findBuiltInFramebuffer() -> io_registry_entry_t {
        var iterator = io_iterator_t()
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault, IOServiceMatching("IOMobileFramebufferShim"), &iterator
        ) == KERN_SUCCESS else { return 0 }
        defer { IOObjectRelease(iterator) }
        var found: io_registry_entry_t = 0
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            let level = (IORegistryEntryCreateCFProperty(
                entry, "IOMFBBrightnessLevel" as CFString, kCFAllocatorDefault, 0
            )?.takeRetainedValue() as? NSNumber)?.doubleValue ?? 0
            if found == 0, level > 65536 * 2 {
                found = entry
            } else {
                IOObjectRelease(entry)
            }
        }
        return found
    }
}
