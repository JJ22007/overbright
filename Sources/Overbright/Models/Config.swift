import Foundation

/// A named brightness level shown in the menu and reachable from the CLI.
struct Preset: Equatable {
    var name: String
    /// Percent of standard brightness, 100...160.
    var level: Double
}

/// Everything a user can change without touching the code.
///
/// The file lives at `~/.config/overbright/config.json`. Every field is
/// optional: a missing field keeps its default, and a bad one is reported by
/// `warnings` and replaced by its default. Decoding never fails on content;
/// only unreadable JSON is an error.
struct Config: Equatable {
    static let levelRange: ClosedRange<Double> = 100...160
    static let stepRange: ClosedRange<Double> = 0.5...30
    static let languages = ["auto", "en", "zh"]

    /// Highest level the slider, the brightness keys and the CLI can reach.
    var maxLevel: Double = 160
    /// Percent added per brightness-key press above 100%.
    var keyStep: Double = 6.25
    /// Percent added per press while holding Option+Shift.
    var fineKeyStep: Double = 1.5625
    /// Let F1/F2 continue past 100% (needs the Accessibility permission).
    var brightnessKeys: Bool = true
    /// Turn the boost on when the app starts.
    var enableOnLaunch: Bool = false
    /// Show the current percentage next to the menu bar icon while boosted.
    var showPercentage: Bool = false
    /// "auto", "en" or "zh".
    var language: String = "auto"
    /// Show external displays in the menu and control their brightness.
    var externalDisplays: Bool = true
    /// Control+F1/F2 adjust external displays (needs the Accessibility permission).
    var externalKeys: Bool = true
    /// Show a brightness indicator on an external display while it changes.
    var showHUD: Bool = true
    /// Let external displays go below 0%: the backlight stays at its minimum
    /// and the picture is darkened in software, down to -90%.
    var extraDimming: Bool = true
    /// How the boost brightens the built-in display: "auto" picks by macOS
    /// version, "panel" or "classic" force one. See `BoostMethod`.
    var boostMethod: String = "auto"
    var presets: [Preset] = []

    /// Problems found while decoding. Each one names the entry at fault.
    var warnings: [String] = []

    static let knownKeys: Set<String> = [
        "maxLevel", "keyStep", "fineKeyStep", "brightnessKeys",
        "enableOnLaunch", "showPercentage", "language", "presets",
        "externalDisplays", "externalKeys", "showHUD", "extraDimming", "boostMethod"
    ]

    enum ParseError: Error, Equatable {
        case notJSON(String)
        case notAnObject
    }

    static func parse(_ data: Data) -> Result<Config, ParseError> {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            return .failure(.notJSON(error.localizedDescription))
        }
        guard let dictionary = object as? [String: Any] else {
            return .failure(.notAnObject)
        }
        return .success(Config(dictionary: dictionary))
    }

    init() {}

    init(dictionary: [String: Any]) {
        for key in dictionary.keys.sorted() where !Self.knownKeys.contains(key) {
            warnings.append("\"\(key)\" is not a known option and was ignored")
        }

        maxLevel = number("maxLevel", in: dictionary, range: Self.levelRange, default: maxLevel)
        if maxLevel <= 100 {
            warnings.append("\"maxLevel\" must be above 100; using 160")
            maxLevel = 160
        }
        keyStep = number("keyStep", in: dictionary, range: Self.stepRange, default: keyStep)
        fineKeyStep = number(
            "fineKeyStep", in: dictionary, range: Self.stepRange, default: fineKeyStep
        )
        brightnessKeys = flag("brightnessKeys", in: dictionary, default: brightnessKeys)
        enableOnLaunch = flag("enableOnLaunch", in: dictionary, default: enableOnLaunch)
        showPercentage = flag("showPercentage", in: dictionary, default: showPercentage)
        externalDisplays = flag("externalDisplays", in: dictionary, default: externalDisplays)
        externalKeys = flag("externalKeys", in: dictionary, default: externalKeys)
        showHUD = flag("showHUD", in: dictionary, default: showHUD)
        extraDimming = flag("extraDimming", in: dictionary, default: extraDimming)
        if let raw = dictionary["boostMethod"] {
            let options = ["auto"] + BoostMethod.allCases.map(\.rawValue)
            if let value = (raw as? String)?.lowercased(), options.contains(value) {
                boostMethod = value
            } else {
                warnings.append("\"boostMethod\" must be \"auto\", \"panel\" or \"classic\"; using \"auto\"")
            }
        }

        if let raw = dictionary["language"] {
            if let value = raw as? String, Self.languages.contains(value.lowercased()) {
                language = value.lowercased()
            } else {
                warnings.append("\"language\" must be \"auto\", \"en\" or \"zh\"; using \"auto\"")
            }
        }

        if let raw = dictionary["presets"] {
            if let list = raw as? [Any] {
                for (index, entry) in list.enumerated() {
                    if let preset = preset(from: entry, index: index) {
                        presets.append(preset)
                    }
                }
            } else {
                warnings.append("\"presets\" must be a list")
            }
        }
    }

    /// The boost method for this Mac: the configured one, or by macOS version.
    func resolvedBoostMethod(
        os: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion
    ) -> BoostMethod {
        BoostMethod(rawValue: boostMethod)
            ?? BoostMethod.automatic(major: os.majorVersion, minor: os.minorVersion)
    }

    func preset(named query: String) -> Preset? {
        let wanted = query.lowercased()
        return presets.first { $0.name.lowercased() == wanted }
            ?? presets.first { $0.name.lowercased().hasPrefix(wanted) }
    }

    /// The config as pretty-printed JSON, with keys in a stable order.
    var json: String {
        func format(_ value: Double) -> String {
            value == value.rounded() ? String(Int(value)) : String(value)
        }
        func quote(_ text: String) -> String {
            let data = try? JSONSerialization.data(
                withJSONObject: [text], options: [.withoutEscapingSlashes]
            )
            let array = data.flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
            return String(array.dropFirst().dropLast())
        }
        let presetLines = presets.map {
            "    { \"name\": \(quote($0.name)), \"level\": \(format($0.level)) }"
        }
        let presetBlock = presets.isEmpty
            ? "[]"
            : "[\n" + presetLines.joined(separator: ",\n") + "\n  ]"
        return """
        {
          "maxLevel": \(format(maxLevel)),
          "keyStep": \(format(keyStep)),
          "fineKeyStep": \(format(fineKeyStep)),
          "brightnessKeys": \(brightnessKeys),
          "enableOnLaunch": \(enableOnLaunch),
          "showPercentage": \(showPercentage),
          "language": \(quote(language)),
          "externalDisplays": \(externalDisplays),
          "externalKeys": \(externalKeys),
          "showHUD": \(showHUD),
          "extraDimming": \(extraDimming),
          "boostMethod": \(quote(boostMethod)),
          "presets": \(presetBlock)
        }

        """
    }

    // MARK: Decoding helpers

    private mutating func number(
        _ key: String,
        in dictionary: [String: Any],
        range: ClosedRange<Double>,
        default fallback: Double
    ) -> Double {
        guard let raw = dictionary[key] else { return fallback }
        guard !Self.isBoolean(raw), let value = (raw as? NSNumber)?.doubleValue,
              value.isFinite else {
            warnings.append("\"\(key)\" must be a number; using \(Self.plain(fallback))")
            return fallback
        }
        guard range.contains(value) else {
            let clamped = min(max(value, range.lowerBound), range.upperBound)
            warnings.append(
                "\"\(key)\" must be between \(Self.plain(range.lowerBound)) and " +
                "\(Self.plain(range.upperBound)); using \(Self.plain(clamped))"
            )
            return clamped
        }
        return value
    }

    private mutating func flag(
        _ key: String,
        in dictionary: [String: Any],
        default fallback: Bool
    ) -> Bool {
        guard let raw = dictionary[key] else { return fallback }
        guard Self.isBoolean(raw), let value = raw as? Bool else {
            warnings.append("\"\(key)\" must be true or false; using \(fallback)")
            return fallback
        }
        return value
    }

    private mutating func preset(from entry: Any, index: Int) -> Preset? {
        let label = "presets[\(index)]"
        guard let dictionary = entry as? [String: Any] else {
            warnings.append("\(label) must be an object with \"name\" and \"level\"; skipped")
            return nil
        }
        guard let name = (dictionary["name"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
            warnings.append("\(label) needs a \"name\"; skipped")
            return nil
        }
        guard let raw = dictionary["level"], !Self.isBoolean(raw),
              let level = (raw as? NSNumber)?.doubleValue, level.isFinite,
              Self.levelRange.contains(level) else {
            warnings.append("\(label) (\"\(name)\") needs a \"level\" between 100 and 160; skipped")
            return nil
        }
        if presets.contains(where: { $0.name.lowercased() == name.lowercased() }) {
            warnings.append("\(label) repeats the name \"\(name)\"; skipped")
            return nil
        }
        if level > maxLevel {
            warnings.append(
                "\(label) (\"\(name)\") is above maxLevel and will stop at \(Self.plain(maxLevel))"
            )
        }
        return Preset(name: name, level: level)
    }

    private static func isBoolean(_ value: Any) -> Bool {
        guard let number = value as? NSNumber else { return false }
        return CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    private static func plain(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(value)
    }
}
