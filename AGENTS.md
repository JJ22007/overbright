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
```

`scripts/test.sh` compiles `Sources/Overbright/Models/*.swift` together with `Tests/LogicTests/main.swift` into a plain executable. That is why everything in `Models/` must import only Foundation and must not touch AppKit, the display or `UserDefaults`. Add a check there whenever you add a config field, change a limit, or change key-step arithmetic.

## What you cannot verify yourself

- **Real brightness.** Whether the panel actually got brighter can only be judged by a person looking at an XDR display. `overbright status --json` tells you the state machine reached `on` and what headroom macOS reports; it does not measure light. Say this plainly instead of claiming a visual change was tested.
- **F1/F2.** Intercepting brightness keys needs the Accessibility permission, which only the user can grant in System Settings. The grant is tied to the code signature: with an ad-hoc signature every rebuild invalidates it while the switch can still look on. `scripts/setup-signing.sh` fixes this by creating a local self-signed identity; it writes to the user's login keychain, so ask the user to run it rather than running it yourself. Never try to grant the permission yourself.
- **Other Mac models.** CI has no XDR panel.

What you can verify: `scripts/test.sh`, `overbright check <file>`, `scripts/dev.sh --verify`, and, on a Mac with an XDR display and with the user's agreement, the CLI round trip (`overbright set 120 && overbright status --json && overbright off`). The opt-in `Overbright --hardware-self-test` exercises apply/restore, sleep/wake and profile changes on the real screen; it visibly changes brightness for a few seconds, so ask first.

Logs: `log stream --predicate 'subsystem == "io.github.overbright"'`. The last state is also in `defaults read io.github.overbright`.

## Layout of the code

All sources are in `Sources/Overbright/`.

| File | Responsibility |
|---|---|
| `Models/Config.swift` | `Config` and `Preset`: defaults, forgiving decoding, warnings, JSON output |
| `Models/BoostLevel.swift` | `BoostLevel` (clamped level), `BoostCalibration` (percent → gamma factor), `BoostState`, `BoostSnapshot` |
| `Models/BrightnessKeyStep.swift` | Next level for an F1/F2 press |
| `Models/BrightnessMediaKeyEvent.swift` | Decoding the system brightness-key events |
| `Models/BacklightObservation.swift` | Tolerating brief backlight read failures |
| `Models/ColorProfileIdentity.swift` | Telling a real color-profile change from a transient notification |
| `Controllers/BoostController.swift` | The state machine: enable, disable, suspend/resume, recovery |
| `Services/GammaTableService.swift` | Reading, scaling and restoring the gamma table |
| `Services/EDRTriggerService.swift` | The invisible HDR layer that opens EDR headroom |
| `Services/NativeBrightnessService.swift` | Reading and writing the system backlight level |
| `Services/BrightnessKeyService.swift` | The event tap for F1/F2; the only code that needs Accessibility |
| `Services/ConfigStore.swift` | Loads `config.json`, creates it on first run, hot reloads |
| `Services/InstanceLock.swift` | One running copy at a time |
| `Views/StatusItemController.swift` | Menu bar icon and menu, rebuilt on every config change |
| `App/CLI.swift` | The `overbright` command (client) and `CommandServer` (inside the app) |
| `App/AppDelegate.swift` | Start-up, sleep/wake/session observers, applying the config |
| `App/OverbrightApplication.swift` | Entry point; routes CLI commands; the hardware self-test |
| `Support/AppInfo.swift` | Name, bundle identifier, repository URL |
| `Support/L10n.swift` | Language selection |

## Conventions that matter

- **Always restore.** Every path that changes the gamma table or the backlight must have a path that puts it back, including on quit, SIGTERM, sleep, a color-profile change and a crash (the `recoveryRequired` marker in `UserDefaults`). If you add a way to turn the boost on, check how it turns off in each of those cases.
- **Never fight the system.** If macOS or the user lowers the backlight, follow it. Do not write the backlight back to 100% from a timer. Do not disable auto-brightness.
- **Never exceed the reported headroom.** The gamma factor is capped by `maximumExtendedDynamicRangeColorComponentValue` at the moment of applying. `BoostLevel.maximum` (160%) and `BoostCalibration` are the calibrated safety envelope: do not raise them to make the screen "brighter". A user-facing ceiling belongs in `maxLevel`, which can only lower it.
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
