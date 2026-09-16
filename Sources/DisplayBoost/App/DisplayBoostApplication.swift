import AppKit
import Darwin

@main
enum DisplayBoostApplication {
    @MainActor
    static func main() {
        let application = NSApplication.shared

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
    private static func runHardwareSelfTest(application: NSApplication) {
        application.setActivationPolicy(.accessory)

        guard let instanceLock = InstanceLock.acquire() else {
            fputs("SELFTEST FAIL: Display Boost is already running\n", stderr)
            Darwin.exit(2)
        }

        let controller = BoostController()
        let brightnessService = NativeBrightnessService()
        guard let displayID = DisplayLookup.builtInScreen?.displayBoostID,
              let baselineEndpoint = GammaTableService.readEndpoint(
                displayID: displayID
              ),
              let baselineBrightness = brightnessService.read(displayID: displayID) else {
            fputs("SELFTEST FAIL: unable to read built-in display state\n", stderr)
            Darwin.exit(2)
        }

        let previousLevel = controller.level.factor
        let requestedTestLevel = Float(
            ProcessInfo.processInfo.environment["DISPLAYBOOST_SELF_TEST_LEVEL"] ?? ""
        ) ?? 1.05
        var completionStarted = false
        var testedWake = false
        var testedProfileRecovery = false
        let adjustedBacklight: Float = 0.7

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
                    for value: Float in [0.9795198, adjustedBacklight] {
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
                let controllerReportedRestore = controller.disable()
                let restoredEndpoint = GammaTableService.readEndpoint(
                    displayID: displayID
                )
                let restoredBrightness = brightnessService.read(displayID: displayID)
                controller.setLevel(previousLevel)

                let boostWasApplied = activeEndpoint.map {
                    $0 > baselineEndpoint + 0.01
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
                        "SELFTEST PASS: gamma \(baselineEndpoint) -> " +
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
