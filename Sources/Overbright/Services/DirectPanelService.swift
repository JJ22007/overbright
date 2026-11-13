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
/// 1000). The panel's own thermal limit is left alone.
///
/// macOS rewrites both values whenever it adjusts the backlight itself: with
/// ambient light, and every time HDR content appears or leaves (a system
/// banner on macOS 27 is HDR content with a headroom of 1.2; that happened
/// 145 times in one working day). It writes a ramp, one step per frame for one
/// to two seconds. `maintain()` follows that ramp step by step: each time it
/// finds macOS's values it writes the boost again, computed from the cap macOS
/// just set (`DirectPanel.backlight`). Waiting for macOS to settle first, as
/// earlier versions did, left the screen at standard brightness for two to
/// three seconds at each end of every HDR appearance.
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
    private var timer: DispatchSourceTimer?

    /// Standard white in nits: ordinary white without the boost.
    private(set) var standardNits: Double?
    /// The cap macOS itself last set: standard white, times the headroom it
    /// has opened for HDR content.
    private(set) var systemCap: Double?
    /// The backlight the boost wants now. Equal to `systemCap` while macOS's
    /// own backlight is already as high as the boost may go (HDR video).
    private(set) var targetNits: Double?
    /// How many times macOS took the backlight over and the boost was put back.
    private(set) var rewrites = 0
    /// `maxNits` from the config; `ceilingNits` bounds it by this panel's peak.
    var configuredCeiling: Double = DirectPanel.defaultCeiling
    var ceilingNits: Double { PanelSupport.ceiling(configured: configuredCeiling, peakNits: peakNits) }
    /// The most the backlight itself is ever written, HDR headroom included.
    private var hardCeiling: Double {
        PanelSupport.ceiling(configured: DirectPanel.ceilingRange.upperBound, peakNits: peakNits)
    }
    /// The panel's peak, read at `begin`; nothing is ever written above it.
    private var peakNits: Double?
    private var level: Float = 1
    /// What the boost last wrote; nil while macOS's own values are left alone.
    private var written: Double?

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
              Self.read(framebuffer, "IOMFBBrightnessLevel") != nil else { return false }
        if defaults.object(forKey: Key.savedCap) == nil {
            defaults.set(cap, forKey: Key.savedCap)
            defaults.synchronize()
        }
        peakNits = readings.peakNits
        standardNits = standard
        systemCap = cap
        written = nil
        rewrites = 0
        self.level = level
        // macOS may be in the middle of a ramp and write over the first try.
        guard (0..<3).contains(where: { _ in apply(level: level) }) else {
            end()
            return false
        }
        startTimer()
        return true
    }

    @discardableResult
    func apply(level newLevel: Float) -> Bool {
        level = newLevel
        guard framebuffer != 0, let standardNits, let systemCap,
              let target = DirectPanel.backlight(standard: standardNits, systemCap: systemCap, level: level,
                                                 ceiling: ceilingNits, hardCeiling: hardCeiling)
        else { return false }
        targetNits = target
        guard target > systemCap + 0.5 else {
            // Nothing to add: macOS's own backlight stands. Hand it back if
            // the boost's values are still on the panel.
            defer { written = nil }
            return written == nil || write(systemCap)
        }
        return write(target)
    }

    /// How long macOS's values must stay unchanged before its ramp counts as over.
    static let settleTime: TimeInterval = 1.0
    /// How often the backlight is checked: while macOS is writing a ramp (it
    /// writes once per frame, every 8 ms at 120 Hz), and otherwise.
    static let followInterval: TimeInterval = 0.002
    static let idleInterval: TimeInterval = 0.02

    private var lastCap: Double?
    private var lastLevel: Double?
    private var changedAt: TimeInterval = 0
    private var following = false

    /// Puts the boost back whenever macOS has written the backlight, at once
    /// and from the cap macOS just set, so the screen keeps its brightness
    /// through macOS's ramps. A backlight below what macOS allows means the
    /// user dimmed the display; that is left for the controller, which ends
    /// the boost.
    func maintain() {
        guard framebuffer != 0, targetNits != nil,
              let cap = Self.read(framebuffer, "BLNitsCap"),
              let current = Self.read(framebuffer, "IOMFBBrightnessLevel") else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if lastCap != cap || lastLevel != current {
            lastCap = cap
            lastLevel = current
            changedAt = now
        }
        let capIsOurs = written.map { abs(cap - $0) <= 0.02 } ?? false
        let levelIsOurs = written.map { abs(current - $0) <= 0.02 } ?? false
        if !capIsOurs, systemCap.map({ abs($0 - cap) > 0.02 }) ?? true {
            systemCap = cap
        }
        let quiet = now - changedAt >= Self.settleTime
        if following, quiet {
            // macOS's ramp is over: its headroom can be trusted now.
            following = false
            countedTakeover = false
            setPace(Self.idleInterval)
            if updateStandard() {
                apply(level: level)
                return
            }
        } else if !following, !quiet {
            following = true
            setPace(Self.followInterval)
        }
        if capIsOurs, levelIsOurs { return }
        if !levelIsOurs, let systemCap, let standardNits,
           DirectPanel.dimmed(level: current, systemCap: systemCap, standard: standardNits) { return }
        apply(level: level)
        // Counted once per takeover, not once per step of macOS's ramp.
        if written != nil, !countedTakeover {
            countedTakeover = true
            rewrites += 1
        }
    }

    private var countedTakeover = false

    /// Reads standard white again once macOS's ramp is over. True if it changed.
    private func updateStandard() -> Bool {
        guard let systemCap, let previous = standardNits else { return false }
        let next = DirectPanel.standard(previous: previous, systemCap: systemCap,
                                        headroom: PanelLightService.edrHeadroom(),
                                        ceiling: ceilingNits, peak: peakNits)
        guard abs(next - previous) >= 0.5 else { return false }
        standardNits = next
        logger.notice("standard white now \(next, privacy: .public) nits")
        return true
    }

    /// Writes back the values from before the boost.
    func end() {
        timer?.cancel()
        timer = nil
        if framebuffer == 0 { framebuffer = PanelLightService.findBuiltInFramebuffer() }
        if framebuffer != 0 {
            _ = Self.restoreSaved(framebuffer, defaults: defaults, systemCap: systemCap, untouched: written == nil && isActive)
        }
        targetNits = nil
        written = nil
        standardNits = nil
        systemCap = nil
        peakNits = nil
        following = false
        countedTakeover = false
        lastCap = nil
        lastLevel = nil
    }

    /// After a crash: writes back values a boost left behind.
    static func recoverIfNeeded() {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: Key.savedCap) != nil else { return }
        let entry = PanelLightService.findBuiltInFramebuffer()
        guard entry != 0 else { return }
        defer { IOObjectRelease(entry) }
        _ = restoreSaved(entry, defaults: defaults, systemCap: nil, untouched: false)
    }

    /// `systemCap` is the cap macOS itself last set, when a running boost
    /// knows it: with HDR content on screen that is what macOS expects to
    /// find, not standard white. `untouched` means the boost never wrote over
    /// macOS's values, so there is nothing to put back.
    private static func restoreSaved(_ entry: io_registry_entry_t, defaults: UserDefaults,
                                     systemCap: Double?, untouched: Bool) -> Bool {
        guard defaults.object(forKey: Key.savedCap) != nil else { return true }
        func forget() {
            defaults.removeObject(forKey: Key.savedCap)
            defaults.removeObject(forKey: Key.savedLevel)
            defaults.synchronize()
        }
        if untouched {
            forget()
            return true
        }
        let peak = PanelLightService.nits(entry, "limit_max_physical_brightness")
        guard let values = DirectPanel.restore(
            savedCap: defaults.object(forKey: Key.savedCap) as? Double,
            systemStandard: systemCap ?? PanelLightService.systemStandardNits(),
            currentLevel: read(entry, "IOMFBBrightnessLevel"),
            peak: peak
        ) else { return false }
        // Standard white is below the cap we wrote, so the level comes down first.
        let limit = max(peak ?? 0, values.cap)
        let ok = (values.level.map { set(entry, "IOMFBBrightnessLevel", $0, limit: limit) } ?? true)
            && set(entry, "BLNitsCap", values.cap, limit: limit)
        if ok { forget() }
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
        written = nits
        return true
    }

    private func startTimer() {
        timer?.cancel()
        let next = DispatchSource.makeTimerSource(flags: .strict, queue: .main)
        next.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.maintain() }
        }
        timer = next
        following = false
        setPace(Self.idleInterval)
        next.resume()
    }

    private func setPace(_ interval: TimeInterval) {
        timer?.schedule(deadline: .now() + interval, repeating: interval, leeway: .nanoseconds(0))
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
