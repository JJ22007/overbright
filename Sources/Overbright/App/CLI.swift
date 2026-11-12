// Command line interface, so scripts and AI agents can drive Overbright.
//
//   overbright status [--json]      what the display is doing right now
//   overbright on | off | toggle    switch the boost
//   overbright set <percent>        100 turns it off, 101-160 boosts
//   overbright up | down            one brightness-key step
//   overbright preset <name>        apply a preset from the config
//   overbright presets              list the presets
//   overbright displays             list external displays
//   overbright display <name|all> <percent|up|down>
//   overbright config               print the config file path
//   overbright check [file]         validate a config file
//
// Only the running app touches the display. The command line process sends
// the request over a distributed notification; the app does the work and
// writes the reply to a temporary file. `check`, `config`, `help` and
// `version` need no running app.

import AppKit

enum CLI {
    static let commands: Set<String> = [
        "status", "on", "off", "toggle", "set", "up", "down", "preset", "presets",
        "displays", "display", "key", "report",
        "config", "check", "version", "help", "--help", "-h", "--version", "--check"
    ]

    static let usage = """
    overbright: drive the Overbright menu bar app from scripts and agents.

      overbright status [--json]     state, level and display capability
      overbright on                  turn the boost on at the last level
      overbright off                 return to standard brightness
      overbright toggle              switch between the two
      overbright set <percent>       one scale for the built-in display: 0-100 is
                                     the system backlight, 101-160 the boost
      overbright up | down           one step along that scale
      overbright key up|down [--fine]
                                     exactly what F1/F2 do, indicator included
      overbright key up|down --real [--control]
                                     post a real brightness key press, which
                                     travels through macOS and the key tap
      overbright preset <name>       apply a preset from the config
      overbright presets             list the presets
      overbright displays            list external displays and how each is controlled
      overbright display <name|all> <percent|up|down>
                                     set an external display, 0-100; below 0
                                     darkens past the backlight's minimum
      overbright report              a Markdown report of this Mac's panel and
                                     the boost, to paste into a model report
                                     issue; it changes nothing
      overbright config              print the config file path
      overbright check [file]        validate a config file (default: yours)
      overbright version

    Add --json to any command that talks to the app to get the status as JSON.
    Exit codes: 0 done, 1 the app refused or the boost is unavailable,
    2 the app is not running or the command is malformed.
    """

    // MARK: Client (the `overbright` command)

    static func run(_ arguments: [String]) -> Int32 {
        guard let command = arguments.first else { print(usage); return 0 }
        switch command {
        case "help", "--help", "-h":
            print(usage)
            return 0
        case "version", "--version":
            print(AppInfo.version)
            return 0
        case "config":
            print(ConfigStore.fileURL.path)
            return 0
        case "check", "--check":
            return check(path: arguments.dropFirst().first)
        default:
            guard commands.contains(command) else {
                fail("error: unknown command \"\(command)\". Run `overbright help`.")
                return 2
            }
            return send(arguments)
        }
    }

    private static func check(path: String?) -> Int32 {
        let url = path.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            ?? ConfigStore.fileURL
        guard let data = try? Data(contentsOf: url) else {
            fail("error: cannot read \(url.path)")
            return 2
        }
        switch Config.parse(data) {
        case let .success(config):
            if config.warnings.isEmpty {
                print("ok: \(url.path)")
                return 0
            }
            config.warnings.forEach { fail("warning: \($0)") }
            return 1
        case let .failure(.notJSON(detail)):
            fail("error: not valid JSON (\(detail))")
            return 1
        case .failure(.notAnObject):
            fail("error: the file must contain a JSON object")
            return 1
        }
    }

    private static func send(_ arguments: [String]) -> Int32 {
        let reply = NSTemporaryDirectory() + "overbright-\(UUID().uuidString).reply"
        guard let token = CommandToken.read() else {
            fail("error: Overbright is not running. Open Overbright.app first.")
            return 2
        }
        let request: [String: Any] = ["args": arguments, "reply": reply, "token": token]
        guard let data = try? JSONSerialization.data(withJSONObject: request),
              let json = String(data: data, encoding: .utf8) else { return 2 }
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name(AppInfo.commandChannel),
            object: json,
            userInfo: nil,
            deliverImmediately: true
        )

        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            if let text = try? String(contentsOfFile: reply, encoding: .utf8),
               text.hasSuffix("\n") {
                try? FileManager.default.removeItem(atPath: reply)
                // First line is the exit code; the rest is the output.
                let parts = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
                let code = Int32(parts.first ?? "") ?? 2
                let body = parts.count > 1 ? String(parts[1]) : ""
                if code == 0 {
                    FileHandle.standardOutput.write(Data(body.utf8))
                } else {
                    FileHandle.standardError.write(Data(body.utf8))
                }
                return code
            }
            usleep(20_000)
        }
        fail("error: Overbright is not running. Open Overbright.app first.")
        return 2
    }

    private static func fail(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}

// MARK: Server (inside the running app)

@MainActor
final class CommandServer {
    private let boostController: BoostController
    private let brightnessKeyService: BrightnessKeyService
    private let externalDisplays: ExternalDisplayManager
    private var observer: NSObjectProtocol?
    private var token: String?
    /// The app's F1/F2 handler, for `overbright key`.
    var keyHandler: ((BrightnessKeyDirection, Bool) -> Double?)?

    init(
        boostController: BoostController,
        brightnessKeyService: BrightnessKeyService,
        externalDisplays: ExternalDisplayManager
    ) {
        self.boostController = boostController
        self.brightnessKeyService = brightnessKeyService
        self.externalDisplays = externalDisplays
    }

    func start() {
        token = CommandToken.create()
        guard token != nil else {
            NSLog("Overbright: could not write the command token; the overbright command is off")
            return
        }
        observer = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name(AppInfo.commandChannel),
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let json = note.object as? String else { return }
            MainActor.assumeIsolated {
                self?.receive(json)
            }
        }
    }

    private func receive(_ json: String) {
        guard let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)),
              let request = object as? [String: Any],
              let arguments = request["args"] as? [String],
              let reply = request["reply"] as? String,
              let token, CommandToken.matches(request["token"] as? String, token),
              // Only ever write where the client asked from: a reply file in the
              // user's own temporary directory.
              reply.hasPrefix(NSTemporaryDirectory()),
              reply.hasSuffix(".reply"),
              !reply.contains("/../") else { return }

        var rest = arguments
        let wantsJSON = rest.contains("--json")
        rest.removeAll { $0 == "--json" }

        handle(rest) { [weak self] code, text in
            guard let self else { return }
            let body: String
            if wantsJSON, code != 2 {
                body = self.statusJSON(message: code == 0 ? nil : text)
            } else {
                body = text
            }
            let output = "\(code)\n\(body)" + (body.hasSuffix("\n") ? "" : "\n")
            try? output.write(toFile: reply, atomically: true, encoding: .utf8)
        }
    }

    /// Runs a command and calls `finish` with an exit code and one line of text.
    private func handle(_ arguments: [String], finish: @escaping (Int32, String) -> Void) {
        guard let command = arguments.first else {
            finish(2, "error: no command")
            return
        }
        let config = ConfigStore.shared.config

        switch command {
        case "status":
            finish(0, statusLine())

        case "report":
            finish(0, reportText())

        case "presets":
            if config.presets.isEmpty {
                finish(0, "no presets. Add some under \"presets\" in \(ConfigStore.fileURL.path)")
            } else {
                finish(0, config.presets.map { "\($0.name)\t\(Self.plain($0.level))%" }
                    .joined(separator: "\n"))
            }

        case "off":
            boostController.disable()
            settle(finish)

        case "on":
            boostController.enable()
            settle(finish)

        case "toggle":
            boostController.toggle()
            settle(finish)

        case "set":
            let raw = arguments.dropFirst().first?.replacingOccurrences(of: "%", with: "") ?? ""
            let top = boostController.scaleTop
            guard let percent = Double(raw), percent.isFinite, (0...top).contains(percent) else {
                finish(2, "error: set needs a percentage from 0 to \(Self.plain(top))")
                return
            }
            boostController.setScale(percent)
            settle(finish)

        case "up", "down":
            let direction: BrightnessKeyDirection = command == "up" ? .increase : .decrease
            _ = boostController.stepScale(direction, step: config.keyStep)
            settle(finish)

        case "key":
            let fine = arguments.contains("--fine")
            guard let which = arguments.dropFirst().first(where: { !$0.hasPrefix("--") }),
                  which == "up" || which == "down" else {
                finish(2, "error: key needs up or down")
                return
            }
            if arguments.contains("--real") {
                // The press goes out at the HID tap, so it reaches this app's
                // own key tap, and macOS after it, the way a keyboard's does.
                guard brightnessKeyService.isRunning else {
                    finish(1, "error: the brightness key tap is not running (Accessibility permission, or brightnessKeys is off)")
                    return
                }
                BrightnessKeyService.postMediaKey(
                    which == "up" ? .increase : .decrease,
                    control: arguments.contains("--control"),
                    fineGrained: fine
                )
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                    self?.settle(finish)
                }
                return
            }
            guard keyHandler?(which == "up" ? .increase : .decrease, fine) != nil else {
                finish(1, "error: the built-in display is not available")
                return
            }
            settle(finish)

        case "preset":
            guard let name = arguments.dropFirst().first else {
                finish(2, "error: preset needs a name. Run `overbright presets`.")
                return
            }
            guard let preset = config.preset(named: name) else {
                finish(2, "error: no preset named \"\(name)\". Run `overbright presets`.")
                return
            }
            boostController.setLevelFromUserInteraction(Float(preset.level / 100))
            settle(finish)

        case "displays":
            // Re-read first, so levels changed with the displays' own buttons show.
            externalDisplays.refresh { [weak self] in
                guard let self else { return }
                finish(0, self.displaysText())
            }

        case "display":
            handleDisplay(Array(arguments.dropFirst()), finish: finish)

        default:
            finish(2, "error: unknown command \"\(command)\". Run `overbright help`.")
        }
    }

    private func handleDisplay(_ arguments: [String], finish: @escaping (Int32, String) -> Void) {
        let usage = "error: usage: overbright display <name|all> <percent|up|down>"
        guard arguments.count == 2 else { finish(2, usage); return }
        guard ConfigStore.shared.config.externalDisplays else {
            finish(1, "error: external displays are off (\"externalDisplays\": false in the config)")
            return
        }
        let query = arguments[0].lowercased()
        let targets = externalDisplays.displays.filter {
            query == "all" || String($0.id) == query || $0.name.lowercased().contains(query)
        }
        guard !targets.isEmpty else {
            finish(2, externalDisplays.displays.isEmpty
                ? "error: no external display is connected"
                : "error: no external display matches \"\(arguments[0])\". Run `overbright displays`.")
            return
        }

        let action = arguments[1].lowercased().replacingOccurrences(of: "%", with: "")
        let step = ConfigStore.shared.config.keyStep
        var levels: [(CGDirectDisplayID, Double)] = []
        for display in targets {
            switch action {
            case "up": levels.append((display.id, ExternalBrightness.next(
                from: display.level, direction: .increase, step: step, minimum: display.minimum)))
            case "down": levels.append((display.id, ExternalBrightness.next(
                from: display.level, direction: .decrease, step: step, minimum: display.minimum)))
            default:
                let text = action.replacingOccurrences(of: "\u{2212}", with: "-")
                guard let percent = Double(text), percent.isFinite,
                      (display.minimum...100).contains(percent) else {
                    finish(2, "error: \(display.name) takes \(ExternalBrightness.label(display.minimum)) to 100%, up or down")
                    return
                }
                levels.append((display.id, percent))
            }
        }

        let group = DispatchGroup()
        for (id, level) in levels {
            group.enter()
            externalDisplays.setLevel(level, for: id) { group.leave() }
        }
        group.notify(queue: .main) { [weak self] in
            guard let self else { return }
            let ids = Set(levels.map(\.0))
            finish(0, self.displaysText(only: ids))
        }
    }

    private func displaysText(only ids: Set<CGDirectDisplayID>? = nil) -> String {
        let displays = externalDisplays.displays.filter { ids?.contains($0.id) ?? true }
        if displays.isEmpty { return "no external displays" }
        return displays.map {
            "\($0.id)\t\($0.name)\t\($0.control.rawValue)\t\(ExternalBrightness.label($0.level))"
        }.joined(separator: "\n")
    }

    /// Enabling is asynchronous: macOS takes a moment to open EDR headroom.
    /// Reply once the state stops changing, so the caller sees the real result.
    private func settle(_ finish: @escaping (Int32, String) -> Void, attemptsRemaining: Int = 50) {
        if boostController.state == .engaging, attemptsRemaining > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.settle(finish, attemptsRemaining: attemptsRemaining - 1)
            }
            return
        }
        if case let .unavailable(message) = boostController.state {
            finish(1, "error: \(message)")
        } else {
            finish(0, statusLine())
        }
    }

    private var stateName: String {
        switch boostController.state {
        case .off: return "off"
        case .engaging: return "engaging"
        case .active: return "on"
        case .unavailable: return "unavailable"
        }
    }

    private var keysName: String {
        if !ConfigStore.shared.config.brightnessKeys { return "disabled" }
        if !brightnessKeyService.isTrusted { return "needs-permission" }
        return brightnessKeyService.isRunning ? "on" : "off"
    }

    private func statusLine() -> String {
        let snapshot = boostController.snapshot
        var line = "\(stateName) \(snapshot.level.percentage)%"
        if let scale = boostController.scalePercent {
            line += " (scale \(Int(scale.rounded()))%)"
        }
        if case let .unsupported(reason) = snapshot.support {
            line += " (\(reason.message))"
        }
        if case let .unavailable(message) = snapshot.state {
            line += " (\(message))"
        }
        return line
    }

    private func statusJSON(message: String?) -> String {
        let snapshot = boostController.snapshot
        var status: [String: Any] = [
            "state": stateName,
            "level": snapshot.level.percentage,
            "maxLevel": ConfigStore.shared.config.maxLevel.map { $0 as Any } ?? "auto",
            "panelMaxLevel": (Double(BoostLevel.maximum) * 10000).rounded() / 100,
            "supported": snapshot.support == .supported,
            "unsupportedReason": {
                if case let .unsupported(reason) = snapshot.support { return reason.code }
                return NSNull()
            }() as Any,
            "panel": boostController.panelDiagnostics,
            "edrHeadroom": (snapshot.currentEDRHeadroom * 100).rounded() / 100,
            "potentialEdrHeadroom": (snapshot.potentialEDRHeadroom * 100).rounded() / 100,
            "brightnessKeys": keysName,
            "presets": ConfigStore.shared.config.presets.map {
                ["name": $0.name, "level": $0.level] as [String: Any]
            },
            "configProblems": ConfigStore.shared.problems,
            "scale": boostController.scalePercent.map { ($0 * 100).rounded() / 100 } ?? NSNull(),
            "scaleTop": boostController.scaleTop,
            "boostMethod": boostController.effectiveMethod.rawValue,
            "overlayMaxFrameGap": (boostController.overlayMaxFrameGap * 1000).rounded() / 1000,
            "mainThreadMaxGap": (boostController.mainThreadMaxGap * 1000).rounded() / 1000,
            "transitions": boostController.transitionDiagnostics,
            "direct": boostController.directDiagnostics,
            "externalDisplays": externalDisplays.displays.map {
                [
                    "id": Int($0.id),
                    "name": $0.name,
                    "control": $0.control.rawValue,
                    "level": Int($0.level.rounded()),
                    "minimum": Int($0.minimum.rounded())
                ] as [String: Any]
            },
            "version": AppInfo.version
        ]
        if case let .unavailable(reason) = snapshot.state {
            status["message"] = reason
        } else if let message {
            status["message"] = message
        }
        let data = try? JSONSerialization.data(
            withJSONObject: status, options: [.prettyPrinted, .sortedKeys]
        )
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    /// Everything a model report needs, read-only.
    private func reportText() -> String {
        let snapshot = boostController.snapshot
        let readings = PanelLightService.readings()
        let framebuffer = PanelLightService.findBuiltInFramebuffer()
        let panelNits = framebuffer == 0 ? nil : PanelLightService.nits(framebuffer, "IOMFBBrightnessLevel")
        if framebuffer != 0 { IOObjectRelease(framebuffer) }
        let direct = boostController.directDiagnostics
        let target = direct["targetNits"] as? Double
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let boosted = stateName == "on" && snapshot.level.percentage > 100
        func nits(_ value: Double?) -> String { value.map { "\(Int($0.rounded())) nits" } ?? "unknown" }

        let check: String
        switch BoostCheck.judge(boosted: boosted, method: boostController.effectiveMethod.rawValue,
                                targetNits: target, panelNits: panelNits) {
        case .notBoosted:
            check = "not checked: turn the boost on at the top of the scale, then run this again"
        case .notDirect:
            check = "not checked: the \(boostController.effectiveMethod.rawValue) method draws on screen; say what you see"
        case .reached:
            check = "yes: the panel is at \(nits(panelNits)), as asked"
        case let .missed(panel, wanted):
            check = "NO: asked for \(nits(wanted)), the panel is at \(nits(panel))"
        case .unknown:
            check = "unknown: no reading"
        }
        let supported: String = {
            if case let .unsupported(reason) = snapshot.support { return "no (\(reason.code))" }
            return "yes"
        }()
        let lines = [
            "### Overbright model report",
            "",
            "| | |",
            "|---|---|",
            "| Model | \(PanelLightService.modelIdentifier ?? "unknown") |",
            "| macOS | \(os.majorVersion).\(os.minorVersion).\(os.patchVersion) |",
            "| Overbright | \(AppInfo.version) |",
            "| Supported | \(supported) |",
            "| Method | \(boostController.effectiveMethod.rawValue) |",
            "| Standard white | \(nits(readings.systemStandardNits)) |",
            "| Peak | \(nits(readings.peakNits)) |",
            "| Backlight cap now | \(nits(readings.capNits)) |",
            "| Backlight now | \(nits(panelNits)) |",
            "| HDR headroom now | \(String(format: "%.2f", snapshot.currentEDRHeadroom)) |",
            "| Top of the scale | \(Int(boostController.scaleTop.rounded()))% |",
            "| Boost | \(statusLine()) |",
            "| Boost reached the panel | \(check) |",
            "",
            "<details><summary>status --json</summary>",
            "",
            "```json",
            statusJSON(message: nil),
            "```",
            "",
            "</details>"
        ]
        return lines.joined(separator: "\n")
    }

    private static func plain(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(value)
    }
}
