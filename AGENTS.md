# AGENTS.md

Instructions for AI coding agents working in this repository. Humans are welcome to read it too.

## What this is

Overbright is a macOS menu bar app that raises a built-in XDR display above 100% brightness by opening EDR headroom and lifting ordinary content into it (a multiplying HDR layer on macOS 27.2+, the gamma table before). It is intentionally small so that a person can fork it and have an agent reshape it into their own tool. Favor small, readable changes over abstractions.

- Language: Swift, built with Swift Package Manager. No Xcode project, no third-party dependencies. Keep it that way.
- Minimum macOS: 13. Both arm64 and x86_64 must keep building.
- English for code, comments, commit messages and docs. `README.zh-CN.md` is a translation of the README; update it when the README changes in substance. Interface text is written in English and Chinese side by side with `L10n.tr("English", "中文")`.

## Build, test, run

```bash
bash scripts/test.sh             # logic tests + validate every examples/*.json
bash scripts/dev.sh              # debug build into dist/Overbright.app and open it
bash scripts/dev.sh --verify     # open, then check it restores and exits on SIGTERM
bash scripts/install.sh          # tests, release build, install to ~/Applications, link the CLI
bash scripts/package_release.sh  # universal zip in outputs/ (what CI and releases run)
bash scripts/setup-signing.sh    # one-time: stable signing identity (the user runs this)
bash scripts/brightness-log.sh --interval 50 --changes   # read-only live brightness readings
bash scripts/light-check.sh                              # real keys, real light (camera); see below
```

`scripts/test.sh` compiles `Sources/Overbright/Models/*.swift` together with `Tests/LogicTests/main.swift` into a plain executable. That is why everything in `Models/` must import only Foundation and must not touch AppKit, the display or `UserDefaults`. Add a check there whenever you add a config field, change a limit, or change key-step arithmetic.

## What you cannot verify yourself

- **Real light, without the user.** Only the camera sees it (see "Measuring brightness"), and the user has to agree to it and to a dark room. Never infer light from the backlight and gamma readings: that model was wrong on macOS 27.2 and passed its own checks anyway.

- **External displays.** `overbright displays` and `overbright display <name> <percent>` reply after the DDC write finished, and the level can be read back independently. That is a real check of DDC, but only on a display that is actually connected; CI has none.
- **The external display indicator.** `"$(swift build --show-bin-path)/Overbright" --preview-hud 70` shows it on the first external display for three seconds (pass a negative level to see extra dimming). Capture it with `screencapture -x -D 2 out.png` and look at the top-right corner.
- **F1/F2.** Intercepting brightness keys needs the Accessibility permission, which only the user can grant in System Settings. The grant is tied to the code signature: with an ad-hoc signature every rebuild invalidates it while the switch can still look on. `scripts/setup-signing.sh` fixes this by creating a local self-signed identity; it writes to the user's login keychain, so ask the user to run it rather than running it yourself. Never try to grant the permission yourself.
- **Other Mac models.** CI has no XDR panel.

What you can verify: `scripts/test.sh`, `overbright check <file>`, `scripts/dev.sh --verify`, and, on a Mac with an XDR display and with the user's agreement, the CLI round trip (`overbright set 120 && overbright status --json && overbright off`). The opt-in `Overbright --hardware-self-test` exercises apply/restore, sleep/wake and profile changes on the real screen; it visibly changes brightness for a few seconds, so ask first.

Logs: `log stream --predicate 'subsystem == "io.github.overbright"'`. The last state is also in `defaults read io.github.overbright`.

## Measuring brightness

Use these instead of asking the user whether something looked brighter. Never write CoreBrightness.

- **`scripts/light-check.sh`: the real check.** It measures emitted light with the Mac's built-in camera while pressing real keys, and passes or fails. The camera faces the user, but the screen lights the user's face and the room, so in a dark room each frame's mean brightness follows the screen within a frame. It shows a black screen with a white patch (10% of the area) for about two minutes, then restores the display. The script runs `scripts/brightness-camera.sh`, which builds a small helper app ("Overbright Light Meter", `.build/BrightnessCamera.app`) so macOS asks for the camera once, for it alone. The helper keeps only numbers (mean luma per frame), never an image. Ask the user before the first run (camera permission, dark room, a couple of minutes of white patch).
  - **Presses.** 10 × F2 then 10 × F1. For each press it reports the direction, the time to 90%, and any overshoot past start or end. A press fails if it moves the wrong way or overshoots by more than 3%.
  - **Ratio.** A null test that does not depend on the camera's response. At boost X the white patch becomes a grey that emits 1/X of white, so the camera must read the same as plain white at the standard 100%. A level fails beyond ±5%.
  - **Release.** The light for 24 s after leaving the boost, as information only.
  - The camera's exposure cannot be locked on a MacBook. Only trust comparisons made within a few seconds of each other; that is why the ratio test is a null test.
- **Real key presses.** `overbright key up|down --real [--control]` makes the running app post a brightness media key at the HID tap. It travels through macOS, Overbright's key tap and its handler, exactly like F1/F2. A shell cannot post one itself (it has no Accessibility). Without `--real`, `overbright key` calls the handler directly.
- **`scripts/brightness-log.sh`: raw readings.** Read-only, safe at any time: backlight slider, standard nits, the backlight in nits macOS is driving (`IOMFBBrightnessLevel`, live through every ramp), EDR headroom and the gamma endpoint. None of these is emitted light.
- **Facts measured on macOS 27.2.1 (14" MacBook Pro).**
  - The gamma table has no effect on emitted light, with or without EDR. A table installed when EDR starts stops macOS from scaling ordinary content, so white goes to the full backlight.
  - A full-screen EDR layer with `compositingFilter = "multiplyBlendMode"` multiplies emitted light exactly. A layer that is drawn once and left alone stops being composited with the filter after about a second and shows as an opaque sheet, so it must keep redrawing. `MultiplyRenderer` draws from its own thread with a dispatch timer (not MTKView, not the main thread: a main-thread timer once let 2.25 s pass between frames in normal use), and the service holds an activity against App Nap. `status --json` reports `overlayMaxFrameGap` (frames that reached the screen; keep it well under a second) and `mainThreadMaxGap`. `defaults write io.github.overbright debugCapturableOverlay -bool true` makes screenshots include the layer (they show the multiply but not the white sheet); `debugStopRedraw` stops the frames for tests. Check this on a black screen, where the failure is obvious; on a white screen it looks like success.
  - macOS dims ordinary white by about 9% once the backlight reaches its EDR peak, not during the ramp (`EDRWhiteCorrection`).
  - A layer change takes about 0.15 s to show (0.4 s at 4 frames per second).
  - The ambient light sensor does not see the screen.
  - SMC `PBLR` is backlight power in watts. It is linear in nits below 100%, but it follows LED drive, not emitted light, so it cannot judge the boost.
- **Indicator.** Capture the top of the screen right after `overbright key up --real` (`screencapture -x -R 0,0,<width>,280`). There must be exactly one indicator, top centre, 16 segments.
- **Leave the display as you found it.** `light-check` does. After anything else, `overbright set 100` and wait about 20 s for macOS to release EDR, then check with `brightness-log.sh --once`.

## Layout of the code

All sources are in `Sources/Overbright/`.

| File | Responsibility |
|---|---|
| `Models/Config.swift` | `Config` and `Preset`: defaults, forgiving decoding, warnings, JSON output |
| `Models/BoostLevel.swift` | `BoostLevel` (clamped level), `BoostCalibration` (percent → gamma factor), `BoostState`, `BoostSnapshot` |
| `Models/BuiltInBrightnessScale.swift` | The 0%-to-ceiling scale (steps, split into backlight and boost, segment fills), `BoostMethod`, `EDRWhiteCorrection` |
| `Models/BrightnessKeyStep.swift` | Boost-only key steps (menu slider, classic paths) |
| `Models/BrightnessMediaKeyEvent.swift` | Decoding the system brightness-key events |
| `Models/BacklightObservation.swift` | Tolerating brief backlight read failures |
| `Models/DDC.swift` | DDC/CI request and reply bytes; `ExternalBrightness` steps and scaling |
| `Models/ColorProfileIdentity.swift` | Telling a real color-profile change from a transient notification |
| `Controllers/BoostController.swift` | The state machine: enable, disable, suspend/resume, recovery |
| `Services/GammaTableService.swift` | Reading, scaling and restoring the gamma table |
| `Services/EDRTriggerService.swift` | The invisible HDR layer that opens EDR headroom (classic method) |
| `Services/EDROverlayService.swift` | The full-screen multiplying HDR layer that is the boost on macOS 27.2+ |
| `Services/DDCService.swift` | IOAVService I2C transport (Apple Silicon, loaded with dlsym) and endpoint discovery |
| `Services/ExternalDisplayManager.swift` | External displays: detection, DDC/macOS/software choice, coalesced writes, software dimming |
| `Services/PanelLightService.swift` | Read-only live backlight nits and the panel's peak, for `EDRWhiteCorrection` |
| `Services/NativeBrightnessService.swift` | Reading and writing the system backlight level |
| `Services/BrightnessKeyService.swift` | The event tap for F1/F2; the only code that needs Accessibility |
| `Services/ConfigStore.swift` | Loads `config.json`, creates it on first run, hot reloads |
| `Services/InstanceLock.swift` | One running copy at a time |
| `Views/MenuBarIcon.swift` | Menu bar glyphs (Lucide SVG, template images): on, off, problem |
| `Views/ScaleHUD.swift` | The one indicator for the built-in display: top centre, sun, 16 dashes over 0% to the ceiling, percentage |
| `Views/BrightnessHUD.swift` | The on-screen indicator for external display changes |
| `Views/StatusItemController.swift` | Menu bar icon and menu, rebuilt on every config change |
| `App/CLI.swift` | The `overbright` command (client) and `CommandServer` (inside the app) |
| `App/AppDelegate.swift` | Start-up, sleep/wake/session observers, applying the config |
| `App/OverbrightApplication.swift` | Entry point; routes CLI commands; the hardware self-test |
| `Support/AppInfo.swift` | Name, bundle identifier, repository URL |
| `Support/L10n.swift` | Language selection |

## Conventions that matter

- **Always restore.** Every path that changes the gamma table, the backlight or the overlay must have a path that puts it back, including on quit, SIGTERM, sleep, a color-profile change and a crash (the `recoveryRequired` marker in `UserDefaults`). If you add a way to turn the boost on, check how it turns off in each of those cases.
- **Never fight the system.** If macOS or the user lowers the backlight, follow it. Do not write the backlight back to 100% from a timer. Do not disable auto-brightness.
- **External displays: brightness only.** DDC/CI can change many monitor settings (input, power, factory reset). Overbright writes VCP 0x10 and nothing else. Keep it that way unless the user asks for a specific feature, and never send a write you have not read back first on real hardware.
- **Never call `CGDisplayRestoreColorSyncSettings` for an external display.** It resets every display, including the built-in boost. `SoftwareDimmer` restores from its own baseline.
- **One scale, one indicator.** With the key tap running, Overbright handles every plain F1/F2 for the built-in display (`AppDelegate.handleBuiltInKey` → `BoostController.stepScale`) and swallows it, so macOS never shows its own indicator as well. Without the tap, macOS keeps the keys. Do not reintroduce a path where both indicators can appear.
- **Overlay method: never write the gamma table.** On macOS 27.2+ the boost is `EDROverlayService` alone (see the measured facts above). Writing any table, even an identity one, while EDR starts makes white jump to the full backlight. Measure any change to the boost with `light-check.sh`, and look at a black screen too.
- **Never exceed the reported headroom.** In `.classic` the gamma factor is capped by `maximumExtendedDynamicRangeColorComponentValue` at the moment of applying; in `.overlay` the multiplier is limited by the same headroom, which macOS applies to the layer. `BoostLevel.classicMaximum` (160%) and `BoostCalibration` are the classic method's calibrated envelope: do not raise them. With `.overlay`, `BoostLevel.maximum` is the panel's measured ceiling (`PanelCeiling`: headroom at the peak ÷ `EDRWhiteCorrection.full`, stored as `panelBoostMaximum` in the app's defaults), never above `absoluteMaximum`. A user-facing ceiling belongs in `maxLevel` (`"auto"` or a number), which can only lower it.
- **The config file is the single source of truth for settings** (`~/.config/overbright/config.json`). Do not add a second settings store. `UserDefaults` holds only runtime state: the last level and the recovery markers.
- **Config must stay forgiving.** Every field is optional. A bad entry produces a warning in `Config.warnings` and falls back to its default; it must never crash the app or block the rest of the file. Unreadable JSON keeps the previous settings.
- **`Models/` stays pure.** Foundation only, no side effects, covered by `Tests/LogicTests/main.swift`.
- **The CLI client does nothing to the display.** It only sends a request; the running app acts and replies. Keep it that way so there is exactly one process that owns the display state.
- **CLI output is an interface.** Agents parse `status --json` and rely on the exit codes (0 done, 1 refused or unavailable, 2 not running or malformed). Add fields freely; do not rename or remove them without a note in `RELEASE_NOTES.md`.

## Common tasks

**Add a config option**
1. Add the field to `Config` with a default, add its name to `knownKeys`, decode it in `init(dictionary:)` with `number` or `flag`, and print it in `json`.
2. Apply it in `AppDelegate.applyConfigToModels()` or `configDidChange()`, or read `ConfigStore.shared.config` where it is used.
3. Add checks in `Tests/LogicTests/main.swift`. Document it in the field table of both READMEs and add or update a file in `examples/`.

**Add a CLI command**
1. Add the name to `CLI.commands` and the usage text.
2. Handle it in `CommandServer.handle`. If it changes the boost, finish with `settle(finish)` so the reply reflects the final state.
3. Document it in both READMEs.

**Add interface text**
Use `L10n.tr("English", "中文")`. To add a language, add a parameter to `L10n.tr`, a case to `L10n.usesChinese`'s logic, and the code to `Config.languages`.

**Change the menu**
Edit `StatusItemController.rebuildMenu()` for structure and `render(_:)` for state.

**Release**
Bump `CFBundleShortVersionString` and `CFBundleVersion` in `Support/Info.plist`, update `RELEASE_NOTES.md`, and merge to `main`. The release workflow tests, builds both architectures and publishes the zip with a checksum. Existing releases are never overwritten.

## When you fork

Change `repoURL` in `Support/AppInfo.swift` and the clone URL in both READMEs to the new repository. If you rename the app, also change `AppInfo.name`, `AppInfo.bundleID` and `AppInfo.commandChannel`, the names in `Support/Info.plist`, `Package.swift` and `scripts/*.sh`, the identity name in `scripts/setup-signing.sh`, the config path in `ConfigStore.fileURL`, and the lock directory in `InstanceLock.swift`.
