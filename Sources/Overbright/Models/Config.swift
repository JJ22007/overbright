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
    static let levelRange: ClosedRange<Double> = 100...400
    static let stepRange: ClosedRange<Double> = 0.5...30
    static let languages = ["auto", "en", "zh"]

    /// Highest level the slider, the brightness keys and the CLI can reach.
    /// nil ("auto", the default) is as high as the panel goes.
    var maxLevel: Double? = nil
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
    /// version and panel, "direct", "overlay" or "classic" put one first.
    /// See `BoostMethod` and `PanelSupport.methods`.
    var boostMethod: String = "auto"
    /// The direct method's ceiling in nits.
    var maxNits: Double = DirectPanel.defaultCeiling
    /// Direct method: keep a small fixed HDR headroom on screen while the
    /// boost is on, so system banners do not make macOS ramp the backlight.
    /// See `HeadroomHoldService`.
    var holdHeadroom: Bool = true
    /// End the boost when the battery falls to this percent while unplugged.
    /// nil (the default) never does.
    var lowBatteryOff: Double? = nil
    /// A global shortcut that switches the boost, such as "ctrl+opt+cmd+b".
    /// nil (the default) registers none.
    var toggleShortcut: String? = nil
    /// A global shortcut that dims every display and, pressed again, puts
    /// them back. nil (`false` in the file) registers none. See `DimAll`.
    var dimShortcut: String? = DimAll.defaultShortcut
    /// How far that shortcut dims, in percent.
    var dimLevel: Double = DimAll.defaultLevel
    var presets: [Preset] = []

    /// Problems found while decoding. Each one names the entry at fault.
    var warnings: [String] = []

    static let knownKeys: Set<String> = [
        "maxLevel", "keyStep", "fineKeyStep", "brightnessKeys",
        "enableOnLaunch", "showPercentage", "language", "presets",
        "externalDisplays", "externalKeys", "showHUD", "extraDimming", "boostMethod", "maxNits",
        "holdHeadroom",
        "lowBatteryOff", "toggleShortcut", "dimShortcut", "dimLevel"
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

        if let text = dictionary["maxLevel"] as? String {
            if text.lowercased() != "auto" {
                warnings.append("\"maxLevel\" must be a number or \"auto\"; using \"auto\"")
            }
        } else if dictionary["maxLevel"] != nil {
            let level = number("maxLevel", in: dictionary, range: Self.levelRange, default: 400)
            if level <= 100 {
                warnings.append("\"maxLevel\" must be above 100; using \"auto\"")
            } else {
                maxLevel = level
            }
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
                warnings.append("\"boostMethod\" must be \"auto\", \"direct\", \"overlay\" or \"classic\"; using \"auto\"")
            }
        }
        maxNits = number("maxNits", in: dictionary, range: DirectPanel.ceilingRange, default: maxNits)
        holdHeadroom = flag("holdHeadroom", in: dictionary, default: holdHeadroom)
        if let raw = dictionary["lowBatteryOff"], !(raw is NSNull), !(Self.isBoolean(raw) && (raw as? Bool) == false) {
            if Self.isBoolean(raw) {
                warnings.append("\"lowBatteryOff\" must be a battery percentage or false; using false")
            } else {
                lowBatteryOff = number("lowBatteryOff", in: dictionary, range: LowBattery.range, default: 20)
            }
        }
        if let raw = dictionary["toggleShortcut"], !(raw is NSNull), !(Self.isBoolean(raw) && (raw as? Bool) == false) {
            if let text = raw as? String, Shortcut.parse(text) != nil {
                toggleShortcut = text
            } else {
                warnings.append("\"toggleShortcut\" must look like \"ctrl+opt+cmd+b\" (a letter, digit, F-key or space with Command, Control or Option); using none")
            }
        }
        if let raw = dictionary["dimShortcut"] {
            if raw is NSNull || (Self.isBoolean(raw) && (raw as? Bool) == false) {
                dimShortcut = nil
            } else if let text = raw as? String, Shortcut.parse(text) != nil {
                dimShortcut = text
            } else {
                warnings.append("\"dimShortcut\" must look like \"ctrl+opt+cmd+b\" (a letter, digit, F-key or space with Command, Control or Option) or be false; using \"\(DimAll.defaultShortcut)\"")
            }
        }
        dimLevel = number("dimLevel", in: dictionary, range: DimAll.levelRange, default: dimLevel)
        // One combination cannot do both. The one written in the file wins
        // over the default; with both written, dimming gives way.
        if let toggle = toggleShortcut.flatMap(Shortcut.parse), toggle == dimShortcut.flatMap(Shortcut.parse) {
            if dictionary["dimShortcut"] != nil {
                warnings.append("\"dimShortcut\" is the same combination as \"toggleShortcut\"; dimming has no shortcut")
            }
            dimShortcut = nil
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
    /// The method the config asks for; nil for "auto".
    var configuredBoostMethod: BoostMethod? { BoostMethod(rawValue: boostMethod) }

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
          "maxLevel": \(maxLevel.map(format) ?? quote("auto")),
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
          "maxNits": \(format(maxNits)),
          "holdHeadroom": \(holdHeadroom),
          "lowBatteryOff": \(lowBatteryOff.map(format) ?? "false"),
          "toggleShortcut": \(toggleShortcut.map(quote) ?? "false"),
          "dimShortcut": \(dimShortcut.map(quote) ?? "false"),
          "dimLevel": \(format(dimLevel)),
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
            warnings.append("\(label) (\"\(name)\") needs a \"level\" between 100 and 400; skipped")
            return nil
        }
        if presets.contains(where: { $0.name.lowercased() == name.lowercased() }) {
            warnings.append("\(label) repeats the name \"\(name)\"; skipped")
            return nil
        }
        if let maxLevel, level > maxLevel {
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
