## Install

Download **Overbright-universal.zip**, unzip it, and move **Overbright.app** into Applications.

- macOS 13 or later. The app contains both Apple Silicon and Intel binaries.
- Boost needs a built-in display with EDR headroom (Liquid Retina XDR). An ordinary LCD does not get brighter.
- Not notarized by Apple. If the first launch is blocked, choose **Open Anyway** under System Settings → Privacy & Security. You do not need to turn Gatekeeper off.
- To use F1/F2 past 100%, allow Overbright under Privacy & Security → Accessibility.

## Unreleased

- **One brightness scale, one indicator.** F1/F2 move along a single 0–160% scale on the built-in display: the backlight up to 100%, the boost above. Overbright shows one indicator for all of it (top centre, 16 segments) instead of macOS's below 100% and its own above.
- **Boost fixed for macOS 27.2.** macOS 27.2 stopped scaling ordinary content when an app sets a gamma table, so the boost jumped to full brightness at 101%, barely changed between 100 and 160%, looked washed out, and took 15–20 s to come back down. The new panel method follows the live backlight and keeps every step prompt: measured, each press reaches 90% of its change in about 0.02 s, and 160→100 is immediate. `"boostMethod"` can force the old behaviour.
- **Measuring tools** for contributors and agents: `scripts/brightness-log.sh` and `scripts/brightness-check.sh`.
- `overbright key up|down`, `set` and `up`/`down` across the whole scale, and `scale`, `scaleTop`, `boostMethod` in `status --json`.

## 2.2

- **New menu bar icon.** A plain monochrome sun from [Lucide](https://lucide.dev): full rays while boosted, dotted rays at standard brightness, and a warning triangle when the boost is unavailable. It follows light and dark menu bars like the system's own icons.

## 2.1

- **External displays.** Plug a display in and it appears in the menu with its own brightness slider. Most monitors are controlled over DDC/CI, exactly like their own buttons; Apple displays through macOS; anything else is dimmed in software.
- **Darker than the backlight allows.** Past 0%, Control+F1 keeps going down to −90%: the backlight stays at its minimum and the picture is darkened in software. Turn it off with `"extraDimming": false`.
- **Control+F1/F2** adjust the external display under the pointer, or all of them when the pointer is on the built-in screen, with an on-screen indicator.
- `overbright displays` and `overbright display <name|all> <percent|up|down>`; `status --json` lists external displays.
- New config options: `externalDisplays`, `externalKeys`, `showHUD`, `extraDimming`.

## 2.0

Display Boost is now **Overbright**, with a new bundle identifier. Quit and delete `Display Boost.app`, then allow Overbright under Accessibility once.

- **Config file.** `~/.config/overbright/config.json` sets the ceiling, F1/F2 step sizes, presets, launch behaviour, the menu bar percentage and the language. It reloads when saved, and problems are listed in the menu.
- **Command line.** `overbright status | on | off | toggle | set <percent> | up | down | preset <name>`, with `--json` output and exit codes, for scripts and AI agents.
- **Presets** in the menu and the CLI.
- **English interface**, with 简体中文 following the system language.
- **Source install** in one step with `scripts/install.sh`, and `scripts/setup-signing.sh` to keep the Accessibility grant across rebuilds.
- `AGENTS.md`, example configs and an MIT license, so the project is easy to fork and reshape.

The brightness engine is unchanged from 1.3.

Different Mac models still need testing on real hardware. 160% is a requested boost, not a measured brightness and not a sustained 1,600 nits. Do not run another gamma-based brightness tool at the same time.
