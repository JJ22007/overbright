# Display Boost

A small, local-only macOS menu bar utility that opens the built-in Liquid Retina
XDR display's EDR headroom and applies a bounded gamma-table boost.

## Compatibility & installation

[Download the latest universal app](https://github.com/JJ22007/display-boost-macos/releases/latest).

macOS 13 or later. The universal app contains native arm64 and x86_64 binaries.
Copy `Display Boost.app` from `Display-Boost-universal.zip` into Applications on
each Mac. Enable Accessibility for that copy to use F1/F2.

Boost is enabled according to the built-in display's live EDR capability, not a
Mac model whitelist. Liquid Retina XDR MacBook Pro displays are the intended
hardware. A non-EDR panel shows an unsupported state and keeps native brightness
keys working. Intel compatibility means the app can run, not that an older LCD
can acquire XDR brightness. Percentage is a requested boost, not measured nits;
the applied gain is limited by current EDR headroom and a conservative curve.
See Apple's [EDR capability documentation](https://developer.apple.com/documentation/appkit/nsscreen/maximumpotentialextendeddynamicrangecolorcomponentvalue).

The current download is locally/ad-hoc signed, not Apple notarized. macOS may
require Open Anyway in Privacy & Security after the first launch attempt, and
Accessibility may need reauthorization after an update. For distribution with a
Developer ID certificate, set `DISPLAYBOOST_SIGN_IDENTITY` when packaging; Apple
notarization is a separate step. Do not disable Gatekeeper system-wide.

## Reliability

Version 1.3 follows native backlight changes without turning off EDR or forcing
the backlight back to maximum. Ambient-light adjustments and Control Center
changes no longer cancel boost. Recovery after sleep/profile changes also uses
the current native level. This preserves the boost setting, not constant physical
brightness: system dimming and thermal/EDR limits still apply. The latest native
change is recorded in `lastBacklightEvent`. Keyboard-listener interruptions do
not disable menu-selected boost; persistently unreadable backlight still stops safely.

Version 1.2 resumes after sleep and safely re-baselines after a changed color
profile. Identical-profile notifications are ignored; error states can be retried
from the slider. User or system backlight reductions still take precedence so
F1 and automatic brightness do not fight the app. A fresh launch starts disabled.
The status menu is intentionally small; hover an error status for details.

CI builds and packages both architectures and runs hardware-independent tests.
The opt-in `--hardware-self-test` also exercises nested sleep/wake, duplicate
profile notifications, injected changed-profile recovery and apply/restore on a
real screen. These tests do not constitute testing every MacBook Pro model.
State changes are logged under `local.jjxu.DisplayBoost` / `Recovery`, with the
latest state also stored in `lastBoostState` and `lastBoostStateAt` preferences.

## Usage

1. Open **Display Boost.app**.
2. Click the sun icon in the menu bar.
3. Choose **开启增亮**, or move the slider to enable automatically, then adjust
   **增亮强度**.
4. Choose **恢复标准亮度** or quit the app to restore the original display state.

F1/F2 keep their normal macOS behaviour from 0–100%. At the top of the native
range, F2 continues into the XDR range in 6.25% steps up to 160%; F1 walks back
through the same range. macOS requires one-time Accessibility permission so the
app can consume those brightness-key events instead of adjusting the backlight a
second time. Until permission is granted, the keys pass through to macOS unchanged;
if the native backlight moves while boost is active, Display Boost follows that
new system brightness while keeping the extra boost enabled. F1/F2 with permission
adjust the extra boost first, then return to native control without a brightness jump.

The 1600-nit specification is a localized HDR peak, not a sustainable full-screen
brightness. Higher brightness uses more power, produces more heat, and can increase
normal backlight wear.

Enabling the boost temporarily moves the native backlight to 100%; the 100–160%
slider controls the extra EDR/gamma mapping above the normal SDR range. The app
restores the original backlight setting unless a newer native adjustment was
observed; in that case it preserves the newer setting on disable, sleep, or quit.

Do not run it at the same time as BetterDisplay, BrightIntosh, BrightXDR, Lunar,
f.lux, or another utility that changes the display gamma table. This app refuses to
enable when it detects an already-boosted gamma endpoint. Gamma remapping can also
compress or clip highlight detail in HDR photos and video, so restore standard
brightness for color-critical or HDR mastering work.

## Build

```sh
./script/test_logic.sh
./script/build_and_run.sh --verify
./script/package_release.sh
```

## Releases

Increment `CFBundleShortVersionString` and `CFBundleVersion` in
`Support/Info.plist`, update `RELEASE_NOTES.md`, then push to `main`. The release
workflow tests and builds both architectures and publishes a versioned ZIP and
SHA-256 checksum to GitHub Releases. Existing releases are never overwritten.
