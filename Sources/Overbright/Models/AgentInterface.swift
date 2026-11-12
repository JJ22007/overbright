import Foundation

/// What the panel reads back after a command: the proof an agent gets that
/// the boost did what it asked, or that the display is back to standard.
enum Readback: String {
    /// Boosted with `direct`, and the panel is at the target.
    case reached
    /// Boosted with `direct`, but the panel is not at the target.
    case missed
    /// Not boosted, and the backlight is at or below the standard white cap.
    case restored
    /// Not boosted, but the backlight is still above standard white (macOS
    /// keeps it up for about 15 s after an `overlay` or `classic` boost).
    case notRestored
    /// Boosted with `overlay` or `classic`, which draw on screen: the
    /// backlight cannot show whether the picture is brighter.
    case notDirect
    /// No reading.
    case unknown

    static let tolerance = BoostCheck.tolerance

    static func judge(boosted: Bool, method: String, targetNits: Double?,
                      panelNits: Double?, capNits: Double?) -> Readback {
        if boosted {
            switch BoostCheck.judge(boosted: true, method: method, targetNits: targetNits, panelNits: panelNits) {
            case .reached: return .reached
            case .missed: return .missed
            case .notDirect: return .notDirect
            case .notBoosted, .unknown: return .unknown
            }
        }
        guard let panelNits, let capNits, panelNits.isFinite, capNits.isFinite else { return .unknown }
        return panelNits <= capNits + tolerance ? .restored : .notRestored
    }

    /// Whether an agent can call the command done.
    var proves: Bool { self == .reached || self == .restored }
}

/// `overbright mcp`: the command line as a Model Context Protocol server over
/// stdio (newline-delimited JSON-RPC 2.0), with no dependencies. It adds no
/// display behaviour: each tool runs an existing command, then reads the
/// panel back and says whether it did what was asked.
struct MCPServer {
    /// Runs an `overbright` command; returns its exit code and output.
    var run: ([String]) -> (code: Int32, output: String)
    /// Waits, so a tool can poll until the panel settles.
    var wait: (Double) -> Void
    var version: String

    static let protocolVersions = ["2025-06-18", "2025-03-26", "2024-11-05"]

    /// The reply to one JSON-RPC line, or nil for a notification.
    func handle(_ line: String) -> String? {
        guard let data = line.data(using: .utf8),
              let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return encode(["jsonrpc": "2.0", "id": NSNull(),
                           "error": ["code": -32700, "message": "parse error"]])
        }
        guard let method = message["method"] as? String else { return nil }
        guard let id = message["id"] else { return nil } // a notification
        let params = message["params"] as? [String: Any] ?? [:]
        func reply(_ result: [String: Any]) -> String {
            encode(["jsonrpc": "2.0", "id": id, "result": result])
        }
        func error(_ code: Int, _ text: String) -> String {
            encode(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": text]])
        }
        switch method {
        case "initialize":
            let asked = params["protocolVersion"] as? String ?? ""
            return reply([
                "protocolVersion": Self.protocolVersions.contains(asked) ? asked : Self.protocolVersions[0],
                "capabilities": ["tools": [String: Any]()],
                "serverInfo": ["name": "overbright", "version": version],
                "instructions": """
                Overbright raises a MacBook XDR display above 100%. Every tool reads the panel \
                back: "readback" is "reached" when a boost is at the target, "restored" when \
                the display is back at standard white. Use restore to undo.
                """
            ])
        case "ping":
            return reply([:])
        case "tools/list":
            return reply(["tools": Self.tools])
        case "tools/call":
            guard let name = params["name"] as? String else { return error(-32602, "missing tool name") }
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            guard let result = call(name, arguments) else { return error(-32602, "unknown tool: \(name)") }
            return reply(result)
        default:
            return error(-32601, "method not found: \(method)")
        }
    }

    static let tools: [[String: Any]] = [
        [
            "name": "status",
            "description": "The boost's state, level and method, and what the panel reads back now. Changes nothing.",
            "inputSchema": ["type": "object", "properties": [String: Any]()],
            "annotations": ["readOnlyHint": true]
        ],
        [
            "name": "set_brightness",
            "description": """
            Set the built-in display on one scale: 0-100 is the system backlight, above 100 boosts \
            (up to scaleTop from status). Waits for the panel to settle and returns its readback; \
            the result is an error if the panel did not reach the target.
            """,
            "inputSchema": [
                "type": "object",
                "properties": ["percent": ["type": "number", "minimum": 0,
                                           "description": "e.g. 150 for 150%"]],
                "required": ["percent"]
            ]
        ],
        [
            "name": "restore",
            "description": """
            Turn the boost off and return to standard brightness. Waits for the backlight to come \
            down and returns the readback; "restored" proves it.
            """,
            "inputSchema": ["type": "object", "properties": [String: Any]()],
            "annotations": ["idempotentHint": true]
        ],
        [
            "name": "report",
            "description": "A Markdown report of this Mac's panel and the boost, as `overbright report` prints it. Changes nothing.",
            "inputSchema": ["type": "object", "properties": [String: Any]()],
            "annotations": ["readOnlyHint": true]
        ]
    ]

    /// Runs a tool; nil if there is no such tool.
    func call(_ name: String, _ arguments: [String: Any]) -> [String: Any]? {
        switch name {
        case "status":
            return result(summary(), failed: false)
        case "report":
            let (code, output) = run(["report"])
            return ["content": [["type": "text", "text": output]], "isError": code != 0]
        case "set_brightness":
            guard let percent = (arguments["percent"] as? NSNumber)?.doubleValue, percent.isFinite else {
                return result(["error": "percent must be a number"], failed: true)
            }
            let (code, output) = run(["set", String(percent)])
            guard code == 0 else { return result(["error": output, "exitCode": Int(code)], failed: true) }
            var status = settle(until: percent > 100 ? [.reached, .notDirect] : [.restored],
                                seconds: percent > 100 ? 4 : 20)
            status["requested"] = percent
            let readback = Readback(rawValue: status["readback"] as? String ?? "") ?? .unknown
            // A boost is proved by `reached`; 0-100 by the backlight being at or
            // below standard white. `notDirect` boosts cannot be proved here.
            return result(status, failed: !(readback.proves || readback == .notDirect))
        case "restore":
            let (code, output) = run(["off"])
            guard code == 0 else { return result(["error": output, "exitCode": Int(code)], failed: true) }
            let status = settle(until: [.restored], seconds: 20)
            let readback = Readback(rawValue: status["readback"] as? String ?? "") ?? .unknown
            return result(status, failed: readback != .restored)
        default:
            return nil
        }
    }

    /// Polls the status until its readback is one of `wanted` or time runs out.
    private func settle(until wanted: Set<Readback>, seconds: Double) -> [String: Any] {
        let step = 0.25
        var waited = 0.0
        var status = summary()
        while waited < seconds {
            if let readback = Readback(rawValue: status["readback"] as? String ?? ""), wanted.contains(readback) {
                break
            }
            wait(step)
            waited += step
            status = summary()
        }
        status["waitedSeconds"] = waited
        return status
    }

    /// The parts of `status --json` an agent needs.
    func summary() -> [String: Any] {
        let (code, output) = run(["status", "--json"])
        guard code != 2, let data = output.data(using: .utf8),
              let status = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ["error": output.isEmpty ? "Overbright is not running" : output]
        }
        var summary: [String: Any] = [:]
        for key in ["state", "level", "scale", "scaleTop", "boostMethod", "supported", "message"] {
            if let value = status[key] { summary[key] = value }
        }
        if let back = status["readback"] as? [String: Any] {
            for (key, value) in back { summary[key] = value }
        }
        return summary
    }

    private func result(_ object: [String: Any], failed: Bool) -> [String: Any] {
        let failed = failed || object["error"] != nil
        return ["content": [["type": "text", "text": encode(object, pretty: true)]],
                "structuredContent": object,
                "isError": failed]
    }

    private func encode(_ object: [String: Any], pretty: Bool = false) -> String {
        let options: JSONSerialization.WritingOptions = pretty ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: options) else { return "{}" }
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}
