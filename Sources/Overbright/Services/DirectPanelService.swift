import Foundation
import IOKit
import os

/// The direct boost: drives the built-in panel's backlight past standard white
/// through the framebuffer's `BLNitsCap` (the most macOS lets the backlight
/// reach for ordinary content) and `IOMFBBrightnessLevel` (the backlight now),
/// both 16.16 fixed-point nits. No window, no gamma table, no EDR.
///
/// Measured on a 14" MacBook Pro, macOS 27.2: writes are accepted and the
/// backlight's power follows (6.8 W at 600 nits, 10.8 W at 800, 12.5 W at
/// 1000). macOS rewrites both values whenever it adjusts the backlight itself
/// (ambient light, a brightness change), so `maintain()` puts them back four
/// times a second. The panel's own thermal limit is left alone.
///
/// The values in place before the boost are kept in the defaults until they
/// are written back, so a crash is undone at the next launch.
@MainActor
final class DirectPanelService {
    private enum Key {
        static let savedCap = "directSavedCap"
        static let savedLevel = "directSavedLevel"
    }

    private let defaults = UserDefaults.standard
    private let logger = Logger(subsystem: AppInfo.bundleID, category: "Direct")
    private var framebuffer: io_registry_entry_t = 0
    private var timer: Timer?

    /// Standard white in nits, from the cap macOS set before the boost (and
    /// again whenever macOS changes it, for example with ambient light).
    private(set) var standardNits: Double?
    private(set) var targetNits: Double?
    private(set) var rewrites = 0
    var ceilingNits: Double = DirectPanel.defaultCeiling
    private var level: Float = 1
    private var writtenCap: Double?

    var isActive: Bool { targetNits != nil }

    /// Standard white before any boost: the current cap. For the scale's top.
    static func currentStandardNits() -> Double? {
        let entry = PanelLightService.findBuiltInFramebuffer()
        guard entry != 0 else { return nil }
        defer { IOObjectRelease(entry) }
        return read(entry, "BLNitsCap")
    }

    /// Starts a boost at `level` (1.0 = standard). False when the panel
    /// cannot be driven.
    func begin(level: Float) -> Bool {
        if framebuffer == 0 { framebuffer = PanelLightService.findBuiltInFramebuffer() }
        guard framebuffer != 0,
              let cap = Self.read(framebuffer, "BLNitsCap"),
              let current = Self.read(framebuffer, "IOMFBBrightnessLevel") else { return false }
        if defaults.object(forKey: Key.savedCap) == nil {
            defaults.set(cap, forKey: Key.savedCap)
            defaults.set(current, forKey: Key.savedLevel)
            defaults.synchronize()
        }
        standardNits = cap
        rewrites = 0
        guard apply(level: level) else {
            end()
            return false
        }
        startTimer()
        return true
    }

    @discardableResult
    func apply(level newLevel: Float) -> Bool {
        level = newLevel
        guard framebuffer != 0, let standardNits,
              let target = DirectPanel.targetNits(standard: standardNits, level: level, ceiling: ceilingNits)
        else { return false }
        targetNits = target
        return write(target)
    }

    /// Puts the boost back after macOS rewrote the backlight. A lower backlight
    /// than standard white means the user dimmed the display; that is left for
    /// the controller, which ends the boost.
    func maintain() {
        guard framebuffer != 0, let target = targetNits,
              let cap = Self.read(framebuffer, "BLNitsCap"),
              let current = Self.read(framebuffer, "IOMFBBrightnessLevel") else { return }
        if let writtenCap, abs(cap - writtenCap) > 1, cap > 50, cap < ceilingNits {
            // macOS set a new standard white (ambient light); follow it.
            standardNits = cap
            logger.notice("standard white now \(cap, privacy: .public) nits")
            apply(level: level)
            rewrites += 1
            return
        }
        if abs(current - target) > 2, current >= (standardNits ?? 0) * 0.95 {
            write(target)
            rewrites += 1
        }
    }

    /// Writes back the values from before the boost.
    func end() {
        timer?.invalidate()
        timer = nil
        if framebuffer == 0 { framebuffer = PanelLightService.findBuiltInFramebuffer() }
        if framebuffer != 0 { _ = Self.restoreSaved(framebuffer, defaults: defaults) }
        targetNits = nil
        writtenCap = nil
        standardNits = nil
    }

    /// After a crash: writes back values a boost left behind.
    static func recoverIfNeeded() {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: Key.savedCap) != nil else { return }
        let entry = PanelLightService.findBuiltInFramebuffer()
        guard entry != 0 else { return }
        defer { IOObjectRelease(entry) }
        _ = restoreSaved(entry, defaults: defaults)
    }

    private static func restoreSaved(_ entry: io_registry_entry_t, defaults: UserDefaults) -> Bool {
        guard let cap = defaults.object(forKey: Key.savedCap) as? Double else { return true }
        let level = (defaults.object(forKey: Key.savedLevel) as? Double) ?? cap
        let ok = set(entry, "IOMFBBrightnessLevel", min(level, cap)) && set(entry, "BLNitsCap", cap)
        if ok {
            defaults.removeObject(forKey: Key.savedCap)
            defaults.removeObject(forKey: Key.savedLevel)
            defaults.synchronize()
        }
        return ok
    }

    @discardableResult
    private func write(_ nits: Double) -> Bool {
        // Cap first, so the level is never above the cap.
        let ok = Self.set(framebuffer, "BLNitsCap", nits) && Self.set(framebuffer, "IOMFBBrightnessLevel", nits)
        if ok { writtenCap = nits }
        return ok
    }

    private func startTimer() {
        timer?.invalidate()
        let next = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.maintain() }
        }
        RunLoop.main.add(next, forMode: .common)
        timer = next
    }

    private static func read(_ entry: io_registry_entry_t, _ key: String) -> Double? {
        guard let value = IORegistryEntryCreateCFProperty(
            entry, key as CFString, kCFAllocatorDefault, 0
        )?.takeRetainedValue() as? NSNumber else { return nil }
        let nits = value.doubleValue / 65536
        return nits.isFinite && nits > 0 ? nits : nil
    }

    private static func set(_ entry: io_registry_entry_t, _ key: String, _ nits: Double) -> Bool {
        guard nits.isFinite, nits > 0, nits <= 1600 else { return false }
        return IORegistryEntrySetCFProperty(
            entry, key as CFString, NSNumber(value: Int64((nits * 65536).rounded()))
        ) == KERN_SUCCESS
    }
}
