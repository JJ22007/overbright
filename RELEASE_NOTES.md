## Install

Download **Overbright-universal.zip**, unzip it, and move **Overbright.app** into Applications.

- macOS 13 or later. The app contains both Apple Silicon and Intel binaries.
- Boost needs a built-in display with EDR headroom (Liquid Retina XDR). An ordinary LCD does not get brighter.
- Not notarized by Apple. If the first launch is blocked, choose **Open Anyway** under System Settings → Privacy & Security. You do not need to turn Gatekeeper off.
- To use F1/F2 past 100%, allow Overbright under Privacy & Security → Accessibility.

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
