import AppKit
import Darwin

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private enum DefaultsKey {
        static let brightnessKeysPromptedBuild = "brightnessKeysPromptedBuild"
        static let dimAll = "dimAllEntries"
    }

    private var instanceLock: InstanceLock?
    private var boostController: BoostController?
    private var brightnessKeyService: BrightnessKeyService?
    private var statusController: StatusItemController?
    private var commandServer: CommandServer?
    private var externalDisplays: ExternalDisplayManager?
    private var hud: BrightnessHUD?
    private let scaleHUD = ScaleHUD()
    private var signalSources: [DispatchSourceSignal] = []
    private var brightnessKeyHealthTimer: Timer?
    private var brightnessKeysWereRunning = false
    private let batteryMonitor = BatteryMonitor()
    private var lastBattery: LowBattery.Reading?
    private let shortcutService = ShortcutService(id: 1)
    private let dimShortcutService = ShortcutService(id: 2)
    private var dimAll = DimAll(
        stored: UserDefaults.standard.dictionary(forKey: DefaultsKey.dimAll) as? [String: [Double]] ?? [:]
    )

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let instanceLock = InstanceLock.acquire() else {
            NSApp.terminate(nil)
            return
        }
        self.instanceLock = instanceLock

        ProcessInfo.processInfo.disableSuddenTermination()
        ProcessInfo.processInfo.disableAutomaticTermination("Menu bar brightness control")
        NSApp.setActivationPolicy(.accessory)

        // Settings come first: the controller reads its ceiling and language.
        ConfigStore.shared.load()
        applyConfigToModels()

        let boostController = BoostController()
        boostController.directCeiling = ConfigStore.shared.config.maxNits
        boostController.holdHeadroom = ConfigStore.shared.config.holdHeadroom
        boostController.configuredMethod = ConfigStore.shared.config.configuredBoostMethod
        boostController.onCeilingChange = { [weak self] in self?.statusController?.rebuildMenu() }
        self.boostController = boostController

        let brightnessKeyService = BrightnessKeyService { [weak self] direction, fineGrained in
            self?.handleBuiltInKey(direction, fineGrained: fineGrained) != nil
        }
        self.brightnessKeyService = brightnessKeyService

        let externalDisplays = ExternalDisplayManager()
        externalDisplays.isEnabled = ConfigStore.shared.config.externalDisplays
        externalDisplays.extraDimming = ConfigStore.shared.config.extraDimming
        self.externalDisplays = externalDisplays
        let hud = BrightnessHUD()
        self.hud = hud
        brightnessKeyService.externalHandler = { [weak self] direction, fineGrained in
            self?.adjustExternalDisplays(direction, fineGrained: fineGrained) ?? false
        }

        let statusController = StatusItemController(
            boostController: boostController,
            brightnessKeyService: brightnessKeyService,
            externalDisplays: externalDisplays
        )
        self.statusController = statusController
        statusController.dimHandler = { [weak self] in self?.toggleDimAll() }
        statusController.isDimmed = dimAll.isDimmed
        externalDisplays.onListChange = { [weak statusController] in
            statusController?.rebuildMenu()
        }
        externalDisplays.onLevelChange = { [weak statusController] display in
            statusController?.renderExternal(display)
        }
        externalDisplays.displaysDidChange()

        brightnessKeyService.isEnabled = ConfigStore.shared.config.brightnessKeys

        let commandServer = CommandServer(
            boostController: boostController,
            brightnessKeyService: brightnessKeyService,
            externalDisplays: externalDisplays
        )
        commandServer.keyHandler = { [weak self] direction, fine in
            self?.handleBuiltInKey(direction, fineGrained: fine)
        }
        commandServer.dimHandler = { [weak self] in self?.toggleDimAll() ?? [:] }
        commandServer.isDimmed = { [weak self] in self?.dimAll.isDimmed ?? false }
        commandServer.start()
        self.commandServer = commandServer

        ConfigStore.shared.onChange = { [weak self] in
            self?.configDidChange()
        }
        ConfigStore.shared.startWatching()

        batteryMonitor.onChange = { [weak self] reading in self?.batteryDidChange(reading) }
        shortcutService.onPress = { [weak self] in self?.boostController?.toggle() }
        dimShortcutService.onPress = { [weak self] in self?.toggleDimAll() }
        applyAutomation()

        installLifecycleObservers()
        installSignalHandlers()
        configureBrightnessKeys()

        if ConfigStore.shared.config.enableOnLaunch {
            boostController.enable()
        }

        if CommandLine.arguments.contains("--auto-enable-for-test") {
            let requestedLevel = Float(
                ProcessInfo.processInfo.environment["OVERBRIGHT_TEST_LEVEL"] ?? ""
            ) ?? 1.25
            boostController.setLevel(requestedLevel)
            boostController.enable()
        }
    }

    /// Pushes config values into the plain model types that use them.
    private func applyConfigToModels() {
        let config = ConfigStore.shared.config
        L10n.language = config.language
        BoostLevel.userCap = config.maxLevel.map { Float($0 / 100) } ?? BoostLevel.absoluteMaximum
        BrightnessKeyStep.coarse = Float(config.keyStep / 100)
        BrightnessKeyStep.fine = Float(config.fineKeyStep / 100)
    }

    /// The config file was saved. Everything it controls is applied here.
    private func configDidChange() {
        applyConfigToModels()
        boostController?.directCeiling = ConfigStore.shared.config.maxNits
        boostController?.holdHeadroom = ConfigStore.shared.config.holdHeadroom
        boostController?.configuredMethod = ConfigStore.shared.config.configuredBoostMethod
        externalDisplays?.isEnabled = ConfigStore.shared.config.externalDisplays
        externalDisplays?.extraDimming = ConfigStore.shared.config.extraDimming
        boostController?.capDidChange()
        brightnessKeyService?.isEnabled = ConfigStore.shared.config.brightnessKeys
        brightnessKeyService?.start()
        applyAutomation()
        statusController?.rebuildMenu()
    }

    /// `lowBatteryOff` and `toggleShortcut` are off unless configured;
    /// `dimShortcut` is on unless turned off.
    private func applyAutomation() {
        let config = ConfigStore.shared.config
        if config.lowBatteryOff != nil {
            batteryMonitor.start()
        } else {
            batteryMonitor.stop()
            lastBattery = nil
        }
        let shortcut = config.toggleShortcut.flatMap(Shortcut.parse)
        if !shortcutService.register(shortcut), let text = config.toggleShortcut {
            NSLog("Overbright: macOS refused the shortcut \(text); another app may use it")
        }
        let dimShortcut = config.dimShortcut.flatMap(Shortcut.parse)
        if !dimShortcutService.register(dimShortcut), let text = config.dimShortcut {
            NSLog("Overbright: macOS refused the shortcut \(text); another app may use it")
        }
    }

    /// `dimShortcut`, the menu item and `overbright dim`: every display down
    /// to `dimLevel`, or back where it was. Returns the levels it wrote.
    ///
    /// The built-in display moves along its one scale, so a boost ends on the
    /// way down and comes back on the way up, each through the same single
    /// write as a brightness key.
    @discardableResult
    func toggleDimAll() -> [String: Double] {
        guard let boostController else { return [:] }
        let config = ConfigStore.shared.config
        var current: [String: Double] = [:]
        var minimums: [String: Double] = [:]
        if let percent = boostController.scalePercent {
            current[DimAll.builtInKey] = percent
        }
        for display in externalDisplays?.displays ?? [] {
            current[String(display.id)] = display.level
            minimums[String(display.id)] = display.minimum
        }

        var written = dimAll.press(current: current, minimums: minimums, dimLevel: config.dimLevel)
        for (key, level) in written {
            if key == DimAll.builtInKey {
                if boostController.setScale(level) {
                    if config.showHUD { scaleHUD.show(percent: level, top: boostController.scaleTop) }
                } else {
                    dimAll.forget(key)
                    written[key] = nil
                }
            } else if let id = CGDirectDisplayID(key), let externalDisplays {
                externalDisplays.setLevel(level, for: id)
                if config.showHUD, let display = externalDisplays.displays.first(where: { $0.id == id }) {
                    hud?.show(display)
                }
            }
        }
        UserDefaults.standard.set(dimAll.stored, forKey: DefaultsKey.dimAll)
        statusController?.isDimmed = dimAll.isDimmed
        return written
    }

    private func batteryDidChange(_ reading: LowBattery.Reading) {
        defer { lastBattery = reading }
        guard let threshold = ConfigStore.shared.config.lowBatteryOff, let boostController else { return }
        let boosted = boostController.state == .active || boostController.state == .engaging
        if LowBattery.shouldTurnOff(previous: lastBattery, current: reading, threshold: threshold, boosted: boosted) {
            boostController.disable()
        }
    }

    /// F1/F2 on the built-in display: one step along the 0–160% scale, with
    /// Overbright's indicator as the only one. Returns the new position, or nil
    /// to leave the key to macOS.
    @discardableResult
    func handleBuiltInKey(_ direction: BrightnessKeyDirection, fineGrained: Bool) -> Double? {
        let config = ConfigStore.shared.config
        guard let boostController,
              let percent = boostController.stepScale(
                direction,
                step: fineGrained ? config.fineKeyStep : config.keyStep
              ) else { return nil }
        if config.showHUD {
            scaleHUD.show(percent: percent, top: boostController.scaleTop)
        }
        return percent
    }

    /// Control+F1/F2. Returns false (so macOS keeps the key) when there is no
    /// external display or the feature is off.
    private func adjustExternalDisplays(_ direction: BrightnessKeyDirection, fineGrained: Bool) -> Bool {
        let config = ConfigStore.shared.config
        guard config.externalDisplays, config.externalKeys,
              let externalDisplays, !externalDisplays.displays.isEmpty else { return false }
        let changed = externalDisplays.step(
            direction,
            by: fineGrained ? config.fineKeyStep : config.keyStep
        )
        if config.showHUD {
            changed.forEach { hud?.show($0) }
        }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        externalDisplays?.restoreSoftwareDimming()
        brightnessKeyService?.stop()
        boostController?.shutdown()
    }

    private func installLifecycleObservers() {
        let center = NSWorkspace.shared.notificationCenter

        center.addObserver(
            self,
            selector: #selector(systemWillSleep),
            name: NSWorkspace.willSleepNotification,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenColorSpaceDidChange),
            name: NSScreen.colorSpaceDidChangeNotification,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(displayParametersDidChange),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )

        center.addObserver(
            self,
            selector: #selector(screenWillSleep),
            name: NSWorkspace.screensDidSleepNotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(systemDidWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(screenDidWake),
            name: NSWorkspace.screensDidWakeNotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(sessionDidResignActive),
            name: NSWorkspace.sessionDidResignActiveNotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(sessionDidBecomeActive),
            name: NSWorkspace.sessionDidBecomeActiveNotification,
            object: nil
        )
    }

    private func installSignalHandlers() {
        for signalNumber in [SIGTERM, SIGINT, SIGHUP] {
            Darwin.signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
            source.setEventHandler { [weak self] in
                self?.externalDisplays?.restoreSoftwareDimming()
                self?.brightnessKeyService?.stop()
                self?.boostController?.shutdown()
                NSApp.terminate(nil)
            }
            source.resume()
            signalSources.append(source)
        }
    }

    @objc private func systemWillSleep() {
        boostController?.suspend(for: .systemSleep)
    }

    @objc private func systemDidWake() {
        boostController?.resume(from: .systemSleep)
        externalDisplays?.displaysDidChange(force: true)
    }

    @objc private func screenWillSleep() {
        boostController?.suspend(for: .screenSleep)
    }

    @objc private func screenDidWake() {
        boostController?.resume(from: .screenSleep)
    }

    @objc private func sessionDidResignActive() {
        boostController?.suspend(for: .inactiveSession)
    }

    @objc private func sessionDidBecomeActive() {
        boostController?.resume(from: .inactiveSession)
    }

    @objc private func screenColorSpaceDidChange(_ notification: Notification) {
        guard let screen = notification.object as? NSScreen else { return }
        boostController?.colorSpaceDidChange(on: screen)
    }

    @objc private func displayParametersDidChange() {
        boostController?.displayParametersDidChange()
        externalDisplays?.displaysDidChange()
    }

    private func configureBrightnessKeys() {
        guard let brightnessKeyService else { return }
        let started = brightnessKeyService.start()

        let skipPrompt = ProcessInfo.processInfo.environment[
            "OVERBRIGHT_SKIP_ACCESSIBILITY_PROMPT"
        ] == "1"
        let currentBuild = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleVersion"
        ) as? String ?? "unbundled"
        if !started,
           brightnessKeyService.isEnabled,
           !skipPrompt,
           UserDefaults.standard.string(
            forKey: DefaultsKey.brightnessKeysPromptedBuild
           ) != currentBuild {
            UserDefaults.standard.set(
                currentBuild,
                forKey: DefaultsKey.brightnessKeysPromptedBuild
            )
            UserDefaults.standard.synchronize()
            BrightnessKeyService.requestAccessibilityPermission()
        }

        brightnessKeysWereRunning = started
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.checkBrightnessKeyHealth()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        brightnessKeyHealthTimer = timer
    }

    private func checkBrightnessKeyHealth() {
        guard let brightnessKeyService else { return }
        let runningNow = brightnessKeyService.start()
        if brightnessKeysWereRunning && !runningNow {
            boostController?.brightnessKeyControlDidBecomeUnavailable()
        }
        brightnessKeysWereRunning = runningNow
        statusController?.refreshBrightnessKeyStatus()
    }
}
