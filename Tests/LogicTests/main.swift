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
expect(DirectPanel.holdsHeadroom(enabled: true, direct: true, backlight: 1, suspended: false), "the headroom is held at full backlight, before the boost")
expect(DirectPanel.holdsHeadroom(enabled: true, direct: true, backlight: 0.5, suspended: false), "and from half backlight up")
expect(!DirectPanel.holdsHeadroom(enabled: true, direct: true, backlight: 0.4, suspended: false), "not in the lower half")
expect(!DirectPanel.holdsHeadroom(enabled: true, direct: true, backlight: nil, suspended: false), "not without a backlight reading")
expect(!DirectPanel.holdsHeadroom(enabled: false, direct: true, backlight: 1, suspended: false), "never with holdHeadroom off")
expect(!DirectPanel.holdsHeadroom(enabled: true, direct: false, backlight: 1, suspended: false), "only for the direct method")
expect(!DirectPanel.holdsHeadroom(enabled: true, direct: true, backlight: 1, suspended: true), "not while the display sleeps")
expect(Config().holdHeadroom && !parsed(#"{"holdHeadroom": false}"#).holdHeadroom, "config: holdHeadroom is on by default and can be turned off")
expect(DirectPanel.backlight(standard: 600, systemCap: 600 * DirectPanel.heldHeadroom, level: 1.66, ceiling: 1000, hardCeiling: 1296).map { $0 < 1296 } == true, "the held headroom leaves the top of the default scale under the hard ceiling")

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

// Direct method: what to write back when the boost ends.
let stale = DirectPanel.restore(savedCap: 600, systemStandard: 600, currentLevel: 996, peak: 1600)
expect(stale?.cap == 600 && stale?.level == 600, "end: a boosted level comes down to standard white, not to a saved ramp value")
let ambientMoved = DirectPanel.restore(savedCap: 720, systemStandard: 600, currentLevel: 943, peak: 1600)
expect(ambientMoved?.cap == 600 && ambientMoved?.level == 600, "end: standard white as macOS reports it now")
let userDimmed = DirectPanel.restore(savedCap: 600, systemStandard: 600, currentLevel: 300, peak: 1600)
expect(userDimmed?.cap == 600 && userDimmed?.level == nil, "end: a level below standard is macOS's own and is left alone")
let hdrSystem = DirectPanel.restore(savedCap: 600, systemStandard: 1600, currentLevel: 996, peak: 1600)
expect(hdrSystem?.cap == 600, "end: an unbelievable system standard falls back to the saved cap")
expect(DirectPanel.restore(savedCap: nil, systemStandard: nil, currentLevel: 996, peak: 1600) == nil, "end: nothing believable, nothing written")

// overbright report: did the direct boost reach the panel?
expect(BoostCheck.judge(boosted: false, method: "direct", targetNits: 900, panelNits: 600) == .notBoosted, "report: boost off is not checked")
expect(BoostCheck.judge(boosted: true, method: "overlay", targetNits: nil, panelNits: 1600) == .notDirect, "report: overlay cannot be judged from the backlight")
expect(BoostCheck.judge(boosted: true, method: "direct", targetNits: 996, panelNits: 994) == .reached, "report: within 5 nits is reached")
expect(BoostCheck.judge(boosted: true, method: "direct", targetNits: 943, panelNits: 600) == .missed(panel: 600, target: 943), "report: a dropped boost is reported")
expect(BoostCheck.judge(boosted: true, method: "direct", targetNits: nil, panelNits: 600) == .unknown, "report: no target, no verdict")
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

// Direct method: the backlight to write, from the cap macOS itself last set.
func backlight(_ standard: Double, cap: Double, _ level: Float, ceiling: Double = 1000) -> Double? {
    DirectPanel.backlight(standard: standard, systemCap: cap, level: level, ceiling: ceiling, hardCeiling: 1296)
}
expect(backlight(600, cap: 600, 1.25) == 750, "no HDR: the backlight is the wanted white")
expect(backlight(600, cap: 600, 1.66)! > 995 && backlight(600, cap: 600, 1.66)! <= 1000, "no HDR: the top stays under the ceiling")
expect(abs(backlight(600, cap: 720, 1.25)! - 900) < 0.01, "a banner's headroom of 1.2: the backlight is the white times 1.2")
expect(abs(backlight(600, cap: 720, 1.66)! - 996 * 1.2) < 0.5, "a banner at the top of the scale: white keeps its 996 nits")
expect(backlight(600, cap: 720, 1.66)! <= 1296, "HDR headroom never takes the backlight past the hard ceiling")
expect(backlight(600, cap: 900, 1.66) == 1296, "a headroom of 1.5: the backlight stops at the hard ceiling")
expect(backlight(600, cap: 1600, 1.66) == 1600, "HDR video at the peak: macOS's own backlight stands")
expect(backlight(600, cap: 1300, 1.25) == 1300, "macOS's cap above the hard ceiling is never lowered")
expect(backlight(600, cap: 610, 1.25)! > 750 && backlight(600, cap: 610, 1.25)! < 765, "the first steps of macOS's ramp move the backlight smoothly")
expect(backlight(500, cap: 500, 2.0) == 1000 && backlight(500, cap: 600, 2.0) == 1200, "a 500-nit panel: the same rule")
expect(backlight(600, cap: 720, 1.66, ceiling: 800)! == 960, "the ceiling bounds ordinary white, and the headroom is added to it")
expect(backlight(600, cap: 40, 1.25) == nil && backlight(40, cap: 600, 1.25) == nil, "nonsense readings give nothing to write")
for cap in stride(from: 600.0, through: 1600, by: 7) {
    let nits = backlight(600, cap: cap, 1.66)!
    if nits < cap || nits > max(1296, cap) { expect(false, "backlight \(nits) out of bounds at cap \(cap)") }
}

// Direct method: standard white once macOS has stopped changing its cap.
func standardAfter(_ cap: Double, headroom: Double?, previous: Double = 600) -> Double {
    DirectPanel.standard(previous: previous, systemCap: cap, headroom: headroom, ceiling: 1000, peak: 1600)
}
expect(standardAfter(720, headroom: 1.2) == 600, "a banner's cap of 720 with its headroom of 1.2 is still 600")
expect(standardAfter(720, headroom: 1.0) == 720, "a cap with no headroom is a new standard white (brighter room)")
expect(standardAfter(600, headroom: 1.0, previous: 720) == 600, "and a darker room is followed down")
expect(abs(standardAfter(1600, headroom: 2.0) - 800) < 0.01, "at the peak with a headroom of 2, standard white is 800")
expect(abs(standardAfter(1600, headroom: 2.667) - 600) < 0.2, "HDR video at the peak leaves standard white at 600")
expect(standardAfter(1600, headroom: 1.0) == 600, "a cap at the peak is never standard white")
expect(standardAfter(720, headroom: nil) == 720, "without a headroom reading, a cap under the ceiling counts as before")
expect(standardAfter(1600, headroom: nil) == 600, "without a headroom reading, a cap at the peak does not")
expect(standardAfter(30, headroom: 1.0) == 600, "a nonsense cap changes nothing")

// Direct method: macOS driving the backlight below its own cap is the user dimming.
expect(DirectPanel.dimmed(level: 400, systemCap: 600, standard: 600), "400 nits under a 600 cap is dimming")
expect(DirectPanel.dimmed(level: 300, systemCap: 720, standard: 600), "dimming under a banner's cap is still dimming")
expect(!DirectPanel.dimmed(level: 600, systemCap: 720, standard: 600), "the first step of a banner's ramp is not dimming")

// The flashing bug: macOS writes a ramp, one step per frame. A boost that
// writes itself back after every step alternates with macOS on every frame.
// `simulate` plays macOS's writes against a boost polled every `poll` seconds
// and counts the boost's writes. `everyStep` is the build that flashed.
private func simulate(macWrites: [(at: Double, nits: Double)], boost: Double, until end: Double,
                      poll: Double, everyStep: Bool) -> (writes: Int, duringRamp: Int, final: Double) {
    var pacer = DirectPacer()
    var panel = boost
    var written: Double? = boost
    var writes = 0, duringRamp = 0, next = 0
    let rampEnd = macWrites.last?.at ?? 0
    var now = 0.0
    while now <= end {
        while next < macWrites.count, macWrites[next].at <= now {
            panel = macWrites[next].nits
            next += 1
        }
        let write: Bool
        if everyStep {
            write = written.map { abs(panel - $0) > DirectPacer.tolerance } ?? true
        } else {
            write = pacer.poll(cap: panel, level: panel, written: written, now: now)
        }
        if write {
            panel = boost
            written = boost
            writes += 1
            if now <= rampEnd { duringRamp += 1 }
            pacer.applied(wrote: true, now: now)
        }
        now += poll
    }
    return (writes, duringRamp, panel)
}
// A banner: 600 to 720 nits over 1.5 s, one step every 8 ms.
let bannerRamp: [(at: Double, nits: Double)] = (0...187).map { (index: Int) -> (at: Double, nits: Double) in
    let step = Double(index)
    return (at: 1 + step * 0.008, nits: 600 + step * 120 / 187)
}
let flashing = simulate(macWrites: bannerRamp, boost: 996, until: 6, poll: 0.002, everyStep: true)
expect(flashing.writes > 150, "answering every step of macOS's ramp alternates with it on every frame (the flashing)")
let paced = simulate(macWrites: bannerRamp, boost: 996, until: 6, poll: 0.02, everyStep: false)
expect(paced.duringRamp == 0, "pacer: nothing is written while macOS is writing its ramp")
expect(paced.writes == 1 && paced.final == 996, "pacer: one write puts the boost back after the ramp")
// A slow adjustment: macOS writes every 0.3 s for a minute. The wait doubles
// past the gap, so the two do not alternate slowly either.
let slowSteps: [(at: Double, nits: Double)] = (0..<200).map { (index: Int) -> (at: Double, nits: Double) in
    (at: 1 + Double(index) * 0.3, nits: 600 + Double(index % 7))
}
let slow = simulate(macWrites: slowSteps, boost: 996, until: 70, poll: 0.02, everyStep: false)
expect(slow.duringRamp <= 1, "pacer: at most one write gets in between macOS's slow steps")
expect(slow.writes <= 2 && slow.final == 996, "pacer: the boost is back once macOS stops")
// Two banners a few seconds apart are separate takeovers, each answered once.
let leaving: [(at: Double, nits: Double)] = bannerRamp.map { step in (at: step.at + 5, nits: 1320 - step.nits) }
let twoBanners = bannerRamp + leaving
let two = simulate(macWrites: twoBanners, boost: 996, until: 12, poll: 0.02, everyStep: false)
expect(two.writes == 2 && two.final == 996, "pacer: a banner appearing and leaving is two writes")
do {
    var pacer = DirectPacer()
    expect(!pacer.poll(cap: 996, level: 996, written: 996, now: 0), "pacer: the boost's own values need nothing")
    expect(!pacer.poll(cap: 600, level: 600, written: 996, now: 1), "pacer: a takeover is not answered at once")
    expect(!pacer.poll(cap: 600, level: 600, written: 996, now: 1.2), "pacer: nor before macOS has been still long enough")
    expect(pacer.poll(cap: 600, level: 600, written: 996, now: 1.26), "pacer: answered after a quarter of a second of stillness")
    pacer.applied(wrote: true, taken: false, now: 1.26)
    expect(!pacer.poll(cap: 600, level: 600, written: 996, now: 1.3), "pacer: a write macOS did not take waits again")
    expect(pacer.poll(cap: 600, level: 600, written: 996, now: 1.52), "pacer: and is then tried again")
    pacer.applied(wrote: true, now: 1.52)
    _ = pacer.poll(cap: 996, level: 996, written: 996, now: 1.54)
    _ = pacer.poll(cap: 610, level: 610, written: 996, now: 1.8)
    expect(pacer.settle == 0.5, "pacer: taken again within two seconds, the wait doubles")
    expect(!pacer.poll(cap: 610, level: 610, written: 996, now: 2.2) && pacer.poll(cap: 610, level: 610, written: 996, now: 2.31), "pacer: and the longer wait is kept")
    pacer.applied(wrote: true, now: 2.31)
    _ = pacer.poll(cap: 996, level: 996, written: 996, now: 2.33)
    _ = pacer.poll(cap: 600, level: 600, written: 996, now: 9)
    expect(pacer.settle == DirectPacer.shortestSettle, "pacer: a takeover long after the write starts from the short wait")
    // A boost that starts in the middle of a ramp writes nothing until the ramp is over.
    var starting = DirectPacer()
    starting.waitForMacOS(now: 0)
    expect(starting.pending, "pacer: a boost starting in a ramp waits (and a new level is not written meanwhile)")
    expect(!starting.poll(cap: 610, level: 610, written: nil, now: 0.02) && !starting.poll(cap: 620, level: 620, written: nil, now: 0.2), "pacer: it writes nothing while the ramp goes on")
    expect(starting.poll(cap: 620, level: 620, written: nil, now: 0.46), "pacer: and starts once macOS is still")
    // Yielded to macOS (HDR video): its changes are looked at once still, never written over in between.
    var yielded = DirectPacer()
    _ = yielded.poll(cap: 1600, level: 1500, written: nil, now: 0)
    expect(yielded.poll(cap: 1600, level: 1500, written: nil, now: 0.3), "pacer: macOS's own backlight is looked at once it is still")
    yielded.applied(wrote: false, now: 0.3)
    expect(!yielded.poll(cap: 1600, level: 1500, written: nil, now: 0.4), "pacer: and then left alone")
}
expect(!DirectPanel.dimmed(level: 590, systemCap: 600, standard: 600), "a level a little behind the cap is not dimming")
expect(!DirectPanel.dimmed(level: 1000, systemCap: 1600, standard: 600), "the level behind a fast ramp to the peak is not dimming")

// Standard white at the start of a boost, with HDR content already on screen.
expect(PanelSupport.standardWhite(PanelReadings(hasBuiltInDisplay: true, potentialHeadroom: 16, peakNits: 1600, capNits: 720, systemStandardNits: 600, edrHeadroom: 1.2)) == 600, "a banner on screen at the start: standard white is 600, not 720")
expect(PanelSupport.standardWhite(PanelReadings(hasBuiltInDisplay: true, potentialHeadroom: 16, peakNits: 1600, capNits: 720, systemStandardNits: 720, edrHeadroom: 1.0)) == 720, "a bright room at the start: standard white is 720")
expect(PanelSupport.standardWhite(PanelReadings(hasBuiltInDisplay: true, potentialHeadroom: 16, peakNits: 1600, capNits: 1600, systemStandardNits: 600, edrHeadroom: 2.0)) == 800, "the headroom is preferred to the luminance reading when both are there")
expect(PanelSupport.standardWhite(PanelReadings(hasBuiltInDisplay: true, potentialHeadroom: 16, peakNits: 1600, capNits: 720, systemStandardNits: 600)) == 720, "without a headroom reading the cap stands, as before")

// Readback: what an agent is told after a command.
expect(Readback.judge(boosted: true, method: "direct", targetNits: 900, panelNits: 898, capNits: 900) == .reached, "readback: boost at the target is reached")
expect(Readback.judge(boosted: true, method: "direct", targetNits: 900, panelNits: 600, capNits: 900) == .missed, "readback: boost short of the target is missed")
expect(Readback.judge(boosted: true, method: "overlay", targetNits: nil, panelNits: 1600, capNits: 1600) == .notDirect, "readback: an overlay boost cannot be proved from the backlight")
expect(Readback.judge(boosted: false, method: "direct", targetNits: nil, panelNits: 600, capNits: 600) == .restored, "readback: off at standard white is restored")
expect(Readback.judge(boosted: false, method: "direct", targetNits: nil, panelNits: 150, capNits: 600) == .restored, "readback: below 100% is restored")
expect(Readback.judge(boosted: false, method: "overlay", targetNits: nil, panelNits: 1600, capNits: 600) == .notRestored, "readback: backlight still at the peak is not restored")
expect(Readback.judge(boosted: false, method: "direct", targetNits: nil, panelNits: nil, capNits: 600) == .unknown, "readback: no reading is unknown")
expect(Readback.reached.proves && Readback.restored.proves && !Readback.missed.proves && !Readback.notDirect.proves, "readback: only reached and restored prove")

// MCP server, against a fake app.
final class FakeApp {
    var calls: [[String]] = []
    var readbacks: [String]
    init(_ readbacks: [String]) { self.readbacks = readbacks }
    func run(_ args: [String]) -> (code: Int32, output: String) {
        calls.append(args)
        if args.first == "status" {
            let rb = readbacks.count > 1 ? readbacks.removeFirst() : readbacks[0]
            return (0, #"{"state":"on","level":150,"boostMethod":"direct","readback":{"readback":"\#(rb)","panelNits":900,"targetNits":900}}"#)
        }
        if args.first == "report" { return (0, "### report") }
        return (0, "ok")
    }
}
func mcpObject(_ text: String?) -> [String: Any] {
    (text.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) } as? [String: Any]) ?? [:]
}
func mcpResult(_ text: String?) -> [String: Any] { mcpObject(text)["result"] as? [String: Any] ?? [:] }
do {
    let app = FakeApp(["missed", "missed", "reached"])
    var waited = 0.0
    let server = MCPServer(run: app.run, wait: { waited += $0 }, version: "test")
    let initialize = mcpResult(server.handle(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26"}}"#))
    expect(initialize["protocolVersion"] as? String == "2025-03-26", "mcp: answers in the client's protocol version")
    expect(server.handle(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#) == nil, "mcp: notifications get no reply")
    let tools = (mcpResult(server.handle(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#))["tools"] as? [[String: Any]])?.compactMap { $0["name"] as? String }
    expect(tools == ["status", "set_brightness", "restore", "report"], "mcp: lists the four tools")
    let set = mcpResult(server.handle(#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"set_brightness","arguments":{"percent":150}}}"#))
    let setContent = set["structuredContent"] as? [String: Any] ?? [:]
    expect(app.calls.contains(["set", "150.0"]), "mcp: set_brightness runs `set`")
    expect(setContent["readback"] as? String == "reached" && set["isError"] as? Bool == false, "mcp: set_brightness waits for the panel to reach the target")
    expect(waited == 0.5, "mcp: polls until settled")
}
do {
    let app = FakeApp(["missed"])
    let server = MCPServer(run: app.run, wait: { _ in }, version: "test")
    let set = mcpResult(server.handle(#"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"set_brightness","arguments":{"percent":150}}}"#))
    expect(set["isError"] as? Bool == true, "mcp: a boost that never reaches the panel is an error")
    let restore = mcpResult(server.handle(#"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"restore","arguments":{}}}"#))
    expect(app.calls.contains(["off"]) && restore["isError"] as? Bool == true, "mcp: restore runs `off` and fails until restored")
    let unknown = mcpObject(server.handle(#"{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"nope"}}"#))
    expect((unknown["error"] as? [String: Any])?["code"] as? Int == -32602, "mcp: an unknown tool is an invalid-params error")
    let bad = mcpObject(server.handle("not json"))
    expect((bad["error"] as? [String: Any])?["code"] as? Int == -32700, "mcp: bad JSON is a parse error")
}

// lowBatteryOff and toggleShortcut.
let low = LowBattery.Reading(percent: 19, onBattery: true)
let high = LowBattery.Reading(percent: 21, onBattery: true)
let plugged = LowBattery.Reading(percent: 19, onBattery: false)
expect(LowBattery.shouldTurnOff(previous: high, current: low, threshold: 20, boosted: true), "low battery: crossing the threshold ends the boost")
expect(!LowBattery.shouldTurnOff(previous: low, current: LowBattery.Reading(percent: 18, onBattery: true), threshold: 20, boosted: true), "low battery: a boost turned back on below the threshold stays on")
expect(LowBattery.shouldTurnOff(previous: plugged, current: low, threshold: 20, boosted: true), "low battery: unplugging below the threshold ends the boost")
expect(!LowBattery.shouldTurnOff(previous: high, current: plugged, threshold: 20, boosted: true), "low battery: on the adapter nothing happens")
expect(!LowBattery.shouldTurnOff(previous: high, current: low, threshold: 20, boosted: false), "low battery: no boost, nothing to do")
expect(LowBattery.shouldTurnOff(previous: nil, current: low, threshold: 20, boosted: true), "low battery: the first reading counts")
expect(Shortcut.parse("ctrl+opt+cmd+b") == Shortcut(keyCode: 0x0B, modifiers: Shortcut.control | Shortcut.option | Shortcut.command), "shortcut: parses modifiers and a letter")
expect(Shortcut.parse("Cmd + Shift + F12")?.keyCode == 0x6F, "shortcut: F-keys, any case and spacing")
expect(Shortcut.parse("shift+b") == nil, "shortcut: shift alone would take an ordinary key")
expect(Shortcut.parse("cmd+b+c") == nil && Shortcut.parse("cmd+") == nil && Shortcut.parse("cmd+hyper") == nil, "shortcut: one known key")
expect(parsed(#"{"lowBatteryOff": 15, "toggleShortcut": "ctrl+opt+b"}"#).lowBatteryOff == 15, "config: lowBatteryOff is a percentage")
expect(parsed(#"{"toggleShortcut": "ctrl+opt+b"}"#).toggleShortcut == "ctrl+opt+b", "config: toggleShortcut is kept")
expect(parsed(#"{"lowBatteryOff": false, "toggleShortcut": false}"#).lowBatteryOff == nil, "config: false turns them off")
expect(Config(dictionary: ["lowBatteryOff": 2]).lowBatteryOff == 5, "config: lowBatteryOff clamps to 5")
expect(Config(dictionary: ["toggleShortcut": "b"]).warnings.count == 1 && Config(dictionary: ["toggleShortcut": "b"]).toggleShortcut == nil, "config: a bad shortcut is a warning, not a shortcut")
expect(Config(dictionary: ["lowBatteryOff": true]).lowBatteryOff == nil, "config: lowBatteryOff true is a warning")
if case let .success(withAutomation) = Config.parse(Data(Config(dictionary: ["lowBatteryOff": 15, "toggleShortcut": "ctrl+opt+b"]).json.utf8)) {
    expect(withAutomation.lowBatteryOff == 15 && withAutomation.toggleShortcut == "ctrl+opt+b" && withAutomation.warnings.isEmpty, "config: the automation options round-trip")
} else {
    expect(false, "config: the automation options round-trip")
}

if failureCount > 0 {
    print("FAILED: \(failureCount) of \(checkCount) logic checks")
    exit(1)
}
print("ok: \(checkCount)/\(checkCount) logic checks passed")
