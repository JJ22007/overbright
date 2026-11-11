import AppKit
import CoreGraphics
import OSLog

enum BoostSuspensionReason: Hashable {
    case systemSleep
    case screenSleep
    case inactiveSession
}

@MainActor
final class BoostController {
    private static let nativeBrightnessMaximumThreshold: Float = 0.995

    private enum DefaultsKey {
        static let level = "boostLevel"
        static let panelMaximum = "panelBoostMaximum"
        static let recoveryRequired = "recoveryRequired"
        static let savedNativeBrightness = "savedNativeBrightness"
    }

    private let gamma = GammaTableService()
    private let edrTrigger = EDRTriggerService()
    private let nativeBrightness = NativeBrightnessService()
    private let overlay = EDROverlayService()
    private let defaults = UserDefaults.standard
    private let logger = Logger(subsystem: AppInfo.bundleID, category: "Recovery")

    private var wantedActive = false
    private var suspensionReasons: Set<BoostSuspensionReason> = []
    private var savedNativeBrightness: Float?
    private var activeDisplayID: CGDirectDisplayID?
    private var activeColorProfileIdentity: ColorProfileIdentity?
    private var backlightMonitoringEnabled = false
    private var gammaRecoveryHandled = false
    private var engagementGeneration = 0
    private var resumePending = false
    private var integrityTimer: Timer?
    private var backlightObservation = BacklightObservation()
    private var lastObservedBacklight: Float?

    /// The configured boost method.
    var method: BoostMethod = .classic {
        didSet {
            loadPanelMaximum()
            guard method != oldValue, wantedActive, state == .active else { return }
            applyCurrentLevel()
        }
    }

    /// Called when the measured panel ceiling changes the top of the scale.
    var onCeilingChange: (() -> Void)?

    /// The overlay method goes as high as the panel: the ceiling measured at
    /// the last boost (`PanelCeiling`), remembered across launches. The classic
    /// method stays at its calibrated 160%.
    private func loadPanelMaximum() {
        let stored = defaults.object(forKey: DefaultsKey.panelMaximum) as? NSNumber
        BoostLevel.maximum = method == .overlay
            ? max(stored?.floatValue ?? BoostLevel.classicMaximum, BoostLevel.classicMaximum)
            : BoostLevel.classicMaximum
        // A stored level above the old ceiling was clamped at launch.
        if let wanted = (defaults.object(forKey: DefaultsKey.level) as? NSNumber)?.floatValue,
           abs(BoostLevel(wanted).factor - level.factor) > 0.0001 {
            level = BoostLevel(wanted)
        }
    }

    private func panelHeadroomMeasured(_ headroom: Double) {
        guard method == .overlay, let top = PanelCeiling.level(headroom: headroom),
              abs(top - BoostLevel.maximum) >= 0.01 else { return }
        logger.info("panel ceiling \(top, privacy: .public) from headroom \(headroom, privacy: .public)")
        BoostLevel.maximum = top
        defaults.set(top, forKey: DefaultsKey.panelMaximum)
        capDidChange()
        onCeilingChange?()
        publishSnapshot()
    }
    var effectiveMethod: BoostMethod { method }

    /// Longest gap between boost-layer redraws while it is up (overlay method).
    var overlayMaxFrameGap: TimeInterval { overlay.maxFrameGap }

    private(set) var state: BoostState = .off
    private(set) var level: BoostLevel
    var onSnapshot: ((BoostSnapshot) -> Void)?

    init() {
        let stored = defaults.object(forKey: DefaultsKey.level) as? NSNumber
        level = BoostLevel(stored?.floatValue ?? BoostLevel.defaultValue)
        overlay.onHeadroom = { [weak self] headroom in
            MainActor.assumeIsolated { self?.panelHeadroomMeasured(headroom) }
        }

        if let saved = defaults.object(
            forKey: DefaultsKey.savedNativeBrightness
        ) as? NSNumber {
            savedNativeBrightness = saved.floatValue
        }

        let needsRecovery = defaults.bool(forKey: DefaultsKey.recoveryRequired) ||
            savedNativeBrightness != nil
        if needsRecovery {
            defaults.set(true, forKey: DefaultsKey.recoveryRequired)
            defaults.synchronize()
            if !recoverInterruptedSession() {
                state = .unavailable(L10n.tr("Waiting for the built-in display to return to standard brightness", "等待内置显示器恢复标准亮度"))
            }
        }

        startIntegrityTimer()
    }

    deinit {
        integrityTimer?.invalidate()
    }

    var snapshot: BoostSnapshot {
        let screen = DisplayLookup.builtInScreen
        return BoostSnapshot(
            state: state,
            level: level,
            currentEDRHeadroom: Double(
                screen?.maximumExtendedDynamicRangeColorComponentValue ?? 1
            ),
            potentialEDRHeadroom: Double(
                screen?.maximumPotentialExtendedDynamicRangeColorComponentValue ?? 1
            )
        )
    }

    /// True while the user wants the boost, including while it is engaging.
    var isWanted: Bool { wantedActive }

    /// Call after `BoostLevel.cap` changes so a stored level above the new
    /// ceiling comes down to it.
    func capDidChange() {
        if level.factor > BoostLevel.cap {
            setLevel(level.factor)
        }
    }

    func toggle() {
        if wantedActive {
            disable()
        } else {
            enable()
        }
    }

    func enable(raiseBacklight: Bool = true) {
        if wantedActive && state == .active { return }
        backlightObservation.reset()
        resumePending = false
        if level.factor <= BoostLevel.minimum {
            let firstBoostStep = BrightnessKeyStep.nextBoostLevel(
                from: BoostLevel.minimum,
                direction: .increase,
                fineGrained: false
            )
            setLevel(firstBoostStep.factor)
        }

        engagementGeneration += 1
        wantedActive = true
        guard suspensionReasons.isEmpty else {
            setState(.engaging)
            return
        }

        if defaults.bool(forKey: DefaultsKey.recoveryRequired) {
            guard completePendingRecovery() else {
                wantedActive = false
                setState(.unavailable(L10n.tr("Waiting for the built-in display to return to standard brightness", "等待内置显示器恢复标准亮度")))
                return
            }
        }

        guard let screen = DisplayLookup.builtInScreen,
              let displayID = screen.overbrightID else {
            wantedActive = false
            setState(.unavailable(L10n.tr("No built-in display found", "未找到内置显示器")))
            return
        }
        guard screen.maximumPotentialExtendedDynamicRangeColorComponentValue > 1.05 else {
            wantedActive = false
            setState(.unavailable(L10n.tr("The built-in display does not support XDR/EDR", "内置屏幕不支持 XDR/EDR")))
            return
        }

        let generation = engagementGeneration
        setState(.engaging)

        if let endpoint = GammaTableService.readEndpoint(displayID: displayID),
           endpoint > 1.05 {
            failActivation(L10n.tr("Another gamma brightness tool is active; turn it off first", "检测到其他 Gamma 增亮，请先关闭它"))
            return
        }

        activeDisplayID = displayID
        activeColorProfileIdentity = Self.colorProfileIdentity(for: screen)

        if savedNativeBrightness == nil {
            guard let currentBrightness = nativeBrightness.read(displayID: displayID) else {
                failActivation(L10n.tr("Could not read the system backlight level", "无法读取系统背光亮度"))
                return
            }
            savedNativeBrightness = currentBrightness
            defaults.set(currentBrightness, forKey: DefaultsKey.savedNativeBrightness)
            defaults.set(true, forKey: DefaultsKey.recoveryRequired)
            gammaRecoveryHandled = false
            defaults.synchronize()
        }

        // The overlay method never writes a gamma table: on macOS 27.2 a table
        // installed when EDR starts makes white jump to the full backlight.
        guard effectiveMethod == .overlay || gamma.captureBaseline(displayID: displayID) else {
            failActivation(L10n.tr("Could not read the display gamma table", "无法读取屏幕颜色表"))
            return
        }

        guard !raiseBacklight || nativeBrightness.write(1, displayID: displayID) else {
            failActivation(L10n.tr("Could not set the system backlight level", "无法设置系统背光亮度"))
            return
        }
        backlightMonitoringEnabled = true
        lastObservedBacklight = nativeBrightness.read(displayID: displayID)
        guard startEDRLayer(on: screen) else {
            failActivation(L10n.tr("Could not create the EDR layer", "无法创建 EDR 图层"))
            return
        }

        waitForEDR(generation: generation, attemptsRemaining: 80)
    }

    private func startEDRLayer(on screen: NSScreen) -> Bool {
        effectiveMethod == .overlay ? overlay.start(on: screen) : edrTrigger.start(on: screen)
    }

    private func stopEDRLayers() {
        overlay.stop()
        edrTrigger.stop()
    }

    @discardableResult
    func disable() -> Bool {
        resumePending = false
        wantedActive = false
        engagementGeneration += 1
        let restored = restoreDisplay(restoreNativeBrightness: true)
        setState(
            restored
                ? .off
                : .unavailable(L10n.tr("Standard brightness is not restored yet; keep the app running", "标准亮度恢复待处理，请保持应用运行"))
        )
        return restored
    }

    func setLevel(_ proposed: Float) {
        level = BoostLevel(proposed)
        defaults.set(level.factor, forKey: DefaultsKey.level)

        if wantedActive, state == .active {
            applyCurrentLevel()
        } else {
            publishSnapshot()
        }
    }

    func setLevelFromUserInteraction(_ proposed: Float) {
        let proposedLevel = BoostLevel(proposed)
        if proposedLevel.factor <= BoostLevel.minimum {
            setLevel(proposedLevel.factor)
            if wantedActive {
                endBoostAtNativeMaximum()
            }
            return
        }

        let shouldEnable = !wantedActive
        setLevel(proposedLevel.factor)
        if shouldEnable {
            enable()
        }
    }

    func brightnessKeyControlDidBecomeUnavailable() {
        guard wantedActive else { return }
        // Key interception and EDR are independent. A temporarily unavailable tap
        // must not undo a menu-selected boost. Native changes still take priority.
        if let displayID = activeDisplayID {
            _ = verifyNativeBrightnessForBoost(displayID: displayID)
        }
    }

    func displayParametersDidChange() {
        guard wantedActive, suspensionReasons.isEmpty else {
            return
        }

        if resumePending {
            return
        }

        guard backlightMonitoringEnabled,
              let displayID = activeDisplayID else { return }
        _ = verifyNativeBrightnessForBoost(displayID: displayID)
    }

    func suspend(for reason: BoostSuspensionReason) {
        resumePending = false
        let wasUnsuspended = suspensionReasons.isEmpty
        suspensionReasons.insert(reason)
        guard wantedActive, wasUnsuspended else { return }
        engagementGeneration += 1
        let restored = restoreDisplay(restoreNativeBrightness: true)
        if !restored {
            wantedActive = false
        }
        setState(
            restored
                ? .engaging
                : .unavailable(L10n.tr("Waiting for the built-in display to return to standard brightness", "等待内置显示器恢复标准亮度"))
        )
    }

    func resume(from reason: BoostSuspensionReason) {
        guard suspensionReasons.remove(reason) != nil,
              suspensionReasons.isEmpty,
              wantedActive else {
            return
        }
        scheduleResume()
    }

    private func scheduleResume() {
        engagementGeneration += 1
        let generation = engagementGeneration
        resumePending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self,
                  self.wantedActive,
                  self.suspensionReasons.isEmpty,
                  self.engagementGeneration == generation else { return }
            self.resumePending = false
            // Recovery must not overwrite ambient-light or Control Center changes.
            self.enable(raiseBacklight: false)
        }
    }

    func shutdown() {
        resumePending = false
        wantedActive = false
        engagementGeneration += 1
        restoreDisplay(restoreNativeBrightness: true)
    }

    func colorSpaceDidChange(on screen: NSScreen) {
        handleColorProfileChange(on: screen, identity: Self.colorProfileIdentity(for: screen))
    }

    func handleColorProfileChange(on screen: NSScreen, identity currentIdentity: ColorProfileIdentity) {
        guard wantedActive,
              let displayID = screen.overbrightID,
              displayID == activeDisplayID else {
            return
        }

        if let activeColorProfileIdentity,
           activeColorProfileIdentity.matches(currentIdentity) {
            // macOS also emits this notification for transient EDR and display
            // environment refreshes. Keep the boost when the ICC profile itself
            // has not changed.
            return
        }

        let shouldResume = nativeBrightness.read(displayID: displayID).map {
            $0.isFinite && (0...1).contains($0)
        } ?? false
        _ = verifyNativeBrightnessForBoost(displayID: displayID)
        guard wantedActive else { return }
        if let currentBrightness = nativeBrightness.read(displayID: displayID) {
            if currentBrightness < Self.nativeBrightnessMaximumThreshold {
                // A color-profile change must use the ColorSync reset below rather than
                // restoring a gamma table captured under the old profile. Preserve a
                // simultaneous native-brightness change by replacing only its restore target.
                savedNativeBrightness = currentBrightness
                defaults.set(currentBrightness, forKey: DefaultsKey.savedNativeBrightness)
                defaults.set(true, forKey: DefaultsKey.recoveryRequired)
                defaults.synchronize()
            }
        } else {
            // A color-profile change must use the ColorSync reset below rather than
            // the ordinary Gamma path. With no trustworthy live brightness, discard the
            // old target before changing display state so this path cannot overwrite it.
            savedNativeBrightness = nil
            defaults.removeObject(forKey: DefaultsKey.savedNativeBrightness)
            defaults.set(true, forKey: DefaultsKey.recoveryRequired)
            defaults.synchronize()
        }

        wantedActive = false
        activeColorProfileIdentity = nil
        resumePending = false
        backlightMonitoringEnabled = false
        engagementGeneration += 1

        GammaTableService.restoreColorSyncDefaults()
        gammaRecoveryHandled = true
        gamma.discardBaseline()
        stopEDRLayers()

        var nativeBrightnessRestored = true
        if let savedNativeBrightness {
            nativeBrightnessRestored = restoreNativeBrightnessValue(
                savedNativeBrightness
            )
            if nativeBrightnessRestored {
                self.savedNativeBrightness = nil
                defaults.removeObject(forKey: DefaultsKey.savedNativeBrightness)
            }
        }

        defaults.set(
            !nativeBrightnessRestored,
            forKey: DefaultsKey.recoveryRequired
        )
        defaults.synchronize()
        if nativeBrightnessRestored {
            activeDisplayID = nil
            if shouldResume {
                // Rebuild from the NEW ColorSync profile, never reuse the old LUT.
                // Keep the original backlight so a later explicit disable restores it.
                wantedActive = true
                setState(.engaging)
                if suspensionReasons.isEmpty { scheduleResume() }
            } else {
                setState(.off)
            }
        } else {
            setState(.unavailable(L10n.tr("The color profile changed; standard brightness is not restored yet", "颜色配置已改变；标准亮度恢复待处理")))
        }
    }

    private func waitForEDR(generation: Int, attemptsRemaining: Int) {
        guard generation == engagementGeneration, wantedActive else { return }
        guard let displayID = activeDisplayID,
              let screen = DisplayLookup.screen(displayID: displayID) else {
            failActivation(L10n.tr("The built-in display configuration changed", "内置显示器配置已改变"))
            return
        }
        let backlightReady = verifyNativeBrightnessForBoost(displayID: displayID)
        guard wantedActive else { return }

        let currentEDR = screen.maximumExtendedDynamicRangeColorComponentValue
        // The overlay is limited by the headroom as the backlight ramps up, so
        // it can take over at once instead of waiting for the ramp to finish.
        if backlightReady && (currentEDR > 1.05 || effectiveMethod == .overlay) {
            applyCurrentLevel()
            return
        }

        guard attemptsRemaining > 0 else {
            failActivation(L10n.tr("macOS did not enter EDR mode", "macOS 未能进入 EDR 模式"))
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.waitForEDR(
                generation: generation,
                attemptsRemaining: attemptsRemaining - 1
            )
        }
    }

    private func applyCurrentLevel() {
        guard wantedActive,
              suspensionReasons.isEmpty,
              let displayID = activeDisplayID,
              let screen = DisplayLookup.screen(displayID: displayID) else {
            return
        }

        guard verifyNativeBrightnessForBoost(displayID: displayID) else { return }
        let applied = effectiveMethod == .overlay
            ? overlay.show(level: level.factor)
            : gamma.apply(factor: targetFactor(for: screen))

        guard applied else {
            failActivation(L10n.tr("Could not apply the boost", "无法应用屏幕增亮"))
            return
        }
        setState(.active)
    }

    private func failActivation(_ message: String) {
        resumePending = false
        wantedActive = false
        engagementGeneration += 1
        let restored = restoreDisplay(restoreNativeBrightness: true)
        setState(
            .unavailable(
                restored
                    ? message
                    : message + L10n.tr(
                        "; standard brightness is not restored yet",
                        "；标准亮度恢复仍待完成"
                      )
            )
        )
    }

    @discardableResult
    private func restoreDisplay(restoreNativeBrightness: Bool) -> Bool {
        backlightMonitoringEnabled = false
        let gammaRestored = restoreGammaWithFallback()
        stopEDRLayers()

        var nativeBrightnessRestored = true
        if restoreNativeBrightness, let savedNativeBrightness {
            nativeBrightnessRestored = restoreNativeBrightnessValue(
                savedNativeBrightness
            )
            if nativeBrightnessRestored {
                self.savedNativeBrightness = nil
                defaults.removeObject(forKey: DefaultsKey.savedNativeBrightness)
            }
        }

        if gammaRestored {
            gamma.discardBaseline()
        }

        let fullyRestored = gammaRestored && nativeBrightnessRestored
        defaults.set(!fullyRestored, forKey: DefaultsKey.recoveryRequired)
        defaults.synchronize()
        if fullyRestored {
            activeDisplayID = nil
            activeColorProfileIdentity = nil
        }
        return fullyRestored
    }

    private func startIntegrityTimer() {
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.performIntegrityCheck()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        integrityTimer = timer
    }

    private func performIntegrityCheck() {
        guard wantedActive else {
            retryPendingRecovery()
            return
        }
        guard suspensionReasons.isEmpty else { return }
        guard state == .active else {
            publishSnapshot()
            return
        }
        guard let displayID = activeDisplayID,
              let screen = DisplayLookup.screen(displayID: displayID) else {
            failActivation(L10n.tr("The built-in display configuration changed", "内置显示器配置已改变"))
            return
        }

        guard verifyNativeBrightnessForBoost(displayID: displayID) else { return }

        if effectiveMethod == .overlay {
            if overlay.isShowing {
                overlay.follow(screen)
            } else if !overlay.start(on: screen) {
                failActivation(L10n.tr("Could not re-enter EDR mode", "无法恢复 EDR 模式"))
                return
            }
            if overlay.level != level.factor { applyCurrentLevel() }
            publishSnapshot()
            return
        }

        if screen.maximumExtendedDynamicRangeColorComponentValue <= 1.05 {
            guard restoreGammaBeforeRetrigger() else {
                failActivation(L10n.tr("Could not safely restore the display gamma table", "无法安全恢复屏幕颜色表"))
                return
            }
            stopEDRLayers()
            gamma.discardBaseline()
            engagementGeneration += 1
            let generation = engagementGeneration
            guard gamma.captureBaseline(displayID: displayID) else {
                failActivation(L10n.tr("Could not re-read the display gamma table", "无法重新读取屏幕颜色表"))
                return
            }
            gammaRecoveryHandled = false
            guard edrTrigger.start(on: screen) else {
                failActivation(L10n.tr("Could not re-enter EDR mode", "无法恢复 EDR 模式"))
                return
            }
            setState(.engaging)
            waitForEDR(generation: generation, attemptsRemaining: 80)
            return
        }

        let expectedFactor = targetFactor(for: screen)
        let factorChanged = abs(gamma.appliedFactor - expectedFactor) > 0.015
        if factorChanged || !gamma.appearsApplied() {
            applyCurrentLevel()
        }
        publishSnapshot()
    }

    private func targetFactor(for screen: NSScreen) -> Float {
        let currentEDR = Float(
            screen.maximumExtendedDynamicRangeColorComponentValue
        )
        let calibratedFactor = BoostCalibration.gammaFactor(
            level: level,
            currentEDR: currentEDR
        )
        return min(calibratedFactor, max(1, currentEDR))
    }

    private func verifyNativeBrightnessForBoost(
        displayID: CGDirectDisplayID
    ) -> Bool {
        let currentBrightness = nativeBrightness.read(displayID: displayID)
        switch backlightObservation.observe(currentBrightness, now: ProcessInfo.processInfo.systemUptime) {
        case .ready:
            if let currentBrightness {
                if state == .active, let previous = lastObservedBacklight,
                   BuiltInBrightnessScale.backlightDropEndsBoost(previous: previous, current: currentBrightness) {
                    defaults.set("boost ended: backlight lowered to \(currentBrightness)", forKey: "lastBacklightEvent")
                    logger.info("Backlight lowered to \(currentBrightness, privacy: .public) while boosted; boost ended")
                    lastObservedBacklight = currentBrightness
                    endBoostPreservingNativeBrightness(currentBrightness)
                    return false
                }
                if let previous = lastObservedBacklight,
                   abs(currentBrightness - previous) > 0.001 {
                    // Follow native brightness WITHOUT writing it or disabling EDR.
                    // Preserve this newest setting on quit, sleep, and recovery.
                    savedNativeBrightness = currentBrightness
                    defaults.set(currentBrightness, forKey: DefaultsKey.savedNativeBrightness)
                    defaults.set("following native backlight \(currentBrightness)", forKey: "lastBacklightEvent")
                    logger.info("Following native backlight: \(currentBrightness, privacy: .public); boost retained")
                    lastObservedBacklight = currentBrightness
                } else if lastObservedBacklight == nil {
                    lastObservedBacklight = currentBrightness
                }
            }
            return true
        case .pending:
            return false
        case .unavailable:
            stopBoostWithoutChangingNativeBrightness(L10n.tr("Could not confirm the system backlight level; boost turned off", "无法确认系统背光亮度，增亮已关闭"))
            return false
        }
    }

    private func endBoostPreservingNativeBrightness(_ currentBrightness: Float) {
        // A brightness key, Control Center, auto-brightness, or the system itself moved
        // the real backlight. Treat that as the newest user/system intent instead of
        // fighting it on the next integrity pass and making the display jump brighter.
        savedNativeBrightness = currentBrightness
        defaults.set(currentBrightness, forKey: DefaultsKey.savedNativeBrightness)
        defaults.set(true, forKey: DefaultsKey.recoveryRequired)
        defaults.synchronize()
        disable()
    }

    private func stopBoostWithoutChangingNativeBrightness(_ message: String) {
        resumePending = false
        wantedActive = false
        backlightMonitoringEnabled = false
        engagementGeneration += 1

        // The live backlight value is unknown, so discard the old restore target before
        // touching Gamma. A crash from this point can recover ColorSync, but can never
        // guess at and overwrite the user's current hardware brightness.
        savedNativeBrightness = nil
        defaults.removeObject(forKey: DefaultsKey.savedNativeBrightness)
        defaults.set(true, forKey: DefaultsKey.recoveryRequired)
        defaults.synchronize()

        let gammaRestored = restoreGammaWithFallback()
        stopEDRLayers()
        if gammaRestored {
            gamma.discardBaseline()
            activeDisplayID = nil
            activeColorProfileIdentity = nil
        }

        defaults.set(!gammaRestored, forKey: DefaultsKey.recoveryRequired)
        defaults.synchronize()
        setState(
            gammaRestored
                ? .unavailable(message)
                : .unavailable(message + L10n.tr(
                    "; display color is not restored yet",
                    "；屏幕颜色恢复待处理"
                  ))
        )
    }

    private func endBoostAtNativeMaximum() {
        // The native level may have changed since activation (ambient light, etc.).
        // Leaving the boost range must not brighten it back to 100%.
        guard let displayID = activeDisplayID,
              let current = nativeBrightness.read(displayID: displayID) else {
            stopBoostWithoutChangingNativeBrightness(L10n.tr("Could not read the system brightness", "无法读取系统亮度"))
            return
        }
        endBoostPreservingNativeBrightness(current)
    }

    private func cancelPendingResume() {
        resumePending = false
        wantedActive = false
        engagementGeneration += 1
        setState(.off)
    }

    private func restoreGammaBeforeRetrigger() -> Bool {
        restoreGammaWithFallback()
    }

    private func restoreGammaWithFallback() -> Bool {
        if gamma.restore() {
            gammaRecoveryHandled = true
            return true
        }

        if !gamma.baselineDisplayIsOnline {
            if let currentDisplayID = DisplayLookup.builtInScreen?.overbrightID,
               CGDisplayIsOnline(currentDisplayID) != 0,
               gamma.restore(to: currentDisplayID) {
                activeDisplayID = currentDisplayID
                gammaRecoveryHandled = true
                return true
            }
            return false
        }

        if !gammaRecoveryHandled {
            GammaTableService.restoreColorSyncDefaults()
            gammaRecoveryHandled = true
        }
        return gamma.matchesBaseline() || !gamma.baselineDisplayIsOnline
    }

    private func restoreNativeBrightnessValue(_ value: Float) -> Bool {
        if let currentDisplayID = DisplayLookup.builtInScreen?.overbrightID,
           nativeBrightness.write(value, displayID: currentDisplayID) {
            return true
        }

        if let activeDisplayID,
           CGDisplayIsOnline(activeDisplayID) != 0,
           nativeBrightness.write(value, displayID: activeDisplayID) {
            return true
        }
        return false
    }

    private func completePendingRecovery() -> Bool {
        if gamma.hasBaseline {
            return restoreDisplay(restoreNativeBrightness: true)
        }
        return recoverInterruptedSession()
    }

    private func retryPendingRecovery() {
        guard defaults.bool(forKey: DefaultsKey.recoveryRequired) else { return }
        if completePendingRecovery() {
            if state != .off {
                setState(.off)
            }
        } else if state != .unavailable(L10n.tr("Waiting for the built-in display to return to standard brightness", "等待内置显示器恢复标准亮度")) {
            setState(.unavailable(L10n.tr("Waiting for the built-in display to return to standard brightness", "等待内置显示器恢复标准亮度")))
        }
    }

    @discardableResult
    private func recoverInterruptedSession() -> Bool {
        guard DisplayLookup.builtInScreen != nil else { return false }

        if !gammaRecoveryHandled {
            GammaTableService.restoreColorSyncDefaults()
            gammaRecoveryHandled = true
        }

        var nativeBrightnessRestored = true
        if let savedNativeBrightness {
            nativeBrightnessRestored = restoreNativeBrightnessValue(
                savedNativeBrightness
            )
        }

        if nativeBrightnessRestored {
            savedNativeBrightness = nil
            defaults.removeObject(forKey: DefaultsKey.savedNativeBrightness)
            defaults.set(false, forKey: DefaultsKey.recoveryRequired)
            defaults.synchronize()
            activeDisplayID = nil
            activeColorProfileIdentity = nil
        }
        return nativeBrightnessRestored
    }

    // MARK: One scale, 0–160%

    /// Where the built-in display is on the 0–160% scale.
    var scalePercent: Double? {
        guard let id = DisplayLookup.builtInScreen?.overbrightID,
              let backlight = nativeBrightness.read(displayID: id) else { return nil }
        return BuiltInBrightnessScale.percent(backlight: backlight, boost: level, boosting: wantedActive)
    }

    var scaleTop: Double {
        snapshot.potentialEDRHeadroom > 1.05 ? BuiltInBrightnessScale.top : 100
    }

    /// One brightness-key press on the built-in display. Below 100% it steps
    /// the system backlight; above, the boost. Returns the new position.
    func stepScale(_ direction: BrightnessKeyDirection, step: Double) -> Double? {
        guard suspensionReasons.isEmpty, let current = scalePercent else { return nil }
        if resumePending { cancelPendingResume() }
        let next = BuiltInBrightnessScale.next(from: current, direction: direction, step: step, top: scaleTop)
        return setScale(next) ? next : current
    }

    /// Moves the built-in display to a position on the 0–160% scale.
    @discardableResult
    func setScale(_ percent: Double) -> Bool {
        guard suspensionReasons.isEmpty,
              let id = DisplayLookup.builtInScreen?.overbrightID else { return false }
        let target = min(max(percent, 0), scaleTop)
        let (backlight, boost) = BuiltInBrightnessScale.split(target)
        if let boost {
            if wantedActive {
                setLevel(boost)
            } else {
                if let current = nativeBrightness.read(displayID: id), current < 0.999 {
                    nativeBrightness.write(1, displayID: id)
                }
                setLevel(boost)
                enable(raiseBacklight: false)
            }
            return wantedActive
        }
        if wantedActive {
            setLevel(BoostLevel.minimum)
            disable()
        }
        return nativeBrightness.write(backlight, displayID: id)
    }

    private func setState(_ newState: BoostState) {
        if state != newState {
            logger.info("Boost state: \(String(describing: newState), privacy: .public)")
            // Small, persistent breadcrumbs make field failures diagnosable.
            defaults.set(String(describing: newState), forKey: "lastBoostState")
            defaults.set(Date().timeIntervalSince1970, forKey: "lastBoostStateAt")
        }
        state = newState
        publishSnapshot()
    }

    private func publishSnapshot() {
        onSnapshot?(snapshot)
    }

    private static func colorProfileIdentity(
        for screen: NSScreen
    ) -> ColorProfileIdentity {
        ColorProfileIdentity(
            iccProfileData: screen.colorSpace?.iccProfileData,
            fallbackName: screen.colorSpace?.localizedName
        )
    }
}
