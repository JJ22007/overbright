import Foundation
import IOKit

/// Read-only: the backlight macOS is driving on the built-in panel right now,
/// from the framebuffer's `IOMFBBrightnessLevel` (16.16 fixed point, in nits).
/// It follows every ramp in real time, including the climb to the EDR peak.
/// A private interface: when it is missing, every value is nil.
final class PanelLightService {
    private var framebuffer: io_registry_entry_t = 0

    init() {
        framebuffer = Self.findBuiltInFramebuffer()
    }

    deinit {
        if framebuffer != 0 { IOObjectRelease(framebuffer) }
    }

    var panelNits: Double? {
        if framebuffer == 0 { framebuffer = Self.findBuiltInFramebuffer() }
        return nits("IOMFBBrightnessLevel")
    }

    /// The panel's physical peak (1600 nits on a MacBook Pro).
    lazy var peakNits: Double? = nits("limit_max_physical_brightness")

    private func nits(_ key: String) -> Double? {
        guard framebuffer != 0,
              let value = IORegistryEntryCreateCFProperty(
                framebuffer, key as CFString, kCFAllocatorDefault, 0
              )?.takeRetainedValue() as? NSNumber else { return nil }
        let nits = value.doubleValue / 65536
        return nits.isFinite && nits > 0 ? nits : nil
    }

    /// Registry classes that carry `IOMFBBrightnessLevel`. Some Macs expose the
    /// built-in panel as `IOMobileFramebufferShim`; others (an M1 Max on macOS
    /// 27.2) have no shim, and the panel is an `IOMobileFramebufferAP`, which
    /// matching the `IOMobileFramebuffer` base class finds.
    static let framebufferClasses = ["IOMobileFramebufferShim", "IOMobileFramebuffer"]

    /// The framebuffer that reports a backlight in nits. External displays
    /// report 1.0 (65536) or nothing, so the built-in one is the only match
    /// above a couple of nits.
    private static func findBuiltInFramebuffer() -> io_registry_entry_t {
        for className in framebufferClasses {
            let found = findBuiltInFramebuffer(className: className)
            if found != 0 { return found }
        }
        return 0
    }

    private static func findBuiltInFramebuffer(className: String) -> io_registry_entry_t {
        var iterator = io_iterator_t()
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault, IOServiceMatching(className), &iterator
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
