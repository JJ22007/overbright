import AppKit
import CoreGraphics
import OSLog

/// How an external display's brightness is controlled, best first.
enum ExternalControl: String {
    /// DDC/CI: the display's own backlight, like its hardware buttons.
    case ddc
    /// macOS's own brightness control (Apple Studio Display, LG UltraFine).
    case native
    /// Gamma dimming. Works on anything, but only darkens the picture.
    case software
}

struct ExternalDisplay: Equatable {
    let id: CGDirectDisplayID
    let name: String
    let control: ExternalControl
    /// Percent. Below zero with extra dimming; see `ExternalBrightness`.
    var level: Double
    /// The lowest level this display can be set to.
    var minimum: Double
}

/// Finds external displays as they are plugged in and adjusts their brightness.
///
/// DDC traffic is slow (tens of milliseconds per message), so it runs on one
/// background queue. Writes are coalesced per display: dragging a slider sends
/// only the newest value once the previous write finishes.
@MainActor
final class ExternalDisplayManager {
    private(set) var displays: [ExternalDisplay] = []

    /// Mirrors `externalDisplays` in the config.
    var isEnabled = true {
        didSet {
            guard isEnabled != oldValue else { return }
            if isEnabled {
                refresh()
            } else {
                dimmers.values.forEach { $0.restore() }
                dimmers = [:]
                displays = []
                onListChange?()
            }
        }
    }

    /// Mirrors `extraDimming` in the config.
    var extraDimming = true {
        didSet {
            guard extraDimming != oldValue else { return }
            for index in displays.indices where displays[index].control != .software {
                displays[index].minimum = ExternalBrightness.minimum(software: false, extraDimming: extraDimming)
                if displays[index].level < displays[index].minimum {
                    setLevel(displays[index].minimum, for: displays[index].id)
                }
            }
            onListChange?()
        }
    }

    /// Displays were connected, disconnected or changed control method.
    var onListChange: (() -> Void)?
    /// One display's level changed.
    var onLevelChange: ((ExternalDisplay) -> Void)?

    private let queue = DispatchQueue(label: "io.github.overbright.ddc")
    private let ddc = DDCService.shared
    private let native = NativeBrightnessService()
    private let defaults = UserDefaults.standard
    private let logger = Logger(subsystem: AppInfo.bundleID, category: "ExternalDisplays")

    private var endpoints: [CGDirectDisplayID: DDCService.Endpoint] = [:]
    private var maxima: [CGDirectDisplayID: UInt16] = [:]
    private var dimmers: [CGDirectDisplayID: SoftwareDimmer] = [:]
    private var pending: [CGDirectDisplayID: Double] = [:]
    private var writing: Set<CGDirectDisplayID> = []
    private var waiters: [CGDirectDisplayID: [() -> Void]] = [:]
    private var lastUserChange: [CGDirectDisplayID: Date] = [:]
    private var refreshGeneration = 0
    private var lastSeenIDs: [CGDirectDisplayID]?
    private var integrityTimer: Timer?

    init() {
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.reapplySoftwareDimming()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        integrityTimer = timer
    }

    // MARK: Discovery

    /// Call when displays may have changed. macOS sends that notification for
    /// many reasons (including EDR changes on the built-in display), so this
    /// only re-detects when the set of external displays really changed, or
    /// when `force` is set (after waking). DDC often needs a moment after a
    /// display appears, so it looks again shortly after.
    func displaysDidChange(force: Bool = false) {
        let ids = Self.onlineExternalDisplays().map(\.id)
        guard force || ids != lastSeenIDs else { return }
        lastSeenIDs = ids
        refresh()
        for delay in [1.5, 4.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.refresh()
            }
        }
    }

    /// Re-detects displays and re-reads their levels, so changes made with the
    /// display's own buttons show up.
    func refresh(completion: (() -> Void)? = nil) {
        guard isEnabled else { completion?(); return }
        refreshGeneration += 1
        let generation = refreshGeneration
        let identities = Self.onlineExternalDisplays()
        let ddc = self.ddc

        queue.async {
            var matched: [CGDirectDisplayID: DDCService.Endpoint] = [:]
            var readings: [CGDirectDisplayID: (current: UInt16, maximum: UInt16)] = [:]
            if ddc.isAvailable, !identities.isEmpty {
                matched = Self.match(identities, to: ddc.discover())
                for (id, endpoint) in matched {
                    if let reading = ddc.readFeature(DDC.brightness, on: endpoint) {
                        readings[id] = reading
                    }
                }
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if generation == self.refreshGeneration {
                        self.finishRefresh(identities.map(\.id), endpoints: matched, readings: readings)
                    }
                    completion?()
                }
            }
        }
    }

    private func finishRefresh(
        _ ids: [CGDirectDisplayID],
        endpoints matched: [CGDirectDisplayID: DDCService.Endpoint],
        readings: [CGDirectDisplayID: (current: UInt16, maximum: UInt16)]
    ) {
        var updated: [ExternalDisplay] = []
        for id in ids {
            let previous = displays.first { $0.id == id }
            let name = Self.screen(for: id)?.localizedName
                ?? matched[id]?.name
                ?? L10n.tr("Display \(id)", "显示器 \(id)")

            let control: ExternalControl
            var level: Double
            if let previous, previous.control == .software, readings[id] == nil {
                // Already known to need software dimming: do not keep asking
                // macOS, and do not re-read the stored level over the live one.
                control = .software
                level = previous.level
                applySoftware(level, to: id)
            } else if let reading = readings[id], let endpoint = matched[id] {
                control = .ddc
                endpoints[id] = endpoint
                maxima[id] = reading.maximum
                level = ExternalBrightness.level(ddcValue: reading.current, maximum: reading.maximum)
            } else if let value = native.read(displayID: id), value.isFinite {
                control = .native
                level = ExternalBrightness.clamp(Double(value) * 100)
            } else {
                control = .software
                level = defaults.object(forKey: softwareKey(id)) as? Double ?? 100
                level = ExternalBrightness.clamp(level, minimum: ExternalBrightness.softwareMinimum)
                applySoftware(level, to: id)
            }
            if control != .ddc {
                endpoints[id] = nil
                maxima[id] = nil
            }
            if let previous, previous.control == control {
                if isBusy(id) {
                    // A reading taken while the user is adjusting is already stale.
                    level = previous.level
                } else if control != .software, previous.level < 0, level <= 0.5 {
                    // The backlight still reads 0: keep the extra dimming on top.
                    level = previous.level
                }
            }
            let minimum = ExternalBrightness.minimum(
                software: control == .software, extraDimming: extraDimming
            )
            level = ExternalBrightness.clamp(level, minimum: minimum)
            if control != .software {
                // Removes extra dimming when the level is back at or above 0,
                // for example after using the display's own buttons.
                applyGamma(ExternalBrightness.split(level).factor, to: id)
            }
            updated.append(ExternalDisplay(id: id, name: name, control: control, level: level, minimum: minimum))
        }

        for id in dimmers.keys where !ids.contains(id) {
            dimmers[id] = nil
        }
        for id in Array(endpoints.keys) where !ids.contains(id) {
            endpoints[id] = nil
            maxima[id] = nil
        }

        let listChanged = updated.map { "\($0.id)|\($0.name)|\($0.control)" }
            != displays.map { "\($0.id)|\($0.name)|\($0.control)" }
        let old = displays
        displays = updated
        if listChanged {
            logger.info("External displays: \(updated.map { "\($0.name) [\($0.control.rawValue)]" }.joined(separator: ", "), privacy: .public)")
            onListChange?()
        } else {
            for display in updated where old.first(where: { $0.id == display.id })?.level != display.level {
                onLevelChange?(display)
            }
        }
    }

    private func isBusy(_ id: CGDirectDisplayID) -> Bool {
        writing.contains(id) || pending[id] != nil ||
            (lastUserChange[id].map { Date().timeIntervalSince($0) < 2 } ?? false)
    }

    // MARK: Adjusting

    /// Sets one display's brightness. `completion` runs once the display has
    /// actually been written to.
    func setLevel(_ proposed: Double, for id: CGDirectDisplayID, completion: (() -> Void)? = nil) {
        guard let index = displays.firstIndex(where: { $0.id == id }) else {
            completion?()
            return
        }
        let level = ExternalBrightness.clamp(proposed, minimum: displays[index].minimum)
        displays[index].level = level
        lastUserChange[id] = Date()
        onLevelChange?(displays[index])

        switch displays[index].control {
        case .software:
            applySoftware(level, to: id)
            defaults.set(level, forKey: softwareKey(id))
            completion?()
        case .native:
            let (hardware, factor) = ExternalBrightness.split(level)
            native.write(Float(hardware / 100), displayID: id)
            applyGamma(factor, to: id)
            completion?()
        case .ddc:
            let (hardware, factor) = ExternalBrightness.split(level)
            applyGamma(factor, to: id)
            pending[id] = hardware
            if let completion {
                waiters[id, default: []].append(completion)
            }
            pump(id)
        }
    }

    /// Sends the newest pending value once the previous write has finished.
    private func pump(_ id: CGDirectDisplayID) {
        guard !writing.contains(id) else { return }
        guard let level = pending.removeValue(forKey: id),
              let endpoint = endpoints[id],
              let maximum = maxima[id] else {
            pending[id] = nil
            waiters.removeValue(forKey: id)?.forEach { $0() }
            return
        }
        writing.insert(id)
        let value = ExternalBrightness.ddcValue(level: level, maximum: maximum)
        let ddc = self.ddc
        queue.async {
            ddc.writeFeature(DDC.brightness, value: value, on: endpoint)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.writing.remove(id)
                    self.pump(id)
                }
            }
        }
    }

    /// The displays a brightness key should change: the external display under
    /// the pointer, or every external display when the pointer is on the
    /// built-in one.
    func keyTargets() -> [ExternalDisplay] {
        let mouse = NSEvent.mouseLocation
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }),
           let id = screen.overbrightID,
           let display = displays.first(where: { $0.id == id }) {
            return [display]
        }
        return displays
    }

    /// Adjusts the key targets by one step. Returns the displays it changed.
    func step(_ direction: BrightnessKeyDirection, by step: Double) -> [ExternalDisplay] {
        guard isEnabled else { return [] }
        return keyTargets().compactMap { display in
            setLevel(
                ExternalBrightness.next(
                    from: display.level, direction: direction, step: step, minimum: display.minimum
                ),
                for: display.id
            )
            return displays.first { $0.id == display.id }
        }
    }

    /// Puts software-dimmed displays back to their real brightness. DDC and
    /// native levels stay, like a setting made with the display's own buttons.
    func restoreSoftwareDimming() {
        dimmers.values.forEach { $0.restore() }
    }

    // MARK: Software dimming

    private func applySoftware(_ level: Double, to id: CGDirectDisplayID) {
        applyGamma(ExternalBrightness.softwareFactor(level: level), to: id)
    }

    /// Gamma dimming on one display; a factor of 1 removes it.
    private func applyGamma(_ factor: Float, to id: CGDirectDisplayID) {
        if factor >= 0.999 {
            dimmers.removeValue(forKey: id)?.restore()
            return
        }
        let dimmer = dimmers[id] ?? SoftwareDimmer(displayID: id)
        dimmers[id] = dimmer
        dimmer.apply(factor)
    }

    /// Anything that resets ColorSync (including Overbright's own recovery of
    /// the built-in display) wipes gamma dimming. Put it back.
    private func reapplySoftwareDimming() {
        for dimmer in dimmers.values where dimmer.wasReset() {
            dimmer.reapply()
        }
    }

    private func softwareKey(_ id: CGDirectDisplayID) -> String {
        "softwareLevel.\(CGDisplayVendorNumber(id)).\(CGDisplayModelNumber(id)).\(CGDisplaySerialNumber(id))"
    }

    // MARK: Matching displays to DDC endpoints

    struct Identity: Sendable {
        let id: CGDirectDisplayID
        let vendor: UInt32
        let model: UInt32
        let serial: UInt32
    }

    static func onlineExternalDisplays() -> [Identity] {
        var count: UInt32 = 0
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        guard CGGetActiveDisplayList(16, &ids, &count) == .success else { return [] }
        return ids.prefix(Int(count))
            .filter { CGDisplayIsBuiltin($0) == 0 }
            .map {
                Identity(
                    id: $0,
                    vendor: CGDisplayVendorNumber($0),
                    model: CGDisplayModelNumber($0),
                    serial: CGDisplaySerialNumber($0)
                )
            }
    }

    /// Pairs displays with endpoints by EDID vendor, model and serial number.
    /// Two identical displays without serials are paired in registry order.
    nonisolated static func match(
        _ identities: [Identity],
        to endpoints: [DDCService.Endpoint]
    ) -> [CGDirectDisplayID: DDCService.Endpoint] {
        var remaining = endpoints
        var result: [CGDirectDisplayID: DDCService.Endpoint] = [:]
        for exact in [true, false] {
            for identity in identities where result[identity.id] == nil {
                guard let index = remaining.firstIndex(where: { endpoint in
                    endpoint.vendor == identity.vendor && endpoint.model == identity.model &&
                        (!exact || endpoint.serial == identity.serial)
                }) else { continue }
                result[identity.id] = remaining.remove(at: index)
            }
        }
        // One display and one endpoint left over: they belong together even if
        // a dock or adapter rewrote the identity.
        let unmatched = identities.filter { result[$0.id] == nil }
        if unmatched.count == 1, remaining.count == 1 {
            result[unmatched[0].id] = remaining[0]
        }
        return result
    }

    static func screen(for id: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first { $0.overbrightID == id }
    }
}

/// Gamma dimming for one display, restored from its own baseline. It never calls
/// `CGDisplayRestoreColorSyncSettings`, which would also reset the built-in
/// display's boost.
@MainActor
final class SoftwareDimmer {
    private let displayID: CGDirectDisplayID
    private var baseline: (red: [CGGammaValue], green: [CGGammaValue], blue: [CGGammaValue])?
    private(set) var factor: Float = 1

    init(displayID: CGDirectDisplayID) {
        self.displayID = displayID
    }

    func apply(_ newFactor: Float) {
        if baseline == nil {
            baseline = readTable()
        }
        guard let baseline else { return }
        var red = baseline.red.map { $0 * newFactor }
        var green = baseline.green.map { $0 * newFactor }
        var blue = baseline.blue.map { $0 * newFactor }
        if CGSetDisplayTransferByTable(displayID, UInt32(red.count), &red, &green, &blue) == .success {
            factor = newFactor
        }
    }

    func restore() {
        guard var table = baseline else { return }
        _ = CGSetDisplayTransferByTable(displayID, UInt32(table.red.count), &table.red, &table.green, &table.blue)
        factor = 1
    }

    /// True when the live table no longer carries our dimming.
    func wasReset() -> Bool {
        guard factor < 0.999, let baseline, let expected = baseline.red.last,
              let actual = readTable()?.red.last else { return false }
        return abs(actual - expected * factor) > 0.02
    }

    /// The table was replaced (a ColorSync reset or a new color profile): take
    /// it as the new baseline and dim again.
    func reapply() {
        baseline = readTable()
        apply(factor)
    }

    private func readTable() -> (red: [CGGammaValue], green: [CGGammaValue], blue: [CGGammaValue])? {
        let capacity: UInt32 = 256
        var red = [CGGammaValue](repeating: 0, count: Int(capacity))
        var green = red
        var blue = red
        var count: UInt32 = 0
        guard CGGetDisplayTransferByTable(displayID, capacity, &red, &green, &blue, &count) == .success,
              count > 0 else { return nil }
        let n = Int(count)
        return (Array(red.prefix(n)), Array(green.prefix(n)), Array(blue.prefix(n)))
    }
}
