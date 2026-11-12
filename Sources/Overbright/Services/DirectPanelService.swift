import Foundation
import IOKit
import os

/// The direct boost: drives the built-in panel's backlight past standard white
/// through the framebuffer's `BLNitsCap` (the most macOS lets the backlight
/// reach for ordinary content) and `IOMFBBrightnessLevel` (the backlight now),
/// both 16.16 fixed-point nits. No window, no gamma table, no EDR.
///
/// Every number comes from the panel itself (`PanelSupport`): standard white,
/// the peak that bounds every write, and the ceiling as a share of the peak.
/// A write that macOS does not take is reported as a failure, so the
/// controller can fall back to the overlay method.
///
/// Measured on a 14" MacBook Pro, macOS 27.2: writes are accepted and the
/// backlight's power follows (6.8 W at 600 nits, 10.8 W at 800, 12.5 W at
/// 1000). macOS rewrites both values whenever it adjusts the backlight itself
/// (ambient light, a brightness change); `maintain()` follows macOS until its
/// values settle, then puts the boost back. The panel's own thermal limit is left alone.
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
    /// `maxNits` from the config; `ceilingNits` bounds it by this panel's peak.
    var configuredCeiling: Double = DirectPanel.defaultCeiling
    var ceilingNits: Double { PanelSupport.ceiling(configured: configuredCeiling, peakNits: peakNits) }
    /// The panel's peak, read at `begin`; nothing is ever written above it.
    private var peakNits: Double?
    private var level: Float = 1
    private var writtenCap: Double?

    var isActive: Bool { targetNits != nil }

    /// Starts a boost at `level` (1.0 = standard). False when this panel
    /// cannot be driven: no XDR peak to bound the writes, no way to tell
    /// standard white, or macOS did not take the first write.
    func begin(level: Float, readings: PanelReadings) -> Bool {
        guard PanelSupport.canDriveDirectly(readings),
              let standard = PanelSupport.standardWhite(readings) else {
            logger.notice("direct method not available on this panel")
            return false
        }
        if framebuffer == 0 { framebuffer = PanelLightService.findBuiltInFramebuffer() }
        guard framebuffer != 0,
              let cap = Self.read(framebuffer, "BLNitsCap"),
              let current = Self.read(framebuffer, "IOMFBBrightnessLevel") else { return false }
        if defaults.object(forKey: Key.savedCap) == nil {
            defaults.set(cap, forKey: Key.savedCap)
            defaults.set(current, forKey: Key.savedLevel)
            defaults.synchronize()
        }
        peakNits = readings.peakNits
        standardNits = standard
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

    /// macOS's last values that differ from ours, and when they last changed.
    private var systemCap: Double?
    private var systemLevel: Double?
    private var systemChangedAt: TimeInterval = 0

    /// How long macOS's values must stay unchanged before the boost goes back.
    /// macOS ramps the backlight in small steps over a second or more (ambient
    /// light, automatic brightness); writing over every step made the screen
    /// flicker between bright and dark. Following macOS until it settles turns
    /// each adjustment into one short dip.
    static let settleTime: TimeInterval = 1.0

    /// Puts the boost back after macOS rewrote the backlight, once macOS has
    /// settled. A backlight below standard white means the user dimmed the
    /// display; that is left for the controller, which ends the boost.
    func maintain() {
        guard framebuffer != 0, let target = targetNits,
              let cap = Self.read(framebuffer, "BLNitsCap"),
              let current = Self.read(framebuffer, "IOMFBBrightnessLevel") else { return }
        let ours = abs(current - target) <= 2 && abs(cap - (writtenCap ?? target)) <= 2
        guard !ours else {
            systemCap = nil
            systemLevel = nil
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        if systemCap.map({ abs($0 - cap) > 0.5 }) ?? true || systemLevel.map({ abs($0 - current) > 0.5 }) ?? true {
            systemCap = cap
            systemLevel = current
            systemChangedAt = now
            return
        }
        guard now - systemChangedAt >= Self.settleTime else { return }
        let decision = DirectPanel.settled(cap: cap, level: current, writtenCap: writtenCap,
                                           standard: standardNits, ceiling: ceilingNits, peak: peakNits)
        guard decision.reapply else { return }
        if let newStandard = decision.newStandard {
            standardNits = newStandard
            logger.notice("standard white now \(newStandard, privacy: .public) nits")
        }
        apply(level: level)
        rewrites += 1
        systemCap = nil
        systemLevel = nil
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
        peakNits = nil
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
        // These are macOS's own values from before the boost, so they bound themselves.
        let limit = max(PanelLightService.nits(entry, "limit_max_physical_brightness") ?? 0, cap)
        let ok = set(entry, "IOMFBBrightnessLevel", min(level, cap), limit: limit)
            && set(entry, "BLNitsCap", cap, limit: limit)
        if ok {
            defaults.removeObject(forKey: Key.savedCap)
            defaults.removeObject(forKey: Key.savedLevel)
            defaults.synchronize()
        }
        return ok
    }

    @discardableResult
    private func write(_ nits: Double) -> Bool {
        // Cap first, so the level is never above the cap. Without a known XDR
        // peak there is no bound, and nothing is written.
        guard let limit = PanelSupport.writeLimit(peakNits: peakNits),
              Self.set(framebuffer, "BLNitsCap", nits, limit: limit),
              Self.set(framebuffer, "IOMFBBrightnessLevel", nits, limit: limit) else { return false }
        // A model or macOS version that ignores the write must not count as boosted.
        guard let readBack = Self.read(framebuffer, "BLNitsCap"), abs(readBack - nits) <= 2 else {
            logger.notice("BLNitsCap write of \(nits, privacy: .public) not taken")
            return false
        }
        writtenCap = nits
        return true
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

    /// Writes `nits`, never above `limit`.
    private static func set(_ entry: io_registry_entry_t, _ key: String, _ nits: Double, limit: Double) -> Bool {
        guard nits.isFinite, nits > 0, nits <= limit else { return false }
        return IORegistryEntrySetCFProperty(
            entry, key as CFString, NSNumber(value: Int64((nits * 65536).rounded()))
        ) == KERN_SUCCESS
    }
}
