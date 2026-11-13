# AGENTS.md

Instructions for AI coding agents working in this repository. Humans are welcome to read it too.

You are the owner and long-term maintainer of this codebase, and its design is up to you.

## What this is

Overbright is a macOS menu bar app that raises a built-in XDR display above 100% brightness. On macOS 27.2+ it does so by default by writing the panel's backlight cap and level directly (`direct`: nothing is drawn on screen). The fallbacks open EDR headroom and lift ordinary content into it: a multiplying HDR layer on 27.2+ (`overlay`), the gamma table before (`classic`). It is intentionally small so that a person can fork it and have an agent reshape it into their own tool. Favor small, readable changes over abstractions.

- Language: Swift, built with Swift Package Manager. No Xcode project, no third-party dependencies. Keep it that way.
- Minimum macOS: 13. Both arm64 and x86_64 must keep building.
- English for code, comments, commit messages and docs. `README.zh-CN.md` is a translation of the README; update it when the README changes in substance. Interface text is written in English and Chinese side by side with `L10n.tr("English", "中文")`.

## Scope

The aim is the cleanest, most verifiable XDR boost on macOS 27.2+, which means the direct method. Check new work against this before starting:

- **Worth doing:** the direct method on more Macs and in more situations (sleep and wake, lid, automatic brightness, HDR video, low battery); making measurements easy for others to reproduce; keeping the CLI stable; fixing bugs anywhere.
- **Not doing:** more external display features than brightness and dimming; raising `maxNits` above 1300 or working around the panel's thermal limit; new features for macOS before 27.2 (`classic` stays as it is); an App Store version; a settings window; colour, HDR grading or night-shift features.
- **Claims follow measurements.** README says only what was measured, and on which Mac. Mark anything inferred as untested.

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
bash scripts/gamma-check.sh                              # does the gamma table change light? (camera)
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
  - **Privacy.** The helper keeps numbers only, never an image, and there is no option to save one; do not add one. The raw `camera.tsv` is deleted once the report is written (`--keep-raw` keeps it), and also when the check fails or is interrupted. The helper stops when the check ends, fails, is interrupted or crashes (`--parent`, `<out>.stop`). Any new camera tool must do the same. To revoke: System Settings → Privacy & Security → Camera, or `tccutil reset Camera io.github.jj22007.overbright.camera-meter`; ask the user first. See SECURITY.md.
  - **Dark room first.** Both camera checks start by alternating the patch white and black. If the screen is under 20% of the light the camera sees, they restore the display and stop with advice (lights off, curtains closed, no other screen or lamp in view). `--force` runs anyway, and the report marks it not valid. Tell the user rather than forcing it.
  - **Presses.** 10 × F2 then 10 × F1. For each press it reports the direction, the time to 90%, and any overshoot past start or end. A press fails if it moves the wrong way or overshoots by more than 3%.
  - **Ratio.** A null test that does not depend on the camera's response. At boost X the white patch becomes a grey that emits 1/X of white, so the camera must read the same as plain white at the standard 100%. A level fails beyond ±5%.
  - **Release.** The light for 24 s after leaving the boost, as information only.
- **`scripts/gamma-check.sh`: does the gamma table change light?** Same camera and dark-room check. It compares the gamma table on and off, without HDR (table × 0.5) and with HDR open (the classic method at 160% against 106%, setting `"boostMethod": "classic"` for the duration), each beside a control made in the picture itself. It puts the table, the config file and the boost back, also on Ctrl-C.
  - The camera's exposure cannot be locked on a MacBook. Only trust comparisons made within a few seconds of each other; that is why the ratio test is a null test.
- **Real key presses.** `overbright key up|down --real [--control]` makes the running app post a brightness media key at the HID tap. It travels through macOS, Overbright's key tap and its handler, exactly like F1/F2. A shell cannot post one itself (it has no Accessibility). Without `--real`, `overbright key` calls the handler directly.
- **`scripts/brightness-log.sh`: raw readings.** Read-only, safe at any time: backlight slider, standard nits, the backlight in nits macOS is driving (`IOMFBBrightnessLevel`, live through every ramp), EDR headroom and the gamma endpoint. None of these is emitted light.
- **Facts measured on macOS 27.2.1 (14" MacBook Pro).** Most of these are about the `overlay` method, kept because it is the fallback.
  - The gamma table has no effect on emitted light, with or without EDR (`gamma-check`: 0% and −1% of the controls). A table installed when EDR starts stops macOS from scaling ordinary content, so white goes to the full backlight.
  - A full-screen EDR layer with `compositingFilter = "multiplyBlendMode"` multiplies emitted light exactly. A layer that is drawn once and left alone stops being composited with the filter after about a second and shows as an opaque sheet, so it must keep redrawing. `MultiplyRenderer` draws from its own thread with a dispatch timer (not MTKView, not the main thread: a main-thread timer once let 2.25 s pass between frames in normal use), and the service holds an activity against App Nap. `status --json` reports `overlayMaxFrameGap` (frames that reached the screen; keep it well under a second) and `mainThreadMaxGap`. `defaults write io.github.overbright debugCapturableOverlay -bool true` makes screenshots include the layer (they show the multiply but not the white sheet); `debugStopRedraw` stops the frames for tests. Check this on a black screen, where the failure is obvious; on a white screen it looks like success.
  - Spaces and Mission Control transitions draw the layer without its multiply: a white sheet. This is why `direct` became the default. At `.screenSaver` level even Control+arrow switches did it; at `CGShieldingWindowLevel()` those are clean. `SpaceTransitionWatcher` hides the layer for the rest: an active HID tap on Dock swipe events (type 30) and Space/Mission Control keys hides it before passing them on (a listen-only tap lost the race), and a 20 Hz check for full-screen WindowManager windows at layers 1–100 covers Mission Control. `status --json` → `transitions` counts events and hides. Screenshots never show the white sheet; only the user's eyes (or a camera in the dark) do.
  - macOS dims ordinary white by about 9% once the backlight reaches its EDR peak, not during the ramp (`EDRWhiteCorrection`).
  - A layer change takes about 0.15 s to show (0.4 s at 4 frames per second).
  - The ambient light sensor does not see the screen.
  - `direct` passes the ratio test but boosts slightly more than asked: +0.9%, +2.8% and +3.5% at 106%, 125% and 160%. Not explained; one guess is light leaking through black rising with the backlight. After the boost ends there is no dim period.
  - SMC `PBLR` is backlight power in watts. It is linear in nits below 100%, but it follows LED drive, not emitted light, so it cannot judge the boost.
- **Indicator.** Capture the top of the screen right after `overbright key up --real` (`screencapture -x -R 0,0,<width>,280`). There must be exactly one indicator, top centre, 16 segments.
- **Leave the display as you found it.** `light-check` does. After anything else, `overbright set 100` and wait about 20 s for macOS to release EDR, then check with `brightness-log.sh --once`.

## Layout of the code

All sources are in `Sources/Overbright/`.

| File | Responsibility |
|---|---|
| `Models/Config.swift` | `Config` and `Preset`: defaults, forgiving decoding, warnings, JSON output |
| `Models/PanelSupport.swift` | Whether this Mac can boost and how, from `PanelReadings`: XDR check, standard white, ceiling, write limit, method order |
| `Models/BoostLevel.swift` | `BoostLevel` (clamped level), `BoostCalibration` (percent → gamma factor), `BoostState`, `BoostSnapshot` |
| `Models/BuiltInBrightnessScale.swift` | The 0%-to-ceiling scale (steps, split into backlight and boost, segment fills), `BoostMethod`, `EDRWhiteCorrection` |
| `Models/BrightnessKeyStep.swift` | Boost-only key steps (menu slider, classic paths) |
| `Models/BrightnessMediaKeyEvent.swift` | Decoding the system brightness-key events |
| `Models/BacklightObservation.swift` | Tolerating brief backlight read failures |
| `Models/DDC.swift` | DDC/CI request and reply bytes; `ExternalBrightness` steps and scaling |
| `Models/Automation.swift` | `LowBattery` (when `lowBatteryOff` ends the boost) and `Shortcut` (parsing `toggleShortcut`) |
| `Models/AgentInterface.swift` | `Readback` (does the panel prove the boost or the restore) and `MCPServer` (`overbright mcp`: JSON-RPC over stdio, four tools, each runs a command and polls the readback) |
| `Models/ColorProfileIdentity.swift` | Telling a real color-profile change from a transient notification |
| `Controllers/BoostController.swift` | The state machine: enable, disable, suspend/resume, recovery |
| `Services/GammaTableService.swift` | Reading, scaling and restoring the gamma table |
| `Services/DirectPanelService.swift` | The direct method: writes, maintains and restores the framebuffer's `BLNitsCap` and `IOMFBBrightnessLevel` |
| `Services/EDRTriggerService.swift` | The invisible HDR layer that opens EDR headroom (classic method) |
| `Services/EDROverlayService.swift` | The full-screen multiplying HDR layer (`overlay`, the fallback on macOS 27.2+) |
| `Services/SpaceTransitionWatcher.swift` | Hides the overlay during Spaces and Mission Control transitions |
| `Services/DDCService.swift` | IOAVService I2C transport (Apple Silicon, loaded with dlsym) and endpoint discovery |
| `Services/ExternalDisplayManager.swift` | External displays: detection, DDC/macOS/software choice, coalesced writes, software dimming |
| `Services/PanelLightService.swift` | Read-only panel readings: live backlight nits, peak, cap, CoreBrightness standard white, model; `readings()` for `PanelSupport` |
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
| `Services/AutomationServices.swift` | `BatteryMonitor` (IOPowerSources) and `ShortcutService` (Carbon hot key, no Accessibility) |
| `Support/CommandToken.swift` | The per-launch secret every `overbright` request must carry (distributed notifications reach sandboxed apps too; see SECURITY.md) |
| `Support/DisplayLookup.swift` | Finding the built-in display and its screen |
| `Support/L10n.swift` | Language selection |

## Conventions that matter

- **Always restore.** Every path that changes the gamma table, the backlight or the overlay must have a path that puts it back, including on quit, SIGTERM, sleep, a color-profile change and a crash (the `recoveryRequired` marker in `UserDefaults`). If you add a way to turn the boost on, check how it turns off in each of those cases.
- **Never fight the system.** If macOS or the user lowers the backlight, follow it. Do not write the backlight back to 100% from a timer. Do not disable auto-brightness.
- **External displays: brightness only.** DDC/CI can change many monitor settings (input, power, factory reset). Overbright writes VCP 0x10 and nothing else. Keep it that way unless the user asks for a specific feature, and never send a write you have not read back first on real hardware.
- **Never call `CGDisplayRestoreColorSyncSettings` for an external display.** It resets every display, including the built-in boost. `SoftwareDimmer` restores from its own baseline.
- **One scale, one indicator.** With the key tap running, Overbright handles every plain F1/F2 for the built-in display (`AppDelegate.handleBuiltInKey` → `BoostController.stepScale`) and swallows it, so macOS never shows its own indicator as well. Without the tap, macOS keeps the keys. Do not reintroduce a path where both indicators can appear.
- **No model numbers in code.** Every number that differs between Macs (standard white, peak, ceiling, headroom) comes from `PanelReadings` and is decided in `PanelSupport`, which is pure and covered for each model in `Tests/LogicTests` with simulated readings. Add a model there rather than a model check in a service. A panel that peaks under 1000 nits (MacBook Air, 13" MacBook Pro) must never be driven. Only a 14" MacBook Pro (27.2.1, measured) and a 16" M1 Max (27.2, readings only) have been checked on real hardware; keep README's "Supported Macs" honest when that changes.
- **Direct method (default on 27.2): framebuffer `BLNitsCap` + `IOMFBBrightnessLevel`.** `DirectPanelService` writes both (cap first) as 16.16 nits, never above the panel's own peak (`PanelSupport.writeLimit`; nothing without a known XDR peak), reads the cap back and reports a write macOS did not take as a failure (the controller then falls back to `overlay`), keeps the previous values in defaults until written back (`recoverIfNeeded` at launch), puts the boost back after every step macOS writes (see below), and leaves a backlight below what macOS allows to the controller (the user dimmed: the boost ends, then macOS recomputes via a native-brightness nudge). Never disable or work around the panel's thermal limit; `maxNits` stops at 1300. Measured on a 14" MacBook Pro, 27.2: 1000 nits held for a minute at 10.7 W; 1300 sagged after ~10 s; 1600 was overridden by macOS within 2 s. `status --json` → `direct`.
  - **macOS takes the backlight over with a ramp**: one write per frame (the cap every 8 ms, the level every 8 to 50 ms) for one to two seconds. It does so with ambient light and every time HDR content appears or leaves; on macOS 27 a system banner is HDR content with a headroom of 1.2 (145 takeovers in one working day). `maintain()` checks every 20 ms, and every 2 ms while values are changing, and writes the boost again whenever it finds macOS's values. Do not go back to waiting for macOS to settle: that left the screen at standard brightness for 2 to 3 s at each end of every HDR appearance. (An earlier version rewrote every 250 ms and flickered; at 2 ms macOS's value is on the register for 1 to 3 ms per step.) Nobody has looked at this with a camera or in the dark: if a user reports shimmer for a second or two when a banner appears, this is where to look.
  - **HDR headroom.** While HDR content is on screen macOS's cap is standard white × headroom and ordinary content is drawn that much darker, so ordinary white = backlight ÷ headroom. `DirectPanel.backlight` therefore writes the wanted white × (macOS's cap ÷ standard white). `maxNits` bounds ordinary white; the backlight itself stops at `maximumShare` of the peak (1296 nits), and where macOS's own cap is higher (HDR video) nothing is written. A cap macOS raised is not a new standard white unless CoreBrightness's `EDRHeadroom` (read only) is 1; standard white is read again only once macOS has been quiet for 1 s. Measured with SMC `PBLR` at 166%: 10.2 W steady; through a 1.2 appearance 9.5 to 10.0 W with the backlight at 1195; with HDR at the peak 7.5 W (macOS's own); before this, 5.7 W there, darker than standard white's 6.8 W.
  - To reproduce: any 2×2 window with a `CAMetalLayer`, `wantsExtendedDynamicRangeContent` and `contentsHeadroom = 1.2` shown for a few seconds, while sampling `BLNitsCap` and `IOMFBBrightnessLevel` every millisecond. An ordinary notification banner does not open HDR; a system banner does.
- **Overlay method: never write the gamma table.** With `overlay` the boost is `EDROverlayService` alone (see the measured facts above). Writing any table, even an identity one, while EDR starts makes white jump to the full backlight. Measure any change to the boost with `light-check.sh`, and look at a black screen too.
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
