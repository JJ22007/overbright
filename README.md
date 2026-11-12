<h1 align="center">Overbright</h1>

<p align="center">
  <b>Take your MacBook's XDR display past 100%.</b><br>
  A menu bar app you can script, configure in one file, and reshape with an AI agent.
</p>

<p align="center">
  <a href="README.zh-CN.md">简体中文</a> ·
  <a href="#install">Install</a> ·
  <a href="#make-it-yours">Customize</a> ·
  <a href="#drive-it-from-scripts-and-agents">CLI</a> ·
  <a href="#build-your-own">Build your own</a>
</p>

Overbright opens the extra brightness that a Liquid Retina XDR display normally keeps for HDR video, and lets you use it for everything: up to what the panel holds across the whole screen (166% of standard brightness on M3 and later, 200% on M1 and M2, worked out on each Mac from what its panel reports), from the menu bar, from F1/F2, or from a command. It is plain Swift with no dependencies and no Xcode project. Settings sit in one JSON file, and anything the file can't do is a short edit away, by you or by your AI coding agent.

## Features

- **Brightness past 100%.** A slider from 100% to the panel's own ceiling, worked out from what the panel reports: its standard white, its peak and its EDR headroom. Nothing is tied to one model. The boost never asks the panel for more than its peak, and by default for no more than the 1000 nits an XDR panel holds across the whole screen.
- **One scale, one indicator.** F1/F2 move along a single scale: 0–100% is the backlight, above 100% the boost, up to the panel's ceiling. Overbright shows one indicator for all of it, and every press changes the brightness within a few hundredths of a second.
- **External displays too.** Plug a display in and it appears in the menu with its own slider. Control+F1/F2 dims or brightens it, with an on-screen indicator. Most monitors are driven over DDC/CI, exactly like their own buttons; the rest are dimmed in software.
- **Stays out of the system's way.** Auto-brightness, Control Center and sleep keep working. Overbright follows them instead of fighting them, and puts everything back when you turn it off or quit.
- **One config file, hot reloaded.** Save the file and the change applies within a second or two. Mistakes show up in the menu instead of breaking the app.
- **Presets.** Name the levels you use ("Shade", "Outdoors") and pick them from the menu or the command line.
- **A command line for scripts and agents.** `overbright set 140`, `overbright status --json`. Every command reports the real result and a meaningful exit code.
- **English and 简体中文**, following the system language.

## Requirements

- macOS 13 or later, Apple Silicon or Intel.
- A built-in display with EDR headroom. In practice that means a MacBook Pro with a Liquid Retina XDR display. On other displays the app says so and leaves brightness alone. Overbright cannot make an ordinary LCD brighter.

## Supported Macs

Every 14" and 16" MacBook Pro with a Liquid Retina XDR display, M1 Pro/Max (2021) and later, should work. Overbright reads each panel's own numbers at run time (standard white, peak and EDR headroom), so it does not need to know the model. Only two Macs have been checked on real hardware so far:

| Mac | macOS | Status |
|---|---|---|
| 14" MacBook Pro, M6 (Mac18,1) | 27.2.1 | **Measured.** Every method, with the camera and real key presses (`scripts/light-check.sh`). |
| 16" MacBook Pro, M1 Max (MacBookPro18,2) | 27.2 | **Panel readings checked.** Support, method, standard white (500 nits), peak (1600) and ceiling (200%) read correctly, including while another app holds HDR open. Light not yet measured. |
| 14" and 16", M1 Pro/Max and M2 Pro/Max | 13 or later | **Expected to work, untested.** Standard white 500 nits, so the top is 200%. |
| 14" and 16", M3, M4, M5, M6 and their Pro/Max | 13 or later | **Expected to work, untested.** Standard white 600 nits, so the top is 166%; less in bright light, where macOS raises standard white (up to 1000 nits outdoors on M4 and later, which leaves no room to boost). |
| MacBook Air, 13" MacBook Pro, Intel MacBook Pro | | **Not supported.** No XDR panel. The menu says so, and nothing is written to the display. |
| External displays, lid closed | | **No boost.** External displays keep their own 0–100% brightness. |

"Expected to work" means the code paths are covered by tests with each model's readings (`Tests/LogicTests`), not that anyone has looked at the screen. If you have one of these Macs, please turn the boost on at the top of the scale, run `overbright report` and paste its output into [a model report](https://github.com/JJ22007/overbright/issues/new?template=model-report.md), whether it works or not. The report reads your panel and checks that the boost reached it; it changes nothing.

Every number that differs between models comes from the panel. If anything is missing or looks wrong, Overbright falls back instead of guessing:

- **Standard white** is the backlight cap macOS sets for ordinary content. While something on screen holds HDR open, macOS raises that cap to the peak; Overbright then reads standard white from CoreBrightness instead, and if that fails it does not use the direct method.
- **The peak** (`limit_max_physical_brightness`) bounds every write. A panel that peaks below 1000 nits is not XDR and is refused. Without a known peak nothing is written.
- **The ceiling** is `maxNits` (1000 by default), never more than 81% of the panel's peak.
- **The method.** On macOS 27.2 and later Overbright tries `direct` first. If the panel cannot be driven directly, or macOS does not take the write (it is read back), it falls back to `overlay`. Before 27.2 it uses `classic`. `status --json` shows the method in use (`boostMethod`) and what it read (`panel`).

## Install

### Download

Get `Overbright-universal.zip` from the [latest release](https://github.com/JJ22007/overbright/releases/latest), unzip it, and move `Overbright.app` into Applications.

The download is ad-hoc signed, not notarized by Apple. The first time you open it macOS will block it: go to System Settings → Privacy & Security and choose **Open Anyway**. You do not need to turn Gatekeeper off.

Each release also has `SHA256SUMS.txt`. Run `shasum -a 256 -c SHA256SUMS.txt` in the folder that holds both files; it should print `Overbright-universal.zip: OK`. This shows the zip is the one the release built. It is not a signature: see [SECURITY.md](SECURITY.md).

### Build from source

Needs the Swift compiler. If you have never installed it, run `xcode-select --install` first.

```bash
git clone https://github.com/JJ22007/overbright.git
cd overbright
bash scripts/install.sh
```

This runs the tests, builds the app, installs `Overbright.app` into `~/Applications`, links the `overbright` command into `~/.local/bin`, and launches it.

### Planning to rebuild? Run this once

macOS ties the Accessibility permission (used for F1/F2) to the app's code signature. A plain source build is ad-hoc signed, so every rebuild looks like a new app: the permission stops working, even though the switch in System Settings may still look on.

```bash
bash scripts/setup-signing.sh
```

The script creates a self-signed certificate in your login keychain, used only to sign your own builds, then rebuilds and installs. Grant the permission one more time and it survives every rebuild after that. If you have an Apple Developer ID, use `SIGN_ID="Developer ID Application: You" bash scripts/install.sh` instead.

## Use

1. Open **Overbright**. A sun icon appears in the menu bar.
2. Click it and choose **Turn Boost On**, or just drag the slider past 100%.
3. Choose **Restore Standard Brightness**, or quit, to put the display back exactly as it was.

**External displays.** Plug one in and it shows up in the menu with its own slider; unplug it and it goes away. Press **Control+F1** or **Control+F2** to change it, in the same steps as the built-in keys (Control+Option+Shift for fine steps). With the pointer on an external display, only that display changes; with the pointer on the MacBook's screen, every external display changes together.

**Darker than 0%.** A monitor's backlight at 0 is still lit. Keep pressing Control+F1 past 0% and the level goes negative, down to −90%: the backlight stays at its minimum and Overbright darkens the picture the rest of the way, the mirror image of the built-in display going past 100%. Coming back up, the extra dimming goes first, then the backlight. Quitting Overbright removes the extra dimming and leaves the backlight at 0.

How each display is controlled is decided automatically:

| Method | Displays | What it does |
|---|---|---|
| DDC/CI | Most monitors from Dell, LG, Samsung, BenQ, ASUS and others | Sets the display's own backlight, exactly like its buttons. The level stays in the display. |
| macOS | Apple Studio Display, LG UltraFine | The same control macOS uses. |
| Software | Displays that ignore DDC/CI: many TVs, some docks and adapters | Darkens the picture through the gamma table. It cannot make the display brighter, stops at 10% so the screen never goes black, and is undone when Overbright quits. |

DDC/CI needs Apple Silicon. On an Intel Mac every external display uses software dimming. Some monitors have DDC/CI switched off in their own on-screen menu; turn it on there.

**F1 and F2: one scale from 0% to the panel's ceiling.** The built-in display's brightness is one scale. 0–100% is the backlight, the same 16 steps as macOS's own keys. Above 100% the backlight stays at full and the boost takes over, up to the panel's ceiling or `maxLevel`. Every press moves 6.25%; hold Option+Shift for quarter steps. Overbright shows one indicator for the whole scale at the top of the screen: a sun, 16 thin, evenly spaced dashes and the percentage, styled like the macOS volume indicator. The dashes span 0% to the ceiling, so each is 1/16 of what this Mac can do.

Handling the keys needs the Accessibility permission, because Overbright has to catch them before macOS does: choose **Allow F1 / F2…** in the menu. Without it, macOS keeps the keys and its own indicator, and the boost is in the menu.

| You press | What happens |
|---|---|
| F1/F2 below 100% | The backlight moves one step, like macOS's own keys. |
| F2 at 100% | The boost starts. With `overlay` and `classic`, the very first step from an idle display takes about 0.3 s, because macOS first ramps the backlight up to its peak; every later step is immediate. `direct` has no such ramp. |
| F1 at 106% | Back to 100% at once. With `overlay` and `classic`, macOS keeps the backlight at its peak for about 15 seconds afterwards; Overbright holds the picture at standard brightness until it has come down. |
| Option+F1/F2 | Opens Displays settings, as usual. |

## Make it yours

The config lives at `~/.config/overbright/config.json`. Open it from the menu with **Edit Config File…**. Write only what you want to change; everything else keeps its default.

```json
{
  "maxLevel": 140,
  "showPercentage": true,
  "presets": [
    { "name": "Shade", "level": 115 },
    { "name": "Outdoors", "level": 140 }
  ]
}
```

| Field | Default | Meaning |
|---|---|---|
| `maxLevel` | `"auto"` | The highest level the slider, the keys and the CLI can reach. `"auto"` is as high as the panel goes, measured the first time the boost reaches the panel's peak and remembered. A number from 101 to 400 sets a lower ceiling; the panel's own still applies. |
| `keyStep` | `6.25` | Percent per F1/F2 press, across the whole scale (`up`/`down` on the command line too). |
| `fineKeyStep` | `1.5625` | Percent added per press with Option+Shift held. |
| `brightnessKeys` | `true` | Let F1/F2 continue past 100%. Set `false` to use only the menu and the CLI; the app then never asks for Accessibility. |
| `enableOnLaunch` | `false` | Turn the boost on when the app starts, at the last level you used. |
| `showPercentage` | `false` | Show the current percentage next to the menu bar icon while boosted. |
| `language` | `"auto"` | `"auto"` follows the system; `"en"` or `"zh"` forces one. |
| `externalDisplays` | `true` | Show external displays in the menu and control their brightness. |
| `externalKeys` | `true` | Control+F1/F2 adjust external displays. Needs `brightnessKeys` and the Accessibility permission. |
| `showHUD` | `true` | Show a brightness indicator on an external display while it changes. |
| `maxNits` | `1000` | Ceiling of the direct method, in nits, from 700 to 1300. 1000 is what the panel holds across the whole screen; above it the panel's own thermal limit pulls the backlight down within seconds. |
| `lowBatteryOff` | `false` | A battery percentage, 5 to 95. When the battery falls to it while unplugged, the boost ends once; turn it back on and it stays on. |
| `toggleShortcut` | `false` | A global shortcut that switches the boost, such as `"ctrl+opt+cmd+b"`: a letter, digit, F-key or `space`, with Command, Control or Option. Needs no Accessibility permission. |
| `boostMethod` | `"auto"` | How the boost brightens the built-in display: `"direct"` (macOS 27.2 and later), `"overlay"` or `"classic"` (earlier). `"auto"` picks by macOS version; force one only if the boost looks wrong. See [How it works](#how-it-works). |
| `extraDimming` | `true` | Let external displays go below 0%, down to −90%, by darkening the picture once the backlight is at its minimum. |
| `presets` | `[]` | Named levels: `name` and `level` (100 to 400). They appear in the menu and work with `overbright preset`. |

**When you get it wrong.** The menu shows **Config Problems** with the exact entry at fault. That entry falls back to its default and the rest keeps working. If the file is not valid JSON at all, the previous settings stay in effect until you fix it. You can also check a file from the terminal:

```bash
overbright check ~/.config/overbright/config.json
```

### Examples

Copy from [`examples/`](examples):

| File | For |
|---|---|
| [`minimal.json`](examples/minimal.json) | A gentler ceiling of 130% |
| [`presets.json`](examples/presets.json) | Three named levels and the percentage in the menu bar |
| [`fine-steps.json`](examples/fine-steps.json) | Smaller F1/F2 steps for precise control |
| [`menu-only.json`](examples/menu-only.json) | No key interception and no Accessibility permission |
| [`on-battery.json`](examples/on-battery.json) | Boost ends at 20% battery; Control+Option+Command+B switches it |
| [`always-on.json`](examples/always-on.json) | Boost from launch, capped at 140% |
| [`no-external.json`](examples/no-external.json) | Leave external displays alone |

## Drive it from scripts and agents

`scripts/install.sh` links the command to `~/.local/bin/overbright`. If you installed from the download, the same binary is at `/Applications/Overbright.app/Contents/MacOS/Overbright`.

```bash
overbright status            # off 125%
overbright set 140           # on 140% (the boost)
overbright set 50            # the backlight at 50%, boost off
overbright up                # one step along the scale
overbright key down          # exactly what F1 does, indicator included
overbright preset outdoors   # match a preset by name or prefix
overbright off               # back to standard brightness
overbright displays          # 2  DELL P2723DE  ddc  100%
overbright display dell 60   # external display by name, id or "all"
overbright display all down
overbright display dell -40  # backlight at 0, picture darkened to 60%
overbright report            # a Markdown report for a model report issue
overbright mcp               # the same, as MCP tools for agents (below)
overbright status --json
```

```json
{
  "boostMethod" : "direct",
  "brightnessKeys" : "on",
  "configProblems" : [],
  "direct" : { "ceilingNits" : 1000, "rewrites" : 0, "standardNits" : 600, "targetNits" : 900 },
  "edrHeadroom" : 1,
  "externalDisplays" : [
    { "control" : "ddc", "id" : 2, "level" : 100, "minimum" : -90, "name" : "DELL P2723DE" }
  ],
  "level" : 150,
  "maxLevel" : "auto",
  "panel" : { "model" : "Mac18,1", "peakNits" : 1600, "standardNits" : 600, "directPossible" : true },
  "panelMaxLevel" : 166,
  "presets" : [],
  "scale" : 150,
  "scaleTop" : 166,
  "state" : "on",
  "supported" : true,
  "version" : "2.6"
}
```

Abridged: the real object has a few more fields, mostly diagnostics. The app must be running; the command talks to it and waits for the display to actually change before it answers. `state` is `off`, `engaging`, `on` or `unavailable`. Add `--json` to any command to get the status object back.

| Exit code | Meaning |
|---|---|
| `0` | Done. |
| `1` | The app refused, or the boost is unavailable (the reason is on stderr). |
| `2` | The app is not running, or the command is malformed. |

Some things this makes easy:

```bash
# Brighter while on battery outdoors, standard at your desk
overbright preset outdoors

# A Shortcuts or Raycast action
~/.local/bin/overbright toggle

# Let an agent check before it changes anything
overbright status --json | jq -e '.supported'
```

### As MCP tools

`overbright mcp` serves the command as a [Model Context Protocol](https://modelcontextprotocol.io) server over stdio, with no dependencies. Add it to your agent's MCP config with the full path:

```json
{ "mcpServers": { "overbright": { "command": "/Users/you/.local/bin/overbright", "args": ["mcp"] } } }
```

| Tool | What it does |
|---|---|
| `status` | State, level and method, and what the panel reads now. Changes nothing. |
| `set_brightness` | `{"percent": 150}`. Waits for the panel to settle. |
| `restore` | Boost off, back to standard brightness. Waits for the backlight to come down. |
| `report` | The `overbright report` Markdown. Changes nothing. |

Every result carries the panel's readback, so an agent gets proof and not just "done". `readback` can be:

- `reached`: a `direct` boost is at the target.
- `missed`: a `direct` boost is not at the target.
- `restored`: the backlight is back at standard white.
- `notRestored`: macOS is still holding the backlight up.
- `notDirect`: `overlay` and `classic` draw on screen, so the backlight can't prove them.
- `unknown`: no reading.

`set_brightness` and `restore` are errors unless the readback proves them. The tools add no display behaviour: each runs the matching command. `status --json` has the same `readback` object.

## Build your own

When the config isn't enough, change the code. The project is written to be easy for people and coding agents to read.

1. **Fork** the repo and clone your fork.
2. Open it with your coding agent (Claude Code, Cursor, Codex, and so on). [`AGENTS.md`](AGENTS.md) already explains the layout, how to build, what can be verified without the hardware, and what must never be changed carelessly.
3. **Say what you want in plain words.** For example:
   - "Add a config option that turns the boost off automatically when the battery drops below 20%."
   - "Add a global hotkey that toggles the boost."
   - "Show the level as a small bar in the menu bar instead of a number."
   - "Add a `schedule` option: boost only between 10:00 and 16:00."
   - "Translate the interface to Japanese."
4. Run `bash scripts/install.sh` and try it.

Prefer to do it by hand? Each file has one job:

| File | Job | Look here to… |
|---|---|---|
| [`Models/Config.swift`](Sources/Overbright/Models/Config.swift) | Reading and validating the config | add a config option |
| [`Models/BoostLevel.swift`](Sources/Overbright/Models/BoostLevel.swift) | Level limits and the brightness curve | change how percent maps to brightness |
| [`Models/DDC.swift`](Sources/Overbright/Models/DDC.swift) | DDC/CI packets and external brightness steps | support another monitor feature |
| [`Services/ExternalDisplayManager.swift`](Sources/Overbright/Services/ExternalDisplayManager.swift) | Finding external displays and choosing DDC, macOS or software | change how a display is controlled |
| [`Models/BrightnessKeyStep.swift`](Sources/Overbright/Models/BrightnessKeyStep.swift) | F1/F2 step arithmetic | change how the keys step |
| [`App/CLI.swift`](Sources/Overbright/App/CLI.swift) | The `overbright` command and its server | add a command |
| [`Views/StatusItemController.swift`](Sources/Overbright/Views/StatusItemController.swift) | Menu bar icon and menu | change the menu |
| [`Support/L10n.swift`](Sources/Overbright/Support/L10n.swift) | English and Chinese text | add a language |
| [`App/AppDelegate.swift`](Sources/Overbright/App/AppDelegate.swift) | Start-up, sleep/wake, applying the config | react to a system event |
| [`Controllers/BoostController.swift`](Sources/Overbright/Controllers/BoostController.swift) | The state machine that applies and restores the boost | rarely, and carefully |
| [`Services/`](Sources/Overbright/Services) | Direct panel writes, gamma table, HDR layers, backlight, key tap | rarely |

## How it works

How Overbright brightens the built-in display depends on the macOS version (`boostMethod`).

- **direct** (macOS 27.2 and later, the default). Overbright drives the panel's backlight past standard white itself, by writing two values of the built-in display's framebuffer: its nits cap (`BLNitsCap`) and its level (`IOMFBBrightnessLevel`). No layer, no gamma table, no HDR mode: nothing is drawn on screen, so Spaces and Mission Control are left alone. 150% asks for 1.5 × standard white (600 nits, more in bright surroundings), up to `maxNits` (1000). Every write is read back; if macOS does not take it, Overbright falls back to `overlay`. macOS rewrites the backlight when it adjusts it (ambient light, automatic brightness); Overbright lets that adjustment finish, then puts the boost back about a second later. When you lower the brightness yourself, the boost ends. The values from before the boost are written back when it ends and at the next launch after a crash. Measured on a 14" MacBook Pro: 6.8 W of backlight power at 100%, 10.7 W at 166% (996 nits), steady for a minute.

The two other methods use HDR headroom instead. macOS gives an XDR display brightness above standard white only while something on screen is HDR: it then drives the backlight up to its peak (1600 nits on a MacBook Pro) and scales ordinary content back down so it looks unchanged. These methods let ordinary white keep part of that light.

- **overlay** (macOS 27.2 and later, the fallback). The gamma table no longer changes the light the panel emits, so Overbright puts a full-screen HDR layer over the built-in display that multiplies everything under it by the boost level: 160% multiplies by 1.6. Black stays black. The layer is invisible to screenshots and recordings and never takes clicks. In HDR mode macOS draws ordinary white about 9% dimmer once the backlight reaches its peak, so the layer adds that back as the backlight arrives; a percentage is therefore relative to the real standard white. No gamma table is written. macOS draws such a layer without its multiply during Spaces and Mission Control transitions, which shows as a white flash; Overbright hides the layer during transitions, which reduces this but does not remove it. That is why `direct` is the default.
- **classic** (earlier macOS). A tiny, invisible HDR layer opens the headroom. macOS scales ordinary content after the gamma table, so a table above 1 lifts white into the headroom: 160% is a table endpoint of about 1.6, capped by the headroom macOS reports.

The percentage is a request on top of standard white (500 or 600 nits at full backlight, depending on the model): 160% of 600 asks for about 960 nits. With the direct method the top is `maxNits` ÷ standard white: 1000 ÷ 600 = 166%, or 1000 ÷ 500 = 200% on M1 and M2. With the overlay method the ceiling is measured: at its peak macOS reports how far ordinary white can go (the EDR headroom, peak ÷ standard white, 1596 ÷ 600 = 2.67 on a 14" MacBook Pro), and Overbright takes off the 9% it adds back for macOS's dimmer white: 2.67 ÷ 1.09 = 244%. Other models get their own number from their own headroom; the 9% was measured on a 14" MacBook Pro only.

Before changing anything, Overbright records the display's original state, and it writes a recovery marker so that even after a crash or a forced quit the next launch restores standard brightness. **Private interfaces.** The direct method writes framebuffer properties that Apple does not document, and reading and setting the system backlight goes through macOS's DisplayServices framework, which is private too. A macOS update can stop either from working; Apple closed a similar route for other brightness tools in macOS 26.3. If a direct write is not taken, Overbright falls back to `overlay`, and `status --json` shows the method in use (`boostMethod`).

## Limits and cautions

- **The percentage is not a measurement.** 160% is a requested boost, not 1,600 nits. Peak HDR brightness is not sustainable across the full screen: near the ceiling a mostly white screen can make macOS lower the headroom after a while (heat, power), and the brightest parts then stop at what is left.
- **How the boost was measured.** With the Mac's own camera, in a dark room, while pressing real keys: `scripts/light-check.sh` (see [AGENTS.md](AGENTS.md)). The camera sees the screen's light on the room; the levels are checked with a null test that does not depend on the camera. Measured on a 14" MacBook Pro with macOS 27.2.1; the 9% correction may differ on other models.
- **The camera checks keep no pictures.** They are developer scripts; the app itself never opens the camera.
  - They save one brightness number per frame, never an image, and delete even that once the report is written (`--keep-raw` keeps it).
  - The camera stops when the check ends, fails or is interrupted.
  - To turn the permission off: System Settings → Privacy & Security → Camera → **Overbright Light Meter**.
  - Details, and how to delete old measurement files: [SECURITY.md](SECURITY.md).
- **Slightly dim for ~13 s after the boost (`overlay` and `classic`).** macOS keeps HDR mode on for about 15 s after the boost ends, and meanwhile draws ordinary white about 7% below standard. Then it lowers the backlight and white returns to standard over about 2 seconds. Overbright cannot correct this without keeping HDR mode on. `direct` does not have this: it never turns HDR mode on, and when the boost ends the backlight is back at standard white within 0.1 s (readings from `brightness-log.sh`). The camera saw no dim period either.
- **Brighter means warmer.** Higher brightness uses more power and makes more heat. macOS may dim the display on its own; Overbright does not override that.
- **Don't run two of these at once.** BetterDisplay, BrightIntosh, Lunar, f.lux and similar tools also change the gamma table. Overbright refuses to turn on when it detects an already boosted table.
- **Not for color-critical work.** With `overlay` and `classic` the boost can clip highlight detail in HDR photos and video. Whether `direct` does has not been tested. Restore standard brightness first.
- **External displays get dimmer and brighter, not overbright.** Going past 100% needs EDR headroom, which only the built-in XDR display has. An external display goes up to its own maximum.
- **DDC/CI is a conversation with the monitor.** Most answer; some answer slowly, and a few behind docks or adapters do not answer at all and fall back to software dimming. Overbright never writes anything except brightness.
- **Tested on a limited set of Macs.** See [Supported Macs](#supported-macs) for what was measured and what is only expected to work. CI runs the hardware-independent tests and builds both architectures. It cannot test a real panel.

## Coming from Display Boost?

Overbright is the new name of Display Boost from version 2.0. The app has a new bundle identifier, so quit and delete `Display Boost.app`, then allow Overbright under Accessibility once. The old repository address redirects here.

## Credits

Opening EDR headroom and lifting ordinary content into it, with the gamma table or a multiplying layer, is a technique known from [BrightIntosh](https://github.com/niklasr22/BrightIntosh) and [BetterDisplay](https://github.com/waydabber/BetterDisplay); Overbright's `classic` and `overlay` methods follow it. The `direct` method takes a different route on macOS 27.2 and later: it drives the backlight instead of drawing anything. BetterDisplay Pro also offers an experimental direct mode for the built-in XDR display.

The menu bar icons are from [Lucide](https://lucide.dev) (ISC, see [LICENSES/lucide.txt](LICENSES/lucide.txt)).

## License

[MIT](LICENSE)
