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

Overbright opens the extra brightness that a Liquid Retina XDR display normally keeps for HDR video, and lets you use it for everything: as far as the panel goes (244% of standard brightness on a 14" MacBook Pro), from the menu bar, from F1/F2, or from a command. It is about 4,000 lines of Swift with no dependencies and no Xcode project. Settings sit in one JSON file, and anything the file can't do is a short edit away, by you or by your AI coding agent.

## Features

- **Brightness past 100%.** A slider from 100% to the panel's own ceiling, measured from the EDR headroom macOS reports (244% on a 14" MacBook Pro with macOS 27.2; 160% with the classic method). The boost is limited by the headroom macOS reports at that moment, so it never asks the panel for more than it offers.
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

## Install

### Download

Get `Overbright-universal.zip` from the [latest release](https://github.com/JJ22007/overbright/releases/latest), unzip it, and move `Overbright.app` into Applications.

The download is ad-hoc signed, not notarized by Apple. The first time you open it macOS will block it: go to System Settings → Privacy & Security and choose **Open Anyway**. You do not need to turn Gatekeeper off.

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
| F2 at 100% | The boost starts. The very first step from an idle display takes about 0.3 s, because macOS first ramps the backlight up to its peak; every later step is immediate. |
| F1 at 106% | Back to 100% at once. macOS keeps the backlight at its peak for about 15 seconds afterwards; Overbright holds the picture at standard brightness until it has come down. |
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
overbright status --json
```

```json
{
  "brightnessKeys" : "on",
  "configProblems" : [],
  "externalDisplays" : [
    { "control" : "ddc", "id" : 2, "level" : 100, "minimum" : -90, "name" : "DELL P2723DE" }
  ],
  "edrHeadroom" : 1.26,
  "level" : 125,
  "maxLevel" : "auto",
  "panelMaxLevel" : 244,
  "potentialEdrHeadroom" : 16,
  "presets" : [],
  "scale" : 125,
  "scaleTop" : 244,
  "boostMethod" : "direct",
  "state" : "on",
  "supported" : true,
  "version" : "2.0"
}
```

The app must be running; the command talks to it and waits for the display to actually change before it answers. `state` is `off`, `engaging`, `on` or `unavailable`. Add `--json` to any command to get the status object back.

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
| [`Services/`](Sources/Overbright/Services) | Gamma table, EDR layer, backlight, key tap | rarely |

## How it works

macOS gives an XDR display brightness "headroom" above standard white only while something on screen is HDR. Overbright keeps a tiny, invisible HDR layer on the built-in display so that headroom opens. macOS then drives the backlight up to its peak (1600 nits on a MacBook Pro) and normally scales ordinary content back down so it looks unchanged. Overbright lets ordinary white take part of that light. How depends on the macOS version (`boostMethod`):

- **direct** (macOS 27.2 and later, the default). No layer, no gamma table, no HDR: Overbright drives the panel's backlight past standard white itself, through the framebuffer's nits cap and level. 150% asks for 1.5 × standard white (600 nits, more in bright surroundings), up to `maxNits` (1000). macOS rewrites the backlight when it adjusts it (ambient light), and Overbright puts the boost back within a quarter of a second; when you lower the brightness yourself, the boost ends. The values from before the boost are written back when it ends and after a crash. Nothing is drawn on screen, so Spaces and Mission Control look as usual. Measured on a 14" MacBook Pro: 6.8 W of backlight power at 100%, 10.7 W at 166% (996 nits), steady for a minute.

- **overlay** (macOS 27.2 and later). The gamma table no longer changes the light the panel emits, so Overbright puts a full-screen HDR layer over the built-in display that multiplies everything under it by the boost level: 160% multiplies by 1.6. Black stays black. The layer is invisible to screenshots and recordings and never takes clicks. In HDR mode macOS draws ordinary white about 9% dimmer once the backlight reaches its peak, so the layer adds that back as the backlight arrives; a percentage is therefore relative to the real standard white. No gamma table is written.
- **classic** (earlier macOS). macOS scales ordinary content after the gamma table, so a table above 1 lifts white into the headroom: 160% is a table endpoint of about 1.6, capped by the headroom macOS reports.

The percentage is a request on top of standard white (600 nits at full backlight): 160% asks for about 960 nits. The ceiling is the panel's: at its peak macOS reports how far ordinary white can go (the EDR headroom, peak ÷ standard white, 1596 ÷ 600 = 2.67 on a 14" MacBook Pro), and Overbright takes off the 9% it adds back for macOS's dimmer white: 2.67 ÷ 1.09 = 244%. Other models get their own number.

Before changing anything, Overbright records the display's original state, and it writes a recovery marker so that even after a crash or a forced quit the next launch restores standard brightness. Reading and setting the system backlight goes through macOS's DisplayServices framework, a private interface that a future macOS version could change.

## Limits and cautions

- **The percentage is not a measurement.** 160% is a requested boost, not 1,600 nits. Peak HDR brightness is not sustainable across the full screen: near the ceiling a mostly white screen can make macOS lower the headroom after a while (heat, power), and the brightest parts then stop at what is left.
- **How the boost was measured.** With the Mac's own camera, in a dark room, while pressing real keys: `scripts/light-check.sh` (see [AGENTS.md](AGENTS.md)). The camera sees the screen's light on the room; the levels are checked with a null test that does not depend on the camera. Measured on a 14" MacBook Pro with macOS 27.2.1; the 9% correction may differ on other models.
- **Slightly dim for ~13 s after the boost.** macOS keeps HDR mode on for about 15 s after the boost ends, and meanwhile draws ordinary white about 7% below standard. Then it lowers the backlight and white returns to standard over about 2 seconds. Overbright cannot correct this without keeping HDR mode on.
- **Brighter means warmer.** Higher brightness uses more power and makes more heat. macOS may dim the display on its own; Overbright does not override that.
- **Don't run two of these at once.** BetterDisplay, BrightIntosh, Lunar, f.lux and similar tools also change the gamma table. Overbright refuses to turn on when it detects an already boosted table.
- **Not for color-critical work.** The boost can clip highlight detail in HDR photos and video. Restore standard brightness first.
- **External displays get dimmer and brighter, not overbright.** Going past 100% needs EDR headroom, which only the built-in XDR display has. An external display goes up to its own maximum.
- **DDC/CI is a conversation with the monitor.** Most answer; some answer slowly, and a few behind docks or adapters do not answer at all and fall back to software dimming. Overbright never writes anything except brightness.
- **Tested on a limited set of Macs.** CI runs the hardware-independent tests and builds both architectures. It cannot test a real panel.

## Coming from Display Boost?

Overbright is the new name of Display Boost from version 2.0. The app has a new bundle identifier, so quit and delete `Display Boost.app`, then allow Overbright under Accessibility once. The old repository address redirects here.

## Credits

Using EDR headroom together with the gamma table is a technique known from tools such as [BrightIntosh](https://github.com/niklasr22/BrightIntosh) and [BetterDisplay](https://github.com/waydabber/BetterDisplay). If you want a mature tool with many more features, use one of those. Overbright has a different goal: to be small enough that you can make it entirely your own.

The menu bar icons are from [Lucide](https://lucide.dev) (ISC, see [LICENSES/lucide.txt](LICENSES/lucide.txt)).

## License

[MIT](LICENSE)
