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

let clamped = parsed(#"{"maxLevel": 500, "keyStep": 0}"#)
expect(clamped.maxLevel == 400 && clamped.keyStep == 0.5 && clamped.warnings.count == 2,
       "out-of-range numbers are clamped with a warning each")
expect(parsed(#"{"maxLevel": 100}"#).maxLevel == nil, "a ceiling of 100 would disable the app and is refused")
expect(Config().maxLevel == nil, "the default ceiling is the panel's own")
let autoLevel = parsed(#"{"maxLevel": "auto"}"#)
expect(autoLevel.maxLevel == nil && autoLevel.warnings.isEmpty, "\"auto\" is the panel's own ceiling")
expect(parsed(#"{"maxLevel": 230}"#).maxLevel == 230, "a ceiling above 160 is accepted")

let wrongTypes = parsed(#"{"maxLevel": "high", "brightnessKeys": 1, "language": "fr", "presets": 3, "typo": true}"#)
expect(wrongTypes.maxLevel == nil && wrongTypes.brightnessKeys && wrongTypes.language == "auto" &&
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

BoostLevel.userCap = 1.3
expect(abs(BoostLevel(1.6).factor - 1.3) < 0.0001, "levels stop at the user's maxLevel")
expect(
    abs(BoostCalibration.gammaFactor(level: BoostLevel(1.3), currentEDR: 4) -
        (1 + 0.553125 * 0.5)) < 0.0001,
    "a lower ceiling does not rescale the calibration curve"
)
BoostLevel.userCap = 9
expect(BoostLevel.cap == BoostLevel.maximum, "the ceiling can never exceed the panel's maximum")
BoostLevel.maximum = 2.44
expect(abs(BoostLevel(2.2).factor - 2.2) < 0.0001, "a measured panel ceiling allows levels above 160%")
expect(abs(BoostLevel(3).factor - 2.44) < 0.0001, "levels stop at the measured panel ceiling")
expect(abs(BuiltInBrightnessScale.top - 244) < 0.001, "the scale's top follows the panel")
BoostLevel.maximum = 99
expect(BoostLevel.maximum == BoostLevel.absoluteMaximum, "no panel goes above the hard limit")
BoostLevel.maximum = BoostLevel.classicMaximum

// MARK: Panel ceiling

expect(PanelCeiling.level(headroom: 2.67) == 2.44, "2.67x headroom less the 9% white correction is 244%")
expect(PanelCeiling.level(headroom: 1.0) == nil, "no headroom, no ceiling")
expect(PanelCeiling.level(headroom: .nan) == nil, "a broken reading is ignored")
expect(PanelCeiling.level(headroom: 16) == BoostLevel.absoluteMaximum, "a huge headroom stops at the hard limit")

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

// MARK: Built-in brightness scale (one 0–160% scale)

expect(BuiltInBrightnessScale.top == 160, "the built-in scale tops out at 160%")
expect(BuiltInBrightnessScale.percent(backlight: 0.5, boost: BoostLevel(1.4), boosting: false) == 50,
       "below the boost the position is the backlight")
expect(abs(BuiltInBrightnessScale.percent(backlight: 1, boost: BoostLevel(1.4), boosting: true) - 140) < 0.001,
       "while boosting the position is the boost level")
expect(BuiltInBrightnessScale.next(from: 100, direction: .increase, step: 6.25, top: 160) == 106.25,
       "F2 at 100% enters the boost")
expect(BuiltInBrightnessScale.next(from: 106.25, direction: .decrease, step: 6.25, top: 160) == 100,
       "F1 leaves the boost at exactly 100%")
expect(BuiltInBrightnessScale.next(from: 93.75, direction: .increase, step: 6.25, top: 160) == 100,
       "F2 below 100% stops at 100% on the way up")
expect(BuiltInBrightnessScale.next(from: 156.25, direction: .increase, step: 6.25, top: 160) == 160,
       "F2 stops at the top")
expect(BuiltInBrightnessScale.next(from: 0, direction: .decrease, step: 6.25, top: 160) == 0, "F1 stops at 0%")
expect(BuiltInBrightnessScale.next(from: 100, direction: .increase, step: 6.25, top: 100) == 100,
       "a display that cannot boost stops at 100%")
expect(BuiltInBrightnessScale.next(from: 47.3, direction: .increase, step: 6.25, top: 160) == 50,
       "an off-grid backlight snaps to the next step")
expect(BuiltInBrightnessScale.next(from: 100, direction: .decrease, step: 1.5625, top: 160) == 98.4375,
       "fine steps are a quarter step")
var position = 0.0
var stepsUp = 0
while position < 160 { position = BuiltInBrightnessScale.next(from: position, direction: .increase, step: 6.25, top: 160); stepsUp += 1 }
expect(stepsUp == 26, "0% to 160% is 16 steps of backlight and 10 of boost")
expect(BuiltInBrightnessScale.split(80) == (0.8, nil), "below 100% only the backlight moves")
expect(BuiltInBrightnessScale.split(100) == (1, nil), "100% is full backlight without boost")
expect(BuiltInBrightnessScale.split(125).backlight == 1 && BuiltInBrightnessScale.split(125).boost == 1.25,
       "above 100% the backlight is full and the rest is boost")
let fills = BuiltInBrightnessScale.segmentFills(percent: 105, top: 160)
expect(fills.count == 16 && fills[9] == 1 && abs(fills[10] - 0.5) < 0.0001 && fills[11] == 0,
       "the 16 segments cover 0–160%, 10% each")
expect(BuiltInBrightnessScale.segmentFills(percent: 160, top: 160).allSatisfy { $0 == 1 }, "all segments are full at the top")
expect(BuiltInBrightnessScale.segmentFills(percent: 0, top: 160).allSatisfy { $0 == 0 }, "no segment is lit at 0%")
expect(BuiltInBrightnessScale.backlightDropEndsBoost(previous: 1, current: 0.5), "a clear backlight drop ends the boost")
expect(!BuiltInBrightnessScale.backlightDropEndsBoost(previous: 1, current: 0.97), "a tiny backlight wobble keeps the boost")
expect(!BuiltInBrightnessScale.backlightDropEndsBoost(previous: 0.5, current: 0.9), "a backlight rise never ends the boost")

// MARK: Boost method

expect(BoostMethod.automatic(major: 27, minor: 2) == .direct, "macOS 27.2 drives the panel directly")
expect(BoostMethod.automatic(major: 28, minor: 0) == .direct, "later macOS drives the panel directly")
expect(BoostMethod.automatic(major: 27, minor: 1) == .classic, "macOS 27.1 keeps the classic gamma boost")
expect(BoostMethod.automatic(major: 15, minor: 6) == .classic, "older macOS keeps the classic gamma boost")
expect(parsed(#"{"boostMethod": "classic"}"#).resolvedBoostMethod(os: OperatingSystemVersion(majorVersion: 27, minorVersion: 2, patchVersion: 1)) == .classic,
       "the config can force the classic method")
expect(parsed(#"{"boostMethod": "overlay"}"#).resolvedBoostMethod(os: OperatingSystemVersion(majorVersion: 15, minorVersion: 0, patchVersion: 0)) == .overlay,
       "the config can force the overlay method")
expect(parsed("{}").resolvedBoostMethod(os: OperatingSystemVersion(majorVersion: 27, minorVersion: 2, patchVersion: 1)) == .direct,
       "auto picks the overlay on macOS 27.2")
expect(parsed(#"{"boostMethod": "bright"}"#).warnings.count == 1, "an unknown boost method warns")
expect(parsed(#"{"boostMethod": "panel"}"#).warnings.count == 1, "the withdrawn panel method warns")
expect(EDRWhiteCorrection.value(sincePeak: nil) == 1, "no correction while the backlight ramps up")
expect(EDRWhiteCorrection.value(sincePeak: 0) == 1, "no correction yet as the backlight nears its peak")
expect(abs(EDRWhiteCorrection.value(sincePeak: 0.125) - 1.045) < 0.0001, "half way through, half the correction")
expect(EDRWhiteCorrection.value(sincePeak: 2) == EDRWhiteCorrection.full, "the full correction once macOS has dimmed white")
expect(EDRWhiteCorrection.isAtPeak(panelNits: 1599, peakNits: 1600), "1599 of 1600 nits is the peak")
expect(EDRWhiteCorrection.isAtPeak(panelNits: 1500, peakNits: 1600), "the last ~70 ms of the ramp count, for the layer's latency")
expect(!EDRWhiteCorrection.isAtPeak(panelNits: 1300, peakNits: 1600), "a backlight still ramping is not")
expect(!EDRWhiteCorrection.isAtPeak(panelNits: 722, peakNits: nil), "without a known peak, a standard level is not")

// MARK: Direct panel boost

expect(DirectPanel.targetNits(standard: 600, level: 1.5, ceiling: 1000) == 900, "150% of 600 nits is 900")
expect(DirectPanel.targetNits(standard: 600, level: 2.4, ceiling: 1000) == 1000, "the ceiling holds")
expect(DirectPanel.targetNits(standard: 720, level: 1, ceiling: 1000) == 720, "100% is standard white")
expect(DirectPanel.targetNits(standard: 1100, level: 1.2, ceiling: 1000) == 1100, "a ceiling below standard white never dims")
expect(DirectPanel.targetNits(standard: 0, level: 1.5, ceiling: 1000) == nil, "no standard white, no target")
expect(DirectPanel.maximumLevel(standard: 600, ceiling: 1000) == 1.66, "1000 nits over 600 is 166%")
expect(DirectPanel.maximumLevel(standard: 720, ceiling: 1000) == 1.38, "brighter surroundings leave less room")
expect(DirectPanel.maximumLevel(standard: 1000, ceiling: 1000) == nil, "no room above standard white")
expect(Config().maxNits == 1000, "the direct ceiling is 1000 nits by default")
expect(parsed(#"{"maxNits": 1200}"#).maxNits == 1200, "maxNits can be raised to 1300")
let tooBright = parsed(#"{"maxNits": 1600}"#)
expect(tooBright.maxNits == 1300 && tooBright.warnings.count == 1, "maxNits stops at 1300 with a warning")
expect(parsed(#"{"boostMethod": "direct"}"#).boostMethod == "direct", "direct is a method name")

// MARK: Panel support across models
//
// Readings as each model reports them. The 16" M1 Max (MacBookPro18,2) row is
// read from a real one on macOS 27.2; the rest follow Apple's published panel
// specifications (1600-nit XDR peak; standard white 500 nits on M1/M2, 600 on
// M3 and later, up to 1000 outdoors on M4 and later) and are not measured.

struct SimulatedMac {
    let name: String
    let readings: PanelReadings
    let supported: Bool
    let direct: Bool
    let standard: Double?
    let top: Float?   // DirectPanel.maximumLevel under the default ceiling
}

func xdr(cap: Double, system: Double? = nil, peak: Double? = 1600, headroom: Double = 16) -> PanelReadings {
    PanelReadings(hasBuiltInDisplay: true, potentialHeadroom: headroom, peakNits: peak,
                  capNits: cap, systemStandardNits: system ?? cap)
}

let simulatedMacs: [SimulatedMac] = [
    SimulatedMac(name: "16\" M1 Max (measured)", readings: xdr(cap: 500), supported: true, direct: true, standard: 500, top: 2.0),
    SimulatedMac(name: "14\" M1 Pro", readings: xdr(cap: 500), supported: true, direct: true, standard: 500, top: 2.0),
    SimulatedMac(name: "16\" M2 Max", readings: xdr(cap: 500), supported: true, direct: true, standard: 500, top: 2.0),
    SimulatedMac(name: "14\" M3", readings: xdr(cap: 600), supported: true, direct: true, standard: 600, top: 1.66),
    SimulatedMac(name: "16\" M3 Max", readings: xdr(cap: 600), supported: true, direct: true, standard: 600, top: 1.66),
    SimulatedMac(name: "14\" M4 Pro, bright room", readings: xdr(cap: 720), supported: true, direct: true, standard: 720, top: 1.38),
    SimulatedMac(name: "16\" M4 Max, outdoors", readings: xdr(cap: 1000), supported: true, direct: true, standard: 1000, top: nil),
    SimulatedMac(name: "14\" M5, HDR video playing", readings: xdr(cap: 1600, system: 600), supported: true, direct: true, standard: 600, top: 1.66),
    SimulatedMac(name: "XDR, HDR video, no CoreBrightness", readings: PanelReadings(hasBuiltInDisplay: true, potentialHeadroom: 16, peakNits: 1600, capNits: 1600, systemStandardNits: nil), supported: true, direct: false, standard: nil, top: nil),
    SimulatedMac(name: "XDR without a readable framebuffer", readings: PanelReadings(hasBuiltInDisplay: true, potentialHeadroom: 16, peakNits: nil, capNits: nil, systemStandardNits: 600), supported: true, direct: false, standard: nil, top: nil),
    SimulatedMac(name: "MacBook Air M2", readings: xdr(cap: 500, peak: 500, headroom: 1.6), supported: false, direct: false, standard: 500, top: nil),
    SimulatedMac(name: "13\" MacBook Pro M2", readings: xdr(cap: 500, peak: 500, headroom: 1.6), supported: false, direct: false, standard: 500, top: nil),
    SimulatedMac(name: "Intel 16\" MacBook Pro", readings: PanelReadings(hasBuiltInDisplay: true, potentialHeadroom: 1, peakNits: nil, capNits: nil, systemStandardNits: nil), supported: false, direct: false, standard: nil, top: nil),
    SimulatedMac(name: "Lid closed, external display only", readings: PanelReadings(hasBuiltInDisplay: false, potentialHeadroom: 1, peakNits: nil, capNits: nil, systemStandardNits: nil), supported: false, direct: false, standard: nil, top: nil),
]

for mac in simulatedMacs {
    let r = mac.readings
    expect((PanelSupport.verdict(r) == .supported) == mac.supported, "\(mac.name): supported is \(mac.supported)")
    expect(PanelSupport.canDriveDirectly(r) == mac.direct, "\(mac.name): direct is \(mac.direct)")
    if mac.supported {
        expect(PanelSupport.standardWhite(r) == mac.standard, "\(mac.name): standard white \(String(describing: mac.standard))")
        let ceiling = PanelSupport.ceiling(configured: DirectPanel.defaultCeiling, peakNits: r.peakNits)
        let top = mac.standard.flatMap { DirectPanel.maximumLevel(standard: $0, ceiling: ceiling) }
        expect(top == mac.top, "\(mac.name): top of the scale \(String(describing: mac.top))")
        if mac.direct, let limit = PanelSupport.writeLimit(peakNits: r.peakNits), let standard = mac.standard {
            for level: Float in [1, 1.5, 2, 4] {
                let target = DirectPanel.targetNits(standard: standard, level: level, ceiling: ceiling) ?? 0
                expect(target <= max(ceiling, standard) && target <= limit, "\(mac.name): \(level)x stays within ceiling and peak")
            }
        }
    }
    // Every Mac on macOS 27.2: unsupported or not, the method list never
    // offers `direct` unless the panel can be driven, and never `classic`.
    let methods = PanelSupport.methods(configured: nil, major: 27, minor: 2)
        .filter { $0 != .direct || PanelSupport.canDriveDirectly(r) }
    expect(!methods.isEmpty && !methods.contains(.classic), "\(mac.name): a 27.2 fallback exists and is never classic")
}

expect(PanelSupport.verdict(simulatedMacs[10].readings) == .unsupported(.notXDR(peakNits: 500)), "an Air is refused as not XDR")
expect(PanelSupport.verdict(simulatedMacs[12].readings) == .unsupported(.noHeadroom), "an Intel MacBook Pro has no headroom")
expect(PanelSupport.verdict(simulatedMacs[13].readings) == .unsupported(.noBuiltInDisplay), "a closed lid has no built-in display")
expect(PanelSupport.verdict(xdr(cap: 500, headroom: .nan)) == .unsupported(.noHeadroom), "a broken headroom reading is refused")

// The ceiling follows the panel's peak, never the 14" numbers.
expect(PanelSupport.ceiling(configured: 1000, peakNits: 1600) == 1000, "1600-nit peak: the sustained 1000")
expect(PanelSupport.ceiling(configured: 1300, peakNits: 1600) == 1300, "1600-nit peak: maxNits up to 1300")
expect(PanelSupport.ceiling(configured: 1000, peakNits: 1200) == 975, "a dimmer peak lowers the ceiling to 81% of it")
expect(PanelSupport.ceiling(configured: 1300, peakNits: 2000) == 1300, "a brighter peak never raises the configured ceiling")
expect(PanelSupport.ceiling(configured: 1000, peakNits: nil) == 1000, "an unknown peak keeps the configured ceiling")
expect(PanelSupport.writeLimit(peakNits: 1600) == 1600, "writes stop at the panel's peak")
expect(PanelSupport.writeLimit(peakNits: 2000) == 2000, "a brighter panel has its own peak")
expect(PanelSupport.writeLimit(peakNits: 500) == nil, "nothing is written to a non-XDR panel")
expect(PanelSupport.writeLimit(peakNits: nil) == nil, "nothing is written without a known peak")
expect(PanelSupport.standardWhite(xdr(cap: 1500, system: 1450)) == nil, "a system reading near the peak is not standard white")

// Methods by macOS version and config.
expect(PanelSupport.methods(configured: nil, major: 13, minor: 0) == [.classic], "macOS 13 (the minimum): classic")
expect(PanelSupport.methods(configured: nil, major: 27, minor: 1) == [.classic], "macOS 27.1: classic")
expect(PanelSupport.methods(configured: nil, major: 27, minor: 2) == [.direct, .overlay], "macOS 27.2: direct, then overlay")
expect(PanelSupport.methods(configured: nil, major: 28, minor: 0) == [.direct, .overlay], "later macOS: direct, then overlay")
expect(PanelSupport.methods(configured: .overlay, major: 27, minor: 2) == [.overlay, .direct], "overlay asked for comes first")
expect(PanelSupport.methods(configured: .direct, major: 15, minor: 0) == [.direct, .classic], "direct on older macOS falls back to classic")
expect(PanelSupport.methods(configured: .classic, major: 27, minor: 2) == [.classic], "classic asked for is classic alone")
expect(Config().configuredBoostMethod == nil, "auto is no configured method")
expect(parsed(#"{"boostMethod": "overlay"}"#).configuredBoostMethod == .overlay, "a named method is configured")

if failureCount > 0 {
    exit(1)
}

// overbright report: did the direct boost reach the panel?
expect(BoostCheck.judge(boosted: false, method: "direct", targetNits: 900, panelNits: 600) == .notBoosted, "report: boost off is not checked")
expect(BoostCheck.judge(boosted: true, method: "overlay", targetNits: nil, panelNits: 1600) == .notDirect, "report: overlay cannot be judged from the backlight")
expect(BoostCheck.judge(boosted: true, method: "direct", targetNits: 996, panelNits: 994) == .reached, "report: within 5 nits is reached")
expect(BoostCheck.judge(boosted: true, method: "direct", targetNits: 943, panelNits: 600) == .missed(panel: 600, target: 943), "report: a dropped boost is reported")
expect(BoostCheck.judge(boosted: true, method: "direct", targetNits: nil, panelNits: 600) == .unknown, "report: no target, no verdict")

print("ok: \(checkCount)/\(checkCount) logic checks passed")
