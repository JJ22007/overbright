import AppKit
import Darwin

@main
enum OverbrightApplication {
    @MainActor
    static func main() {
        // `overbright status`, `overbright set 140` and friends: act as the
        // command line client and exit without starting a second app.
        let arguments = Array(CommandLine.arguments.dropFirst())
        if let first = arguments.first,
           CLI.commands.contains(first) || !first.hasPrefix("-") {
            Darwin.exit(CLI.run(arguments))
        }

        let application = NSApplication.shared

        // Development aid: `Overbright --preview-hud <level>` shows the external
        // display indicator on every external display for a few seconds, so its
        // look can be checked without pressing keys.
        if let index = CommandLine.arguments.firstIndex(of: "--preview-hud") {
            previewHUD(application: application, arguments: Array(CommandLine.arguments[(index + 1)...]))
            return
        }

        if CommandLine.arguments.contains("--hardware-self-test") {
            runHardwareSelfTest(application: application)
            return
        }

        let delegate = AppDelegate()

        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        application.run()
    }

    @MainActor
    private static func previewHUD(application: NSApplication, arguments: [String]) {
        application.setActivationPolicy(.accessory)
        let level = arguments.first.flatMap(Double.init) ?? 70
        let hud = BrightnessHUD()
        let ids = ExternalDisplayManager.onlineExternalDisplays().map(\.id)
        guard let id = ids.first else {
            fputs("no external display\n", stderr)
            Darwin.exit(1)
        }
        let display = ExternalDisplay(
            id: id,
            name: ExternalDisplayManager.screen(for: id)?.localizedName ?? "Display",
            control: .ddc,
            level: level,
            minimum: ExternalBrightness.extraDimMinimum
        )
        hud.show(display)
        // Step once while visible, so the animated path is exercised too.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            var next = display
            next.level = ExternalBrightness.next(
                from: level, direction: .decrease, step: 6.25, minimum: display.minimum
            )
            hud.show(next)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { Darwin.exit(0) }
        withExtendedLifetime(hud) { application.run() }
    }

    @MainActor
    private static func runHardwareSelfTest(application: NSApplication) {
        application.setActivationPolicy(.accessory)

        guard let instanceLock = InstanceLock.acquire() else {
            fputs("SELFTEST FAIL: Overbright is already running\n", stderr)
            Darwin.exit(2)
        }

        ConfigStore.shared.load()
        let controller = BoostController()
        controller.configuredMethod = ConfigStore.shared.config.configuredBoostMethod
        print("SELFTEST method=\(controller.effectiveMethod.rawValue)")
        let brightnessService = NativeBrightnessService()
        guard let displayID = DisplayLookup.builtInScreen?.overbrightID,
              let baselineEndpoint = GammaTableService.readEndpoint(
                displayID: displayID
              ),
              let baselineBrightness = brightnessService.read(displayID: displayID) else {
            fputs("SELFTEST FAIL: unable to read built-in display state\n", stderr)
            Darwin.exit(2)
        }

        let previousLevel = controller.level.factor
        let requestedTestLevel = Float(
            ProcessInfo.processInfo.environment["OVERBRIGHT_SELF_TEST_LEVEL"] ?? ""
        ) ?? 1.05
        var completionStarted = false
        var testedWake = false
        var testedProfileRecovery = false
        // A small change that macOS or auto-brightness can make while boosted.
        // The boost must follow it, not end; lowering the backlight further
        // ends the boost by design (BuiltInBrightnessScale.backlightDropEndsBoost).
        let adjustedBacklight: Float = 0.9795198

        controller.onSnapshot = { snapshot in
            print(
                "SELFTEST state=\(snapshot.state) " +
                "currentEDR=\(snapshot.currentEDRHeadroom) " +
                "potentialEDR=\(snapshot.potentialEDRHeadroom)"
            )

            guard snapshot.state == .active, !completionStarted else { return }
            if !testedWake {
                testedWake = true
                DispatchQueue.main.async {
                    for value: Float in [adjustedBacklight] {
                        guard brightnessService.write(value, displayID: displayID) else {
                            controller.shutdown()
                            _ = brightnessService.write(baselineBrightness, displayID: displayID)
                            Darwin.exit(2)
                        }
                        controller.displayParametersDidChange()
                        guard controller.state == .active,
                              let actual = brightnessService.read(displayID: displayID),
                              abs(actual - value) < 0.01 else {
                            controller.shutdown()
                            _ = brightnessService.write(baselineBrightness, displayID: displayID)
                            fputs("SELFTEST FAIL: native brightness change disabled boost or was overwritten\n", stderr)
                            Darwin.exit(2)
                        }
                    }
                    controller.brightnessKeyControlDidBecomeUnavailable()
                    guard controller.state == .active else {
                        controller.shutdown()
                        fputs("SELFTEST FAIL: key listener interruption disabled boost\n", stderr)
                        Darwin.exit(2)
                    }
                    if let screen = DisplayLookup.builtInScreen {
                        controller.colorSpaceDidChange(on: screen)
                    }
                    guard controller.state == .active else {
                        controller.shutdown()
                        fputs("SELFTEST FAIL: identical profile disabled boost\n", stderr)
                        Darwin.exit(2)
                    }
                    controller.suspend(for: .systemSleep)
                    controller.suspend(for: .screenSleep)
                    controller.resume(from: .systemSleep)
                    controller.resume(from: .screenSleep)
                }
                return
            }
            if !testedProfileRecovery {
                testedProfileRecovery = true
                DispatchQueue.main.async {
                    guard let screen = DisplayLookup.builtInScreen else { return }
                    // Inject a changed identity into the production recovery path.
                    // This tests re-baselining without changing the user's ICC profile.
                    controller.handleColorProfileChange(on: screen, identity:
                        ColorProfileIdentity(iccProfileData: Data([0x44, 0x42]), fallbackName: "self-test"))
                }
                return
            }
            completionStarted = true

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) {
                let activeEndpoint = GammaTableService.readEndpoint(
                    displayID: displayID
                )
                let activeBrightness = brightnessService.read(displayID: displayID)
                let wasActive = controller.state == .active
                let usesOverlay = controller.effectiveMethod == .overlay
                let controllerReportedRestore = controller.disable()
                let restoredEndpoint = GammaTableService.readEndpoint(
                    displayID: displayID
                )
                let restoredBrightness = brightnessService.read(displayID: displayID)
                controller.setLevel(previousLevel)

                // The overlay method must leave the gamma table alone; the
                // classic one raises it.
                let boostWasApplied = activeEndpoint.map {
                    usesOverlay
                        ? wasActive && abs($0 - baselineEndpoint) < 0.001
                        : $0 > baselineEndpoint + 0.01
                } ?? false
                let baselineWasRestored = restoredEndpoint.map {
                    abs($0 - baselineEndpoint) < 0.025
                } ?? false
                let backlightWasRaised = activeBrightness.map {
                    abs($0 - adjustedBacklight) < 0.01
                } ?? false
                let backlightWasRestored = restoredBrightness.map {
                    abs($0 - adjustedBacklight) < 0.01
                } ?? false
                // The test intentionally adjusted the backlight; leave the user's
                // original hardware setting intact regardless of assertion outcome.
                _ = brightnessService.write(baselineBrightness, displayID: displayID)

                if boostWasApplied && baselineWasRestored &&
                    backlightWasRaised && backlightWasRestored &&
                    controllerReportedRestore {
                    print(
                        "SELFTEST PASS (\(usesOverlay ? "overlay" : "classic")): gamma \(baselineEndpoint) -> " +
                        "\(activeEndpoint!) -> \(restoredEndpoint!); " +
                        "backlight \(baselineBrightness) -> " +
                        "\(activeBrightness!) -> \(restoredBrightness!)"
                    )
                    application.terminate(nil)
                } else {
                    print("SELFTEST readback baselineGamma=\(baselineEndpoint) activeGamma=\(String(describing: activeEndpoint)) restoredGamma=\(String(describing: restoredEndpoint)) baselineBacklight=\(baselineBrightness) activeBacklight=\(String(describing: activeBrightness)) restoredBacklight=\(String(describing: restoredBrightness)) restore=\(controllerReportedRestore)")
                    fputs(
                        "SELFTEST FAIL: display readback did not verify apply/restore\n",
                        stderr
                    )
                    Darwin.exit(2)
                }
            }
        }

        var signalSources: [DispatchSourceSignal] = []
        for signalNumber in [SIGTERM, SIGINT, SIGHUP] {
            Darwin.signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(
                signal: signalNumber,
                queue: .main
            )
            source.setEventHandler {
                controller.shutdown()
                _ = brightnessService.write(baselineBrightness, displayID: displayID)
                application.terminate(nil)
            }
            source.resume()
            signalSources.append(source)
        }

        print("SELFTEST requestedLevel=\(BoostLevel(requestedTestLevel).factor)")
        controller.setLevel(requestedTestLevel)
        controller.enable()

        DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
            controller.shutdown()
            _ = brightnessService.write(baselineBrightness, displayID: displayID)
            controller.setLevel(previousLevel)
            fputs("SELFTEST FAIL: boost did not become active\n", stderr)
            Darwin.exit(2)
        }

        withExtendedLifetime((instanceLock, signalSources)) {
            application.run()
        }
    }
}
