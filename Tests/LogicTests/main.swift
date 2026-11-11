import Foundation

private var failureCount = 0
private var checkCount = 0

private func expect(_ condition: @autoclosure () -> Bool, _ name: String) {
    checkCount += 1
    if condition() {
        print("PASS: \(name)")
    } else {
        failureCount += 1
        print("FAIL: \(name)")
    }
}

expect(BoostLevel(0.2).factor == 1, "level clamps below minimum")
expect(abs(BoostLevel(3).factor - 1.60) < 0.0001, "level clamps above maximum")
expect(BoostLevel(1.254).percentage == 125, "percentage rounds down")
expect(BoostLevel(1.256).percentage == 126, "percentage rounds up")
expect(BoostState.engaging.isRunning, "engaging state is running")
expect(BoostState.active.isRunning, "active state is running")
expect(!BoostState.off.isRunning, "off state is not running")
expect(!BoostState.unavailable("test").isRunning, "error state is not running")

let calibratedMaximum = BoostCalibration.gammaFactor(
    level: BoostLevel(1.60),
    currentEDR: 4
)
expect(
    abs(calibratedMaximum - 1.553125) < 0.0001,
    "M1 XDR maximum uses conservative dynamic factor"
)
expect(
    abs(BoostCalibration.gammaFactor(level: BoostLevel(1), currentEDR: 4) - 1) < 0.0001,
    "minimum level has no gamma boost"
)

expect(
    abs(BrightnessKeyStep.nextBoostLevel(
        from: 1,
        direction: .increase,
        fineGrained: false
    ).factor - 1.0625) < 0.0001,
    "F2 crosses from 100 to 106.25 percent"
)
expect(
    abs(BrightnessKeyStep.nextBoostLevel(
        from: 1.6,
        direction: .decrease,
        fineGrained: false
    ).factor - 1.5625) < 0.0001,
    "F1 leaves the off-grid 160 percent endpoint correctly"
)
expect(
    BrightnessKeyStep.nextBoostLevel(
        from: 1.0625,
        direction: .decrease,
        fineGrained: false
    ).factor == 1,
    "F1 crosses from boost to native maximum"
)
expect(
    BrightnessKeyStep.nextBoostLevel(
        from: 1.6,
        direction: .increase,
        fineGrained: false
    ).factor == 1.6,
    "F2 clamps at 160 percent"
)
expect(
    abs(BrightnessKeyStep.nextBoostLevel(
        from: 1,
        direction: .increase,
        fineGrained: true
    ).factor - 1.015625) < 0.0001,
    "option-shift F2 uses a fine step"
)
expect(
    abs(BrightnessKeyStep.nextBoostLevel(
        from: 1.33,
        direction: .increase,
        fineGrained: false
    ).factor - 1.375) < 0.0001,
    "F2 advances an off-grid slider value"
)

let brightnessUpDown = BrightnessMediaKeyEvent.decode(
    subtype: 8,
    data1: (2 << 16) | (0x0A << 8)
)
expect(
    brightnessUpDown?.direction == .increase &&
        brightnessUpDown?.phase == .keyDown,
    "decodes brightness-up key-down"
)
let brightnessDownRepeat = BrightnessMediaKeyEvent.decode(
    subtype: 8,
    data1: (3 << 16) | (0x0A << 8) | 1
)
expect(
    brightnessDownRepeat?.direction == .decrease &&
        brightnessDownRepeat?.phase == .keyDown,
    "decodes repeated brightness-down as another key-down"
)
expect(
    BrightnessMediaKeyEvent.decode(
        subtype: 8,
        data1: (2 << 16) | (0x0B << 8)
    )?.phase == .keyUp,
    "decodes brightness key-up"
)
expect(
    BrightnessMediaKeyEvent.decode(
        subtype: 7,
        data1: (2 << 16) | (0x0A << 8)
    ) == nil && BrightnessMediaKeyEvent.decode(
        subtype: 8,
        data1: (7 << 16) | (0x0A << 8)
    ) == nil,
    "ignores unrelated system events"
)

let profileA = ColorProfileIdentity(
    iccProfileData: Data([1, 2, 3]),
    fallbackName: "Display P3"
)
expect(
    profileA.matches(ColorProfileIdentity(
        iccProfileData: Data([1, 2, 3]),
        fallbackName: "Transient EDR name"
    )),
    "identical ICC data ignores transient color-space notification"
)
expect(
    !profileA.matches(ColorProfileIdentity(
        iccProfileData: Data([3, 2, 1]),
        fallbackName: "Display P3"
    )),
    "changed ICC data is detected"
)
expect(
    ColorProfileIdentity(iccProfileData: nil, fallbackName: "Display P3")
        .matches(ColorProfileIdentity(
            iccProfileData: nil,
            fallbackName: "Display P3"
        )),
    "profile name is used when ICC data is unavailable"
)
expect(
    profileA.matches(ColorProfileIdentity(
        iccProfileData: nil,
        fallbackName: "Display P3"
    )),
    "temporary missing ICC data falls back to profile name"
)

expect(BoostLevel(.nan).factor == 1, "invalid saved level safely defaults to standard")
var sequence = BrightnessKeySequence()
sequence.recordDown(code: 2, consumed: false)
sequence.recordDown(code: 2, consumed: true)
expect(!sequence.consumeRelease(code: 2), "held F2 crossing 100 percent still releases system HUD")
sequence.recordDown(code: 3, consumed: true)
sequence.recordDown(code: 3, consumed: false)
expect(!sequence.consumeRelease(code: 3), "held F1 crossing below boost still releases native key")
sequence.recordDown(code: 2, consumed: true)
expect(sequence.consumeRelease(code: 2), "fully intercepted gesture consumes its release")
expect(!sequence.consumeRelease(code: 2), "unmatched key-up passes through")
for headroom: Float in [1, 1.1, 1.3, 2, 4, 8, 16] {
    let value = BoostCalibration.gammaFactor(level: BoostLevel(1.6), currentEDR: headroom)
    expect(value >= 1 && value <= headroom, "gamma respects available EDR \(headroom)")
}
expect(BoostCalibration.gammaFactor(level: BoostLevel(1.6), currentEDR: .nan) == 1,
       "invalid headroom does not boost")

var backlight = BacklightObservation()
expect(backlight.observe(1, now: 0) == .ready, "full backlight ready")
expect(backlight.observe(0.99, now: 1) == .ready, "small native change retains boost")
expect(backlight.observe(1, now: 1.2) == .ready, "transient fluctuation recovers")
expect(backlight.observe(nil, now: 2) == .pending, "temporary read failure tolerated")
expect(backlight.observe(1, now: 2.2) == .ready, "read recovery resets deadline")
expect(backlight.observe(0.99, now: 3) == .ready, "fine adjustment retains boost")
expect(backlight.observe(0.9795198, now: 4.1) == .ready, "reported 97.95 percent backlight no longer disables boost")
backlight.reset()
expect(backlight.observe(0.7, now: 5) == .ready, "large native changes retain boost without writing backlight")
expect(backlight.observe(nil, now: 6) == .pending, "unknown reading begins bounded wait")
expect(backlight.observe(.nan, now: 7.1) == .unavailable, "persistent invalid reading stops safely")
backlight.reset()
expect(backlight.observe(0, now: 20) == .ready, "zero native brightness remains valid")

// MARK: Config

func parsed(_ json: String) -> Config {
    if case let .success(config) = Config.parse(Data(json.utf8)) { return config }
    return Config()
}

let defaults = parsed("{}")
expect(defaults == Config() && defaults.warnings.isEmpty, "empty config is the defaults with no warnings")
if case let .success(roundTrip) = Config.parse(Data(Config().json.utf8)) {
    expect(roundTrip == Config(), "default config file round-trips")
} else {
    expect(false, "default config file round-trips")
}
if case .failure = Config.parse(Data("{ nope".utf8)) {
    expect(true, "broken JSON is an error, not a crash")
} else {
    expect(false, "broken JSON is an error, not a crash")
}
if case .failure(.notAnObject) = Config.parse(Data("[1]".utf8)) {
    expect(true, "a non-object config is rejected")
} else {
    expect(false, "a non-object config is rejected")
}

let partial = parsed(#"{"maxLevel": 130, "showPercentage": true}"#)
expect(partial.maxLevel == 130 && partial.showPercentage && partial.keyStep == 6.25 && partial.warnings.isEmpty,
       "unlisted options keep their defaults")

let clamped = parsed(#"{"maxLevel": 400, "keyStep": 0}"#)
expect(clamped.maxLevel == 160 && clamped.keyStep == 0.5 && clamped.warnings.count == 2,
       "out-of-range numbers are clamped with a warning each")
expect(parsed(#"{"maxLevel": 100}"#).maxLevel == 160, "a ceiling of 100 would disable the app and is refused")

let wrongTypes = parsed(#"{"maxLevel": "high", "brightnessKeys": 1, "language": "fr", "presets": 3, "typo": true}"#)
expect(wrongTypes.maxLevel == 160 && wrongTypes.brightnessKeys && wrongTypes.language == "auto" &&
       wrongTypes.presets.isEmpty && wrongTypes.warnings.count == 5,
       "wrong types and unknown keys warn and fall back")
expect(parsed(#"{"maxLevel": true}"#).warnings.count == 1, "a boolean is not accepted as a number")

let withPresets = parsed(#"""
{"maxLevel": 140, "presets": [
  {"name": "Shade", "level": 115},
  {"name": "shade", "level": 120},
  {"name": "", "level": 120},
  {"name": "Dim", "level": 90},
  {"name": "Outdoors", "level": 160},
  "nope"
]}
"""#)
expect(withPresets.presets.map(\.name) == ["Shade", "Outdoors"], "bad presets are skipped, good ones kept")
expect(withPresets.warnings.count == 5, "each skipped or capped preset is reported")
expect(withPresets.preset(named: "OUT")?.name == "Outdoors", "presets match by case-insensitive prefix")
expect(withPresets.preset(named: "shade")?.level == 115, "an exact preset name wins")
expect(withPresets.preset(named: "nothing") == nil, "an unknown preset is nil")
expect(parsed(#"{"language": "ZH"}"#).language == "zh", "language is case-insensitive")

// MARK: User ceiling and custom key steps

BoostLevel.cap = 1.3
expect(abs(BoostLevel(1.6).factor - 1.3) < 0.0001, "levels stop at the user's maxLevel")
expect(
    abs(BoostCalibration.gammaFactor(level: BoostLevel(1.3), currentEDR: 4) -
        (1 + 0.553125 * 0.5)) < 0.0001,
    "a lower ceiling does not rescale the calibration curve"
)
BoostLevel.cap = 9
expect(BoostLevel.cap == BoostLevel.maximum, "the ceiling can never exceed the calibrated maximum")
BoostLevel.cap = BoostLevel.maximum

BrightnessKeyStep.coarse = 0.07
expect(
    abs(BrightnessKeyStep.nextBoostLevel(from: 1, direction: .increase, fineGrained: false).factor - 1.07) < 0.0001,
    "a custom key step is counted from 100 percent"
)
expect(
    BrightnessKeyStep.nextBoostLevel(from: 1.07, direction: .decrease, fineGrained: false).factor == 1,
    "a custom key step returns exactly to 100 percent"
)
BrightnessKeyStep.coarse = BrightnessKeyStep.defaultCoarse

// MARK: DDC/CI packets

expect(DDC.getRequest(code: 0x10) == [0x82, 0x01, 0x10, 0xAC], "get-brightness request matches the DDC/CI spec")
expect(DDC.setRequest(code: 0x10, value: 70) == [0x84, 0x03, 0x10, 0x00, 0x46, 0xEE], "set-brightness request carries value and checksum")
expect(DDC.setRequest(code: 0x10, value: 0x0123)[3...4] == [0x01, 0x23], "16-bit values are sent high byte first")
// Captured from a Dell P2723DE at 100 of 100.
let dellReply: [UInt8] = [0x6E, 0x88, 0x02, 0x00, 0x10, 0x00, 0x00, 0x64, 0x00, 0x64, 0xA4, 0x5F]
expect(DDC.parseReply(dellReply, code: 0x10).map { $0.current == 100 && $0.maximum == 100 } ?? false,
       "a real display reply parses")
var corrupted = dellReply
corrupted[9] = 0x46
expect(DDC.parseReply(corrupted, code: 0x10) == nil, "a reply with a bad checksum is rejected")
var unsupported = dellReply
unsupported[3] = 0x01
expect(DDC.parseReply(unsupported, code: 0x10) == nil, "an unsupported-feature reply is rejected")
expect(DDC.parseReply(dellReply, code: 0x12) == nil, "a reply for another feature is rejected")
expect(DDC.parseReply([UInt8](repeating: 0, count: 12), code: 0x10) == nil, "silence is not a reading")

// MARK: External brightness

expect(ExternalBrightness.next(from: 100, direction: .decrease, step: 6.25) == 93.75, "Control+F1 steps down from 100")
expect(ExternalBrightness.next(from: 6.25, direction: .decrease, step: 6.25) == 0, "Control+F1 reaches exactly 0")
expect(ExternalBrightness.next(from: 0, direction: .decrease, step: 6.25) == 0, "Control+F1 stops at 0")
expect(ExternalBrightness.next(from: 70, direction: .increase, step: 6.25) == 75, "Control+F2 snaps an off-grid level to the next step")
expect(ExternalBrightness.next(from: 98, direction: .increase, step: 6.25) == 100, "Control+F2 stops at 100")
expect(ExternalBrightness.ddcValue(level: 70, maximum: 100) == 70, "percent maps to a 0-100 display")
expect(ExternalBrightness.ddcValue(level: 50, maximum: 255) == 128, "percent maps to a display with its own scale")
expect(ExternalBrightness.level(ddcValue: 128, maximum: 255) > 50.1, "a display's scale maps back to percent")
expect(ExternalBrightness.level(ddcValue: 5, maximum: 0) == 100, "a zero maximum does not divide by zero")
expect(ExternalBrightness.softwareFactor(level: 0) == 0.1, "software dimming never goes fully black")
expect(ExternalBrightness.softwareFactor(level: 100) == 1, "software dimming at 100 changes nothing")

// MARK: Extra dimming below the backlight's minimum

let deepest = ExternalBrightness.minimum(software: false, extraDimming: true)
expect(deepest == -90, "extra dimming reaches -90")
expect(ExternalBrightness.minimum(software: false, extraDimming: false) == 0, "without extra dimming the floor is 0")
expect(ExternalBrightness.minimum(software: true, extraDimming: true) == 10, "software-only displays keep their 10 percent floor")
expect(ExternalBrightness.split(60) == (60, 1), "above 0 only the backlight changes")
expect(ExternalBrightness.split(0) == (0, 1), "at 0 the backlight is at its minimum and the picture untouched")
expect(ExternalBrightness.split(-40) == (0, 0.6), "below 0 the backlight stays at 0 and the picture is darkened")
expect(ExternalBrightness.split(-500).factor == 0.1, "extra dimming never goes fully black")
expect(ExternalBrightness.next(from: 0, direction: .decrease, step: 6.25, minimum: deepest) == -6.25,
       "Control+F1 continues past 0 into extra dimming")
expect(ExternalBrightness.next(from: -87.5, direction: .decrease, step: 6.25, minimum: deepest) == -90,
       "Control+F1 stops at the deepest level")
expect(ExternalBrightness.next(from: -6.25, direction: .increase, step: 6.25, minimum: deepest) == 0,
       "Control+F2 comes back to exactly 0")
expect(ExternalBrightness.next(from: 0, direction: .decrease, step: 6.25) == 0,
       "without extra dimming Control+F1 stops at 0")
expect(ExternalBrightness.label(-40) == "\u{2212}40%" && ExternalBrightness.label(60) == "60%",
       "levels below 0 are labelled with a minus sign")
expect(!parsed(#"{"extraDimming": false}"#).extraDimming, "extra dimming can be turned off")

let externalOptions = parsed(#"{"externalDisplays": false, "externalKeys": false, "showHUD": false}"#)
expect(!externalOptions.externalDisplays && !externalOptions.externalKeys && !externalOptions.showHUD &&
       externalOptions.warnings.isEmpty, "external display options decode")
expect(Config().externalDisplays && Config().externalKeys && Config().showHUD, "external displays are on by default")

if failureCount > 0 {
    exit(1)
}

print("ok: \(checkCount)/\(checkCount) logic checks passed")
