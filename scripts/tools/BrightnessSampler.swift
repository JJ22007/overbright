// Read-only measurements of the built-in display, shared by brightness-log and
// brightness-check. Nothing here writes a backlight, gamma or CoreBrightness
// value.
//
// What each value is:
//   backlight     DisplayServices backlight, 0...1 (the system slider)
//   standardNits  CoreBrightness DisplayNitsKey: ordinary white without EDR
//   panelNits     IOMFBBrightnessLevel on the built-in framebuffer: the backlight
//                 macOS is driving right now, in nits, live through every ramp
//   edr           CoreBrightness EDRHeadroom (1.0 = no EDR)
//   gamma         gamma table endpoint (red channel, last entry)
//   whiteNits     estimated luminance of ordinary white
//
// There is no light sensor that sees the screen (the ambient sensor does not
// respond to it), so whiteNits is a model built from two exact readings:
//   panel  (macOS 27.2+): with an app's gamma table installed, panelNits × min(gamma, 1);
//          with the table at exactly 1.0, macOS's own EDR scaling applies and white
//          is standardNits
//   classic (older macOS): standardNits × min(gamma, edr)
// See BoostMethod in Sources/Overbright/Models/BuiltInBrightnessScale.swift for
// the evidence behind the panel model.
import AppKit
import CoreGraphics
import Foundation
import IOKit

struct BrightnessSample {
    var time: Double
    var backlight: Double?
    var standardNits: Double?
    var panelNits: Double?
    var edr: Double?
    var gamma: Double?
    var whiteNits: Double?

    static let header = ["t", "backlight", "standardNits", "panelNits", "edr", "gamma", "whiteNits"]

    func row(_ digits: Int = 3) -> [String] {
        func f(_ value: Double?, _ d: Int) -> String { value.map { String(format: "%.\(d)f", $0) } ?? "-" }
        return [f(time, 3), f(backlight, 3), f(standardNits, 0), f(panelNits, 0), f(edr, 2), f(gamma, 3), f(whiteNits, 0)]
    }
}

final class BrightnessSampler {
    enum Model: String { case panel, classic }

    let model: Model
    let displayID: CGDirectDisplayID
    private let getBrightness: (@convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32)?
    private let client: NSObject?
    private let copySelector = NSSelectorFromString("copyPropertyForKey:")
    private var framebuffer: io_registry_entry_t = 0

    init?(model: Model) {
        self.model = model
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        CGGetOnlineDisplayList(16, &ids, &count)
        guard let builtIn = ids.prefix(Int(count)).first(where: { CGDisplayIsBuiltin($0) != 0 }) else { return nil }
        displayID = builtIn

        let services = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY)
        getBrightness = dlsym(services, "DisplayServicesGetBrightness").map {
            unsafeBitCast($0, to: (@convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32).self)
        }
        dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_LAZY)
        client = (NSClassFromString("BrightnessSystemClient") as? NSObject.Type)?.init()

        var iterator = io_iterator_t()
        if IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOMobileFramebufferShim"), &iterator) == KERN_SUCCESS {
            while case let entry = IOIteratorNext(iterator), entry != 0 {
                let level = (IORegistryEntryCreateCFProperty(entry, "IOMFBBrightnessLevel" as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? NSNumber)?.doubleValue ?? 0
                if framebuffer == 0, level > 65536 * 2 { framebuffer = entry } else { IOObjectRelease(entry) }
            }
            IOObjectRelease(iterator)
        }
    }

    private func coreBrightness(_ key: String) -> Double? {
        guard let client, client.responds(to: copySelector),
              let value = client.perform(copySelector, with: key)?.takeRetainedValue() else { return nil }
        return (value as? NSNumber)?.doubleValue
    }

    func sample(at time: Double) -> BrightnessSample {
        var s = BrightnessSample(time: time)
        var value: Float = 0
        if let getBrightness, getBrightness(displayID, &value) == 0 { s.backlight = Double(value) }
        s.standardNits = coreBrightness("DisplayNitsKey")
        s.edr = coreBrightness("EDRHeadroom")
        if framebuffer != 0,
           let level = IORegistryEntryCreateCFProperty(framebuffer, "IOMFBBrightnessLevel" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? NSNumber {
            s.panelNits = level.doubleValue / 65536
        }
        var red = [CGGammaValue](repeating: 0, count: 256), green = red, blue = red
        var count: UInt32 = 0
        if CGGetDisplayTransferByTable(displayID, 256, &red, &green, &blue, &count) == .success, count > 0 {
            s.gamma = Double(red[Int(count) - 1])
        }
        switch model {
        case .panel:
            let gamma = s.gamma ?? 1
            if abs(gamma - 1) < 0.0005 {
                // No app's table is scaling white (or it is at exactly 1 because
                // the backlight is already at the target): macOS's own EDR
                // scaling applies, so white is the standard luminance.
                s.whiteNits = s.standardNits ?? s.panelNits
            } else if let panel = s.panelNits {
                s.whiteNits = panel * min(max(gamma, 0), 1)
            }
        case .classic:
            if let standard = s.standardNits { s.whiteNits = standard * min(s.gamma ?? 1, max(s.edr ?? 1, 1)) }
        }
        return s
    }
}
