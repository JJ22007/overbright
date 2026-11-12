// Measures the light the built-in display really emits while pressing real
// brightness keys, with the Mac's own camera. See scripts/light-check.sh and
// AGENTS.md ("Measuring brightness").
//
// The camera faces the user, not the screen, but the screen lights the user's
// face and the room. With a dark room, each frame's mean brightness follows the
// screen within a frame. The camera's exposure cannot be locked, so this tool
// only trusts comparisons made within a few seconds of each other:
//   - presses: did each real key press move the light the right way, and how fast
//   - ratio:   a "null test" that does not depend on the camera's response. At
//              boost level X the white patch is replaced by a grey that emits
//              exactly 1/X of white. If the boost is right, the camera reads the
//              same as plain white at the standard 100%.
//   - release: the light after leaving the boost, while macOS lowers the backlight
//
// Shows a black screen with a white patch (10% of the area) for about two
// minutes, then restores the display. Records numbers only; no image is kept.
import AppKit
import Foundation

setvbuf(stdout, nil, _IOLBF, 0)
var outputDirectory = "outputs/light-check"
var cli = (NSHomeDirectory() as NSString).appendingPathComponent(".local/bin/overbright")
var force = false
var arguments = CommandLine.arguments.dropFirst().makeIterator()
while let argument = arguments.next() {
    switch argument {
    case "--out": outputDirectory = arguments.next() ?? outputDirectory
    case "--cli": cli = arguments.next() ?? cli
    case "--force": force = true
    default:
        FileHandle.standardError.write(Data("usage: light-check [--out dir] [--cli path] [--force]\n".utf8))
        exit(2)
    }
}
let root = FileManager.default.currentDirectoryPath
try? FileManager.default.createDirectory(atPath: outputDirectory, withIntermediateDirectories: true)
let cameraFile = (outputDirectory as NSString).appendingPathComponent("camera.tsv")
let absoluteCameraFile = cameraFile.hasPrefix("/") ? cameraFile : root + "/" + cameraFile

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("light-check: \(message)\n".utf8))
    exit(1)
}

@discardableResult
func overbright(_ args: [String]) -> (Int32, String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: cli)
    process.arguments = args
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try? process.run()
    process.waitUntilExit()
    let text = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    return (process.terminationStatus, text.trimmingCharacters(in: .whitespacesAndNewlines))
}

func status() -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: Data(overbright(["status", "--json"]).1.utf8))) as? [String: Any] ?? [:]
}

guard let sampler = BrightnessSampler() else { fail("no built-in display") }
let before = status()
guard let startScale = before["scale"] as? Double else { fail("Overbright is not running (scripts/install.sh)") }
let startState = before["state"] as? String ?? "off"

// MARK: Screen: black with a white (or grey) patch

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let screen = NSScreen.screens.first {
    ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == sampler.displayID
} ?? NSScreen.main!
let window = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
window.backgroundColor = .black
window.level = .floating
window.ignoresMouseEvents = true
window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
let side = screen.frame.size.applying(.init(scaleX: 0.1.squareRoot(), y: 0.1.squareRoot()))
let patch = NSView(frame: NSRect(x: (screen.frame.width - side.width) / 2, y: (screen.frame.height - side.height) / 2,
                                 width: side.width, height: side.height))
patch.wantsLayer = true
window.contentView?.addSubview(patch)
window.setFrame(screen.frame, display: true)

/// Sets the patch to emit `linear` × white (sRGB encoding, so the panel's
/// standard response turns it back into that fraction of the light).
func setPatch(_ linear: Double) {
    let encoded = linear <= 0.0031308 ? 12.92 * linear : 1.055 * pow(linear, 1 / 2.4) - 0.055
    patch.layer?.backgroundColor = NSColor(srgbRed: encoded, green: encoded, blue: encoded, alpha: 1).cgColor
}
setPatch(1)

func now() -> Double { Date().timeIntervalSince1970 }
func pump(_ seconds: Double) {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end { RunLoop.current.run(until: min(end, Date().addingTimeInterval(0.05))) }
}

func restore() {
    window.orderOut(nil)
    if startState == "on" || startScale <= 100 {
        overbright(["set", String(format: "%.2f", startScale)])
    } else {
        overbright(["off"])
    }
}

// MARK: Run

// Start from the standard 100%, with the backlight back from any earlier EDR.
overbright(["set", "100"])
print("waiting for the backlight to return to its standard level…")
let settleDeadline = now() + 30
while now() < settleDeadline {
    let s = sampler.sample(at: 0)
    if let panel = s.panelNits, let standard = s.standardNits, panel <= standard * 1.01 + 0.5 { break }
    pump(0.25)
}
window.orderFrontRegardless()

let camera = Process()
camera.executableURL = URL(fileURLWithPath: "/usr/bin/open")
camera.arguments = ["-n", "-W", root + "/.build/BrightnessCamera.app", "--args", "--out", absoluteCameraFile, "--seconds", "150"]
try? FileManager.default.removeItem(atPath: absoluteCameraFile)
do { try camera.run() } catch { restore(); fail("could not start the camera meter: \(error)") }
pump(4)

let room = checkRoom(cameraFile: absoluteCameraFile, setPatch: setPatch, pump: pump, now: now)
print("room: \(room.summary)")
if !room.isDark && !force {
    restore(); camera.terminate()
    fail("\(RoomCheck.advice)\n(\(room.summary))")
}

struct Mark { var time: Double; var label: String; var scale: String }
var marks: [Mark] = []
var panelTrace: [(Double, Double)] = []
func mark(_ label: String, _ scale: String = "") { marks.append(Mark(time: now(), label: label, scale: scale)) }

print("presses: 10 × F2 (real key), 10 × F1")
mark("start")
pump(1.5)
for direction in ["up", "down"] {
    for _ in 0..<10 {
        let t = now()
        let (code, text) = overbright(["key", direction, "--real"])
        guard code == 0 else { restore(); fail("a real key press was refused: \(text)") }
        let scale = text.components(separatedBy: "scale ").last?.replacingOccurrences(of: ")", with: "") ?? "?"
        marks.append(Mark(time: t, label: direction, scale: scale))
        pump(1.5)
    }
}
print("release: 24 s at 100% while macOS lowers the backlight")
mark("release")
let releaseEnd = now() + 24
while now() < releaseEnd {
    if let panel = sampler.sample(at: 0).panelNits { panelTrace.append((now(), panel)) }
    pump(0.2)
}
print("ratio: grey patches at 106%, 125% and 160% against white at 100%")
mark("reference")
pump(2.5)
for level in [106.25, 125.0, 160.0] {
    overbright(["set", String(level)])
    setPatch(100 / level)
    mark("ratio", String(format: "%.2f%%", level))
    pump(2.5)
}
overbright(["set", "100"])
setPatch(1)
pump(1)
restore()
camera.terminate()
pump(1)

// MARK: Analysis

let cameraText = (try? String(contentsOfFile: absoluteCameraFile, encoding: .utf8)) ?? ""
let frames: [(Double, Double)] = cameraText.split(separator: "\n").compactMap { line in
    let parts = line.split(separator: "\t")
    guard parts.count >= 2, let t = Double(parts[0]), let v = Double(parts[1]) else { return nil }
    return (t, v)
}
guard frames.count > 100 else { fail("the camera recorded no frames (camera permission for Overbright Light Meter?)") }
func mean(_ from: Double, _ to: Double) -> Double {
    let s = frames.filter { $0.0 >= from && $0.0 < to }.map(\.1)
    return s.isEmpty ? .nan : s.reduce(0, +) / Double(s.count)
}

var failures: [String] = []
var rows: [String] = []
// Camera units per unit of log light, from 100% → 160% (a known ratio of 1.6).
let firstUp = marks.first { $0.label == "up" }!
let lastUp = marks.last { $0.label == "up" }!
let sensitivity = (mean(lastUp.time + 1.2, lastUp.time + 1.45) - mean(firstUp.time - 1.2, firstUp.time - 0.05)) / log(1.6)
/// The worst excursion past the start and end of a press, in % of light.
func overshoot(_ t: Double, before: Double, after: Double, up: Bool) -> Double {
    let bins = stride(from: t, to: t + 1.45, by: 0.1).map { mean($0, $0 + 0.1) }.filter { !$0.isNaN }
    let excess = up ? (bins.max() ?? after) - max(before, after) : min(before, after) - (bins.min() ?? after)
    return max(excess, 0) / sensitivity * 100
}
let start = marks.first { $0.label == "start" }!
var previous = mean(start.time + 0.3, start.time + 1.45)
let reference100 = previous
var at160 = Double.nan
let presses = marks.filter { $0.label == "up" || $0.label == "down" }
for (index, press) in presses.enumerated() {
    let after = mean(press.time + 1.2, press.time + 1.45)
    let delta = after - previous
    let target = previous + 0.9 * delta
    let t90 = frames.first { $0.0 >= press.time && (delta >= 0 ? $0.1 >= target : $0.1 <= target) }.map { $0.0 - press.time } ?? .nan
    var verdict = "ok"
    if press.label == "up" && delta <= 0.05 { verdict = "FAIL: not brighter" }
    if press.label == "down" && delta >= -0.05 { verdict = "FAIL: not dimmer" }
    if verdict != "ok" { failures.append("press \(index + 1) (\(press.label) → \(press.scale)): \(verdict)") }
    let over = overshoot(press.time, before: previous, after: after, up: press.label == "up")
    if verdict == "ok" && over > 3 {
        verdict = String(format: "FAIL: overshoots by %.1f%%", over)
        failures.append("press \(index + 1) (\(press.label) → \(press.scale)): \(verdict)")
    }
    if press.scale.hasPrefix("160") { at160 = after }
    rows.append(String(format: "| %d | %@ | %@ | %.2f → %.2f | %+.2f | %.2f s | %.1f%% | %@ |", index + 1,
                       press.label == "up" ? "F2" : "F1", press.scale, previous, after, delta, t90, over, verdict))
    previous = after
}

let reference = marks.first { $0.label == "reference" }!
let referenceValue = mean(reference.time + 1.2, reference.time + 2.4)
var ratioRows: [String] = []
for m in marks where m.label == "ratio" {
    let value = mean(m.time + 1.2, m.time + 2.4)
    let error = (value - referenceValue) / sensitivity * 100
    let ok = abs(error) <= 5
    if !ok { failures.append("\(m.scale) is \(String(format: "%+.1f", error))% off its target") }
    ratioRows.append(String(format: "| %@ | %.2f | %.2f | %+.1f%% | %@ |", m.scale, referenceValue, value, error, ok ? "ok" : "FAIL"))
}

let release = marks.first { $0.label == "release" }!
let steady = mean(reference.time - 2, reference.time)
var releaseRows: [String] = []
for k in stride(from: 0, to: 24, by: 2) {
    let t = release.time + Double(k)
    let value = mean(t, t + 2)
    let panel = panelTrace.filter { $0.0 >= t && $0.0 < t + 2 }.map(\.1).max() ?? .nan
    releaseRows.append(String(format: "| +%d s | %.0f | %.2f | %+.1f%% |", k, panel, value, (value - steady) / sensitivity * 100))
}

let lastPress = presses.last!
let report = """
# Light check

\(failures.isEmpty ? "**PASS**" : "**FAIL**"). Measured with the built-in camera, real key presses, \(frames.count) camera frames. Room: \(room.summary).\(room.isDark ? "" : " **Not dark enough: not a valid result.**")

Sensitivity: 100% → 160% moved the camera from \(String(format: "%.2f", reference100)) to \(String(format: "%.2f", at160)), \(String(format: "%.2f", sensitivity)) units per unit of log light. Percentages below are light, derived from that.

## Presses

| # | key | scale | camera before → after | change | 90% reached | overshoot | verdict |
|---|-----|-------|-----------------------|--------|-------------|-----------|---------|
\(rows.joined(separator: "\n"))

## Ratio (null test)

Grey patch emitting 1/X of white at boost X, against white at the standard 100%. Equal readings mean the boost is exactly X.

| boost | white at 100% | grey at boost | light error | verdict |
|-------|---------------|---------------|-------------|---------|
\(ratioRows.joined(separator: "\n"))

## After leaving the boost

Light relative to the steady 100% at the end, while macOS brings the backlight down. The last press was at \(String(format: "%.1f", release.time - lastPress.time)) s before +0 s. (Not judged: macOS keeps EDR on for about 15 s by itself.)

| time | max backlight (nits) | camera | light vs steady 100% |
|------|----------------------|--------|----------------------|
\(releaseRows.joined(separator: "\n"))

"""
+ (failures.isEmpty ? "" : "\n## Failures\n\n" + failures.map { "- \($0)" }.joined(separator: "\n") + "\n")
try? report.write(toFile: (outputDirectory as NSString).appendingPathComponent("report.md"), atomically: true, encoding: .utf8)
let marksText = marks.map { String(format: "%.3f\t%@\t%@", $0.time, $0.label, $0.scale) }.joined(separator: "\n") + "\n"
try? marksText.write(toFile: (outputDirectory as NSString).appendingPathComponent("marks.tsv"), atomically: true, encoding: .utf8)
print(report)
exit(failures.isEmpty ? 0 : 1)
