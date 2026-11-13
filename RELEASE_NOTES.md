## Install

Download **Overbright-universal.zip**, unzip it, and move **Overbright.app** into Applications.

- macOS 13 or later. The app contains both Apple Silicon and Intel binaries.
- Boost needs a built-in display with EDR headroom (Liquid Retina XDR). An ordinary LCD does not get brighter.
- Not notarized by Apple. If the first launch is blocked, choose **Open Anyway** under System Settings → Privacy & Security. You do not need to turn Gatekeeper off.
- To use F1/F2 past 100%, allow Overbright under Privacy & Security → Accessibility.

## 2.6.2

- **Fixed: after a boost ended, the screen could stay dim at about 160 nits** while standard white was 600. Overbright saved a backlight level caught while macOS was still ramping and wrote it back at the end, then saved it again on the next boost. Ending a boost now goes back to the standard white macOS reports, and only lowers a backlight that is still above it.
- **Camera checks keep nothing they don't need.** The camera never saved images. It now stops as soon as a check ends, fails or is interrupted (it used to keep recording numbers for its full 150 s), and the per-frame numbers are deleted once the report is written (`--keep-raw` keeps them). See `SECURITY.md` for how to delete measurement files and revoke the camera.
- **The `overbright` command needs a token.** The app writes a fresh token at each launch (`~/Library/Application Support/Overbright/command-token`, readable only by you), and ignores requests without it, so a sandboxed app can no longer change your brightness. The `overbright` command reads it for you; nothing changes for scripts that use it.
- **`overbright mcp`**: an MCP server over stdio with four tools (`status`, `set_brightness`, `restore`, `report`). Every result carries the panel's readback, and `set_brightness` and `restore` wait until the panel proves them, so an agent gets evidence instead of an exit code. `status --json` gains the same `readback` object.
- **Two opt-in options, both off by default:** `lowBatteryOff` ends the boost when the battery falls to a percentage you choose, and `toggleShortcut` (for example `"ctrl+opt+cmd+b"`) switches the boost from anywhere without Accessibility permission. Neither the shortcut press nor an actual low-battery shutoff has been tried by hand yet.
- **New `SECURITY.md`**, and the README now leads with how Overbright differs from Vivid and BrightIntosh, with measured numbers.
- The logic tests could pass while checks failed (the failure check sat halfway through the file). Fixed; 331 checks now run.

## 2.6.1

- **Fixed: the boost could drop out when the room got darker.** With the direct method, when ambient light fell macOS lowered standard white (720 to 600 nits on a 14" MacBook Pro) and Overbright took the lower backlight for you dimming the screen. The boost was not put back, while the menu and `status` still said it was on. Overbright now follows the new standard white and keeps boosting.
- **`overbright report`.** One read-only command that prints a Markdown report for a model report issue: model, macOS, method, standard white, peak, the backlight now, the top of the scale, and whether the boost actually reached the panel, with the full `status --json` folded underneath. It changes nothing on screen. If you have a MacBook Pro other than a 14" M6, please turn the boost on at the top of the scale, run it, and [send the output](https://github.com/JJ22007/overbright/issues/new?template=model-report.yml).
- **README and AGENTS.md describe the direct method first**, mark what only applies to the overlay and classic methods, and state the private-interface risk. With the direct method there is no dim period after the boost ends: the backlight is back at standard white within 0.1 s (measured readings).

## 2.6

- **More MacBook Pros.** Nothing is tied to the 14" MacBook Pro any more. Standard white, the peak, the ceiling and the scale's top are read from each panel, so a 16" or an M1/M2 model gets its own numbers (200% on M1 and M2, whose standard white is 500 nits; 166% on M3 and later). Every write is bounded by the panel's own peak. See "Supported Macs" in the README for what was measured and what is only expected to work, and please report your model.
- **Falls back instead of failing.** When the direct method cannot drive the panel, or macOS does not take the write, the boost uses the overlay method instead of stopping with an error.
- **Fixed: a boost started while HDR was on screen went to the full 1600 nits.** With an HDR video playing (or another boost tool holding HDR open), macOS raises the backlight cap to the peak, and the direct method took that for standard white. Standard white now comes from CoreBrightness in that case.
- **Clear "not supported".** A MacBook Air, a 13" MacBook Pro or an Intel MacBook Pro now says why in the menu and in `overbright status`, and nothing is written to its display. `status --json` adds `unsupportedReason` and `panel` (model, peak, cap, standard white, the methods it will try).
- **Checked on a 14" MacBook Pro (M6, macOS 27.2.1)** before release: 120%, 150% and 166% drove the panel to 720, 900 and 996 nits, 100% went back to 600, quitting while boosted restored the display, and the hardware self-test passed.

## 2.5

- **Boost without a layer on macOS 27.2: no more white screen.** The new default method, `direct`, drives the built-in panel's backlight past standard white itself (the framebuffer's nits cap and level) instead of covering the screen with a multiplying HDR layer. The layer flashed white in Spaces and Mission Control transitions, a macOS behaviour other boost apps share; with nothing drawn on screen, switching desktops looks as usual and the screen no longer dims while switching. The top is 1000 nits (`maxNits`, up to 1300), which the panel holds across the whole screen: 166% of a 600-nit standard white, less in bright surroundings where macOS raises standard white. The previous values are written back when the boost ends, when you lower the brightness, and at the next launch after a crash. `"boostMethod": "overlay"` keeps the 2.4 layer.

## 2.4

- **As bright as the panel goes.** With the overlay method (macOS 27.2) the ceiling is no longer a fixed 160%: Overbright measures the panel's EDR headroom the first time the boost reaches the peak and remembers it. On a 14" MacBook Pro that is 244% (2.67× headroom less the 9% Overbright adds back for macOS's dimmer white); other models get their own number. `"maxLevel"` is now `"auto"` by default, or a number up to 400 for a lower ceiling. `status --json` adds `panelMaxLevel`.
- **Indicator restyled after the macOS volume indicator.** A larger glass capsule with a sun, 16 thin, evenly spaced dashes spanning 0% to the panel's ceiling, and the percentage.
- **No white sheet when switching Spaces (mostly).** macOS draws the boost layer without its multiply in Spaces and Mission Control transitions, which showed as a white, flickering sheet over the whole screen. The layer now sits at the shielding level (keyboard switches stay clean), and hides while a transition runs: a trackpad swipe between Spaces, a Control/Option+arrow switch or the Mission Control key (caught before the Dock sees them), or while Mission Control is open. It fades back in 1.5 s after the last swipe, so the screen is at standard brightness during a switch. A rare short flash remains.
- **The boost layer draws from its own thread.** It used to be redrawn by a timer on the app's main thread; in normal use frames once stopped for 2.25 s, long enough for the layer to show as a white sheet over the whole screen. `status --json` reports `overlayMaxFrameGap` (frames that reached the screen) and `mainThreadMaxGap`.

## 2.3

- **One brightness scale, one indicator.** F1/F2 move along a single 0–160% scale on the built-in display: the backlight up to 100%, the boost above. Overbright shows one indicator for all of it (top centre, 16 evenly spaced segments) instead of macOS's below 100% and its own above.
- **Boost fixed for macOS 27.2.** On macOS 27.2 the gamma table no longer changes the light the built-in panel emits, and a table installed when HDR starts makes white jump to the full backlight. That is why the boost jumped at 101%, did not change between 100 and 160%, and stayed bright for 15 s after going back to 100%. The boost now uses a full-screen HDR layer that multiplies the picture by the boost level and never touches the gamma table. Measured with the Mac's camera and real key presses: every F1/F2 press changes the light the right way, reaching 90% in 0.3–0.65 s; 106%, 125% and 160% are within 0.3% of 1.06, 1.25 and 1.6 × the standard white; entering the boost flashes at most 3%. One limit is macOS's: after leaving the boost, white sits about 7% below standard for ~13 s until macOS lowers the backlight. `"boostMethod"` can force the old gamma method (`"classic"`). The layer is redrawn by Overbright's own timer, with App Nap held off while it is up: a layer that stops redrawing for about a second turns into a white sheet over the whole screen.
- **Measuring tools** for contributors and agents: `scripts/light-check.sh` measures real light with the camera while pressing real keys; `scripts/brightness-log.sh` prints the raw readings.
- `overbright key up|down [--real]` (`--real` posts an actual key press through macOS), `set` and `up`/`down` across the whole scale, and `scale`, `scaleTop`, `boostMethod` in `status --json`.

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
