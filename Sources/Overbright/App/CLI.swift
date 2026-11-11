// Command line interface, so scripts and AI agents can drive Overbright.
//
//   overbright status [--json]      what the display is doing right now
//   overbright on | off | toggle    switch the boost
//   overbright set <percent>        100 turns it off, 101-160 boosts
//   overbright up | down            one brightness-key step
//   overbright preset <name>        apply a preset from the config
//   overbright presets              list the presets
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
        "config", "check", "version", "help", "--help", "-h", "--version", "--check"
    ]

    static let usage = """
    overbright: drive the Overbright menu bar app from scripts and agents.

      overbright status [--json]     state, level and display capability
      overbright on                  turn the boost on at the last level
      overbright off                 return to standard brightness
      overbright toggle              switch between the two
      overbright set <percent>       100 turns the boost off, 101-160 boosts
      overbright up | down           one brightness-key step
      overbright preset <name>       apply a preset from the config
      overbright presets             list the presets
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
        let request: [String: Any] = ["args": arguments, "reply": reply]
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
    private var observer: NSObjectProtocol?

    init(boostController: BoostController, brightnessKeyService: BrightnessKeyService) {
        self.boostController = boostController
        self.brightnessKeyService = brightnessKeyService
    }

    func start() {
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
            guard let percent = Double(raw), percent.isFinite, percent >= 100 else {
                finish(2, "error: set needs a percentage from 100 to \(Self.plain(config.maxLevel))")
                return
            }
            boostController.setLevelFromUserInteraction(Float(percent / 100))
            settle(finish)

        case "up", "down":
            let direction: BrightnessKeyDirection = command == "up" ? .increase : .decrease
            let current = boostController.isWanted ? boostController.level.factor : BoostLevel.minimum
            let next = BrightnessKeyStep.nextBoostLevel(
                from: current, direction: direction, fineGrained: false
            )
            boostController.setLevelFromUserInteraction(next.factor)
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

        default:
            finish(2, "error: unknown command \"\(command)\". Run `overbright help`.")
        }
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
        if snapshot.potentialEDRHeadroom <= 1.05 {
            line += " (this display has no EDR headroom)"
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
            "maxLevel": ConfigStore.shared.config.maxLevel,
            "supported": snapshot.potentialEDRHeadroom > 1.05,
            "edrHeadroom": (snapshot.currentEDRHeadroom * 100).rounded() / 100,
            "potentialEdrHeadroom": (snapshot.potentialEDRHeadroom * 100).rounded() / 100,
            "brightnessKeys": keysName,
            "presets": ConfigStore.shared.config.presets.map {
                ["name": $0.name, "level": $0.level] as [String: Any]
            },
            "configProblems": ConfigStore.shared.problems,
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

    private static func plain(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(value)
    }
}
