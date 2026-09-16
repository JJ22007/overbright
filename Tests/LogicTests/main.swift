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

if failureCount > 0 {
    exit(1)
}

print("\(checkCount)/\(checkCount) logic checks passed")
