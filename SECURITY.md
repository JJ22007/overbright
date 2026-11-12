# Security and privacy

## Reporting a problem

Use **Report a vulnerability** on the repository's Security tab. It is private to the maintainer. If you can't use it, open an issue that says there is a security problem, without the details, and you will be contacted.

## What Overbright can change

- **The built-in display's backlight** (`direct`, the default on macOS 27.2+). It writes two framebuffer values, the backlight cap and the level.
  - Every write is bounded by `maxNits`: 1000 by default, never outside 700–1300, and never above a share of the panel's own peak.
  - The panel's thermal limit is never disabled or worked around.
  - When the boost ends, the cap and level go back to standard white as macOS reports it, or to the saved cap if that report is not believable.
- **The gamma table and an HDR overlay window** (`classic`, `overlay`).
- **External displays**, through DDC/CI. Only brightness is written.

Whatever was changed is put back when the boost ends, on quit, on SIGTERM, on sleep, and when the color profile changes. If the app crashes, a marker in its preferences makes the next launch restore first. It never writes CoreBrightness settings.

## Permissions

- **Accessibility**: only for F1/F2 above 100%. Without it, the menu and the command still work.
- **No camera, no network, no sudo.** The app itself never opens the camera and makes no network requests. `scripts/install.sh` builds and installs for the current user only.

## The `overbright` command

The command reaches the running app through a macOS distributed notification. Every process in your login session can post one, sandboxed apps included. So each request must carry a token:

- The app writes a fresh token at every launch to `~/Library/Application Support/Overbright/command-token`, readable only by you (mode 0600). Sandboxed apps cannot read it.
- Replies are written only to `.reply` files in your own temporary directory.

A program running as you, outside a sandbox, can still read the token and drive the boost. It could do the same through Accessibility, or change your settings in other ways. The token is not meant to stop it.

## Downloads

Releases are built by GitHub Actions from a tagged commit. The `.zip` is ad-hoc signed, not notarized by Apple. Each release has a `SHA256SUMS.txt`. In the folder that holds both files, run:

```bash
shasum -a 256 -c SHA256SUMS.txt
```

It should print `Overbright-universal.zip: OK`. This checks that the file is the one the release built. It is not a signature: anyone who can change the release can change both files. Building from source avoids trusting the download.

## Camera measurements (developers only)

`scripts/light-check.sh` and `scripts/gamma-check.sh` measure emitted light with the Mac's built-in camera, in a dark room. They are not part of the app, and nothing runs them unless you do.

### What they record

- **Kept:** a helper app ("Overbright Light Meter", `.build/BrightnessCamera.app`, bundle ID `io.github.jj22007.overbright.camera-meter`) opens the camera at 640×480. It keeps one row of numbers per frame:
  - time,
  - mean brightness,
  - centre brightness,
  - share of clipped pixels.
- **Never kept:** no image or video is written, at any point, and there is no option to write one.
- **Deleted by default:** the numbers still show when someone sat in front of the Mac. The raw file (`camera.tsv`) is deleted once `report.md` is written, and also when the check fails or is interrupted. `--keep-raw` keeps it.
- **The camera stops when the check stops.** The helper stops when the check finishes, fails, is interrupted (Ctrl-C, SIGTERM) or crashes. It also stops after a fixed time.

### Other files in `outputs/`

The checks write reports and logs there, and `outputs/` is not committed. Older versions of the measurement scripts also saved **screenshots of the top of the screen** (to check the brightness indicator). These may show whatever was on screen at the time. Those are screen captures, not camera images.

### Deleting

Move the files to the Trash and empty it, or use `rm`. On an APFS SSD, overwriting a file in place does not reliably erase the old blocks, so this project does not offer "secure delete". What protects deleted data is FileVault (full-disk encryption): check it in System Settings → Privacy & Security → FileVault. Also check that the folder isn't in a Time Machine backup or a synced folder (iCloud Drive's Desktop & Documents, Dropbox).

### Turning the camera permission off

- **Revoke it:** System Settings → Privacy & Security → Camera, turn off **Overbright Light Meter**. Or run:

  ```bash
  tccutil reset Camera io.github.jj22007.overbright.camera-meter
  ```

- **Remove the helper:** `rm -rf .build/BrightnessCamera.app`. The next camera check builds it again, and macOS asks for the camera again.
