# AGENTS.md

Instructions for AI coding agents working in this repository. Humans are welcome to read it too.

## What this is

Overbright is a macOS menu bar app that raises a built-in XDR display above 100% brightness by opening EDR headroom and scaling the gamma table. It is intentionally small so that a person can fork it and have an agent reshape it into their own tool. Favor small, readable changes over abstractions.

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
bash scripts/brightness-check.sh                         # drive F1/F2 and measure every press
```

`scripts/test.sh` compiles `Sources/Overbright/Models/*.swift` together with `Tests/LogicTests/main.swift` into a plain executable. That is why everything in `Models/` must import only Foundation and must not touch AppKit, the display or `UserDefaults`. Add a check there whenever you add a config field, change a limit, or change key-step arithmetic.

## What you cannot verify yourself

- **Real light.** No sensor on a Mac sees its own screen: the ambient light sensor ignores it, and the camera faces the user and needs their permission (do not use it). What you can measure exactly, read-only, is the backlight macOS is driving (`IOMFBBrightnessLevel` on the built-in framebuffer, in nits, live through every ramp), the standard luminance (CoreBrightness `DisplayNitsKey`), the EDR headroom (CoreBrightness `EDRHeadroom`) and the gamma table. `scripts/tools/BrightnessSampler.swift` turns those into an estimate of ordinary white; the model is explained there and in `BoostMethod`. Report results as estimates from that model, not as measured light. Never write CoreBrightness.

- **External displays.** `overbright displays` and `overbright display <name> <percent>` reply after the DDC write finished, and the level can be read back independently. That is a real check of DDC, but only on a display that is actually connected; CI has none.
- **The external display indicator.** `"$(swift build --show-bin-path)/Overbright" --preview-hud 70` shows it on the first external display for three seconds (pass a negative level to see extra dimming). Capture it with `screencapture -x -D 2 out.png` and look at the top-right corner.
- **F1/F2.** Intercepting brightness keys needs the Accessibility permission, which only the user can grant in System Settings. The grant is tied to the code signature: with an ad-hoc signature every rebuild invalidates it while the switch can still look on. `scripts/setup-signing.sh` fixes this by creating a local self-signed identity; it writes to the user's login keychain, so ask the user to run it rather than running it yourself. Never try to grant the permission yourself.
- **Other Mac models.** CI has no XDR panel.

What you can verify: `scripts/test.sh`, `overbright check <file>`, `scripts/dev.sh --verify`, and, on a Mac with an XDR display and with the user's agreement, the CLI round trip (`overbright set 120 && overbright status --json && overbright off`). The opt-in `Overbright --hardware-self-test` exercises apply/restore, sleep/wake and profile changes on the real screen; it visibly changes brightness for a few seconds, so ask first.

Logs: `log stream --predicate 'subsystem == "io.github.overbright"'`. The last state is also in `defaults read io.github.overbright`.

## Measuring brightness

Use these instead of asking the user whether something looked brighter.

- `scripts/brightness-log.sh` prints the readings and the white estimate every `--interval` ms (`--changes` for only changed rows, `--once` for one). Read-only; safe at any time.
- `scripts/brightness-check.sh` changes the brightness, so run it only when the user expects that. It reads the starting position, drives `overbright key up|down` (the same code F1/F2 run, indicator included) through a scenario (`--scenario full|boost|native`), samples every 20 ms, captures the top quarter of the built-in screen about 5 times a second, then puts the display back. It writes `samples.tsv`, `events.tsv`, `frames/` (file names carry the time on the same clock) and `report.md` to `outputs/brightness-check/` (or `--out`). The report gives, per press: white before and after, time to 90% of the change, and whether it went the wrong way, overshot, or was slow (over 0.35 s). Exit code 1 if any press failed.
- Posting synthetic media-key events from a shell does not reach macOS here (it needs its own permission), which is why the check drives `overbright key`. That covers everything after the key tap; the tap itself (`BrightnessKeyService`) still needs a real key press.
- Look at the frames to check the indicator: exactly one, top centre, 16 segments, appearing within one frame of the press.
- Leave the display as you found it. The check does; after anything else, `overbright set 100` and wait about 20 s for macOS to release EDR, then confirm with `brightness-log.sh --once` that the gamma endpoint is 1.000.

## Layout of the code

All sources are in `Sources/Overbright/`.

| File | Responsibility |
|---|---|
| `Models/Config.swift` | `Config` and `Preset`: defaults, forgiving decoding, warnings, JSON output |
| `Models/BoostLevel.swift` | `BoostLevel` (clamped level), `BoostCalibration` (percent → gamma factor), `BoostState`, `BoostSnapshot` |
| `Models/BuiltInBrightnessScale.swift` | The 0–160% scale (steps, split into backlight and boost, segment fills), `BoostMethod`, `PanelCompensation` |
| `Models/BrightnessKeyStep.swift` | Boost-only key steps (menu slider, classic paths) |
| `Models/BrightnessMediaKeyEvent.swift` | Decoding the system brightness-key events |
| `Models/BacklightObservation.swift` | Tolerating brief backlight read failures |
| `Models/DDC.swift` | DDC/CI request and reply bytes; `ExternalBrightness` steps and scaling |
| `Models/ColorProfileIdentity.swift` | Telling a real color-profile change from a transient notification |
| `Controllers/BoostController.swift` | The state machine: enable, disable, suspend/resume, recovery |
| `Services/GammaTableService.swift` | Reading, scaling and restoring the gamma table |
| `Services/EDRTriggerService.swift` | The invisible HDR layer that opens EDR headroom |
| `Services/DDCService.swift` | IOAVService I2C transport (Apple Silicon, loaded with dlsym) and endpoint discovery |
| `Services/ExternalDisplayManager.swift` | External displays: detection, DDC/macOS/software choice, coalesced writes, software dimming |
| `Services/PanelLightService.swift` | Read-only live backlight nits and standard nits for the panel method |
| `Services/NativeBrightnessService.swift` | Reading and writing the system backlight level |
| `Services/BrightnessKeyService.swift` | The event tap for F1/F2; the only code that needs Accessibility |
| `Services/ConfigStore.swift` | Loads `config.json`, creates it on first run, hot reloads |
| `Services/InstanceLock.swift` | One running copy at a time |
| `Views/MenuBarIcon.swift` | Menu bar glyphs (Lucide SVG, template images): on, off, problem |
| `Views/ScaleHUD.swift` | The one indicator for the built-in display: top centre, sun, 16 segments over 0–160% |
| `Views/BrightnessHUD.swift` | The on-screen indicator for external display changes |
| `Views/StatusItemController.swift` | Menu bar icon and menu, rebuilt on every config change |
| `App/CLI.swift` | The `overbright` command (client) and `CommandServer` (inside the app) |
| `App/AppDelegate.swift` | Start-up, sleep/wake/session observers, applying the config |
| `App/OverbrightApplication.swift` | Entry point; routes CLI commands; the hardware self-test |
| `Support/AppInfo.swift` | Name, bundle identifier, repository URL |
| `Support/L10n.swift` | Language selection |

## Conventions that matter

- **Always restore.** Every path that changes the gamma table or the backlight must have a path that puts it back, including on quit, SIGTERM, sleep, a color-profile change and a crash (the `recoveryRequired` marker in `UserDefaults`). If you add a way to turn the boost on, check how it turns off in each of those cases.
- **Never fight the system.** If macOS or the user lowers the backlight, follow it. Do not write the backlight back to 100% from a timer. Do not disable auto-brightness.
- **External displays: brightness only.** DDC/CI can change many monitor settings (input, power, factory reset). Overbright writes VCP 0x10 and nothing else. Keep it that way unless the user asks for a specific feature, and never send a write you have not read back first on real hardware.
- **Never call `CGDisplayRestoreColorSyncSettings` for an external display.** It resets every display, including the built-in boost. `SoftwareDimmer` restores from its own baseline.
- **One scale, one indicator.** With the key tap running, Overbright handles every plain F1/F2 for the built-in display (`AppDelegate.handleBuiltInKey` → `BoostController.stepScale`) and swallows it, so macOS never shows its own indicator as well. Without the tap, macOS keeps the keys. Do not reintroduce a path where both indicators can appear.
- **Panel method: the table only takes light away.** On macOS 27.2+ an app's gamma table reaches the panel without macOS's EDR scaling (evidence: a table of 1.01 jumped white to the backlight's peak; after restoring an explicit identity table, white stayed bright until the backlight came down about 17 s later). So in `.panel` the endpoint is wanted nits ÷ live backlight nits, never above 1, tracked at 120 Hz with a predicted backlight while it ramps. On leaving the boost, keep compensating (`settling`) until the backlight is back where it was before the boost; hand the table back through ColorSync if another app still holds EDR. Measure any change here with `brightness-check.sh`.
- **Never exceed the reported headroom.** In `.classic` the gamma factor is capped by `maximumExtendedDynamicRangeColorComponentValue` at the moment of applying; in `.panel` the endpoint never goes above 1, so the panel is never asked for more than the backlight macOS is driving. `BoostLevel.maximum` (160%) and `BoostCalibration` are the calibrated safety envelope: do not raise them to make the screen "brighter". A user-facing ceiling belongs in `maxLevel`, which can only lower it.
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
