// Does the gamma table change the light the built-in display emits? Measured
// with the Mac's own camera, in a dark room. See scripts/gamma-check.sh and
// AGENTS.md ("Measuring brightness").
//
// Each comparison alternates a reference and a test four times, two seconds
// each, and reads the camera within those seconds only (its exposure cannot be
// locked). Every gamma comparison has a control beside it: the same change made
// in the picture itself, which the camera must see. If the gamma change moves
// the camera like its control, the table changes the light; if it does not
// move it, the table is ignored.
//   A. No HDR: gamma table scaled to 0.5, against a patch drawn at 0.5.
//   B. HDR open (the classic method, which raises the table above 1):
//      160% against 106%, against a patch 1.5 times dimmer.
//
// Shows a black screen with a white patch (10% of the area), writes the gamma
// table and, for part B, sets "boostMethod": "classic" in the config file for
// the duration. Puts the table, the config file and the boost back at the end,
// also on Ctrl-C. Records numbers only; no image is kept.
import AppKit
import Foundation

setvbuf(stdout, nil, _IOLBF, 0)
var outputDirectory = "outputs/gamma-check"
var cli = (NSHomeDirectory() as NSString).appendingPathComponent(".local/bin/overbright")
var force = false
var arguments = CommandLine.arguments.dropFirst().makeIterator()
while let argument = arguments.next() {
    switch argument {
    case "--out": outputDirectory = arguments.next() ?? outputDirectory
    case "--cli": cli = arguments.next() ?? cli
    case "--force": force = true
    default:
        FileHandle.standardError.write(Data("usage: gamma-check [--out dir] [--cli path] [--force]\n".utf8))
        exit(2)
    }
}
let root = FileManager.default.currentDirectoryPath
try? FileManager.default.createDirectory(atPath: outputDirectory, withIntermediateDirectories: true)
let cameraFile = (outputDirectory as NSString).appendingPathComponent("camera.tsv")
let absoluteCameraFile = cameraFile.hasPrefix("/") ? cameraFile : root + "/" + cameraFile

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

guard let sampler = BrightnessSampler() else {
    FileHandle.standardError.write(Data("gamma-check: no built-in display\n".utf8)); exit(1)
}
let before = status()
guard let startScale = before["scale"] as? Double else {
    FileHandle.standardError.write(Data("gamma-check: Overbright is not running (scripts/install.sh)\n".utf8)); exit(1)
}
let startState = before["state"] as? String ?? "off"
let startLevel = before["level"] as? Double
let display = sampler.displayID

// MARK: What has to be put back

let configURL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".config/overbright/config.json")
let originalConfig = try? Data(contentsOf: configURL)
var configChanged = false

var tableSize: UInt32 = 0
var originalRed = [CGGammaValue](repeating: 0, count: 1024), originalGreen = originalRed, originalBlue = originalRed
guard CGGetDisplayTransferByTable(display, 1024, &originalRed, &originalGreen, &originalBlue, &tableSize) == .success,
      tableSize > 1 else {
    FileHandle.standardError.write(Data("gamma-check: cannot read the gamma table\n".utf8)); exit(1)
}
var tableChanged = false
func setTable(scale: Float) {
    let n = Int(tableSize)
    let r = originalRed.prefix(n).map { $0 * scale }, g = originalGreen.prefix(n).map { $0 * scale }
    let b = originalBlue.prefix(n).map { $0 * scale }
    CGSetDisplayTransferByTable(display, tableSize, r, g, b)
    tableChanged = scale != 1
}
func restoreTable() {
    CGSetDisplayTransferByTable(display, tableSize, Array(originalRed.prefix(Int(tableSize))),
                                Array(originalGreen.prefix(Int(tableSize))), Array(originalBlue.prefix(Int(tableSize))))
    tableChanged = false
}
func setConfig(classic: Bool) {
    if classic {
        var object = (originalConfig.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]) ?? [:]
        object["boostMethod"] = "classic"
        if let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: configURL)
            configChanged = true
        }
    } else if configChanged {
        if let originalConfig { try? originalConfig.write(to: configURL) } else { try? FileManager.default.removeItem(at: configURL) }
        configChanged = false
    }
}

// MARK: Screen: black with a white (or grey) patch

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let screen = NSScreen.screens.first {
    ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == display
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

/// The patch emits `linear` × white (sRGB encoding).
func setPatch(_ linear: Double) {
    let encoded = linear <= 0.0031308 ? 12.92 * linear : 1.055 * pow(linear, 1 / 2.4) - 0.055
    setPatchEncoded(encoded)
}
/// The patch at a pixel value, as the gamma table sees it.
func setPatchEncoded(_ encoded: Double) {
    patch.layer?.backgroundColor = NSColor(srgbRed: encoded, green: encoded, blue: encoded, alpha: 1).cgColor
}
setPatch(1)

func now() -> Double { Date().timeIntervalSince1970 }
func pump(_ seconds: Double) {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end { RunLoop.current.run(until: min(end, Date().addingTimeInterval(0.05))) }
}

let camera = Process()
func restoreAll() {
    restoreTable()
    if configChanged { overbright(["off"]); setConfig(classic: false); pump(2) }
    window.orderOut(nil)
    restoreBoost(state: startState, scale: startScale, level: startLevel) { overbright($0) }
    if camera.isRunning { camera.terminate() }
}
func fail(_ message: String) -> Never {
    restoreAll()
    FileHandle.standardError.write(Data("gamma-check: \(message)\n".utf8))
    exit(1)
}
for sig in [SIGINT, SIGTERM, SIGHUP] {
    signal(sig) { _ in
        restoreTable()
        if let original = originalConfig { try? original.write(to: configURL) }
        exit(130)
    }
}

// MARK: Run

overbright(["off"])
print("waiting for the backlight to return to its standard level…")
let settleDeadline = now() + 30
while now() < settleDeadline {
    let s = sampler.sample(at: 0)
    if let panel = s.panelNits, let standard = s.standardNits, panel <= standard * 1.01 + 0.5, (s.edr ?? 1) <= 1.01 { break }
    pump(0.25)
}
window.orderFrontRegardless()
camera.executableURL = URL(fileURLWithPath: "/usr/bin/open")
camera.arguments = ["-n", "-W", root + "/.build/BrightnessCamera.app", "--args", "--out", absoluteCameraFile, "--seconds", "150"]
try? FileManager.default.removeItem(atPath: absoluteCameraFile)
do { try camera.run() } catch { fail("could not start the camera meter: \(error)") }
pump(4)

let room = checkRoom(cameraFile: absoluteCameraFile, setPatch: setPatch, pump: pump, now: now)
print("room: \(room.summary)")
if !room.isDark && !force {
    fail("\(RoomCheck.advice)\n(\(room.summary))")
}

struct Comparison {
    var name: String
    var reference: String
    var test: String
    var windows: [(ref: (Double, Double), test: (Double, Double))] = []
    var readings: [String] = []
}
func compare(_ name: String, reference: String, test: String,
             setReference: () -> Void, setTest: () -> Void, settle: Double = 2.0) -> Comparison {
    print("\(name): \(reference) against \(test)")
    var c = Comparison(name: name, reference: reference, test: test)
    for _ in 0..<4 {
        setReference(); let r = now(); pump(settle)
        setTest(); let t = now(); pump(settle)
        c.windows.append(((r + settle - 0.9, r + settle - 0.05), (t + settle - 0.9, t + settle - 0.05)))
    }
    let s = sampler.sample(at: 0)
    c.readings.append(String(format: "panel %.0f nits, EDR %.2f, gamma endpoint %.3f",
                             s.panelNits ?? .nan, s.edr ?? .nan, s.gamma ?? .nan))
    setReference()
    pump(0.5)
    return c
}

var comparisons: [Comparison] = []
// A. No HDR open.
comparisons.append(compare("A control", reference: "white patch", test: "patch at pixel value 0.5",
                           setReference: { setPatchEncoded(1) }, setTest: { setPatchEncoded(0.5) }))
var gammaAReading = ""
comparisons.append(compare("A gamma", reference: "gamma table as it was", test: "gamma table × 0.5",
                           setReference: { restoreTable() },
                           setTest: { setTable(scale: 0.5); pump(0.05)
                               gammaAReading = String(format: "gamma endpoint while scaled: %.3f", sampler.sample(at: 0).gamma ?? .nan) }))
restoreTable()

// B. HDR open, through the classic method.
setConfig(classic: true)
pump(2.5)
overbright(["set", "106.25"])
pump(3)
let method = status()["boostMethod"] as? String ?? "?"
var partB = method == "classic"
if partB {
    comparisons.append(compare("B control", reference: "white patch", test: "patch emitting 1/1.5",
                               setReference: { setPatch(1) }, setTest: { setPatch(1 / 1.5) }))
    var endpoints: [String] = []
    comparisons.append(compare("B gamma", reference: "classic boost at 160%", test: "classic boost at 106%",
                               setReference: { overbright(["set", "160"]); pump(0.3)
                                   endpoints.append(String(format: "160%%: %.3f", sampler.sample(at: 0).gamma ?? .nan)) },
                               setTest: { overbright(["set", "106.25"]); pump(0.3)
                                   endpoints.append(String(format: "106%%: %.3f", sampler.sample(at: 0).gamma ?? .nan)) },
                               settle: 2.5))
    comparisons[comparisons.count - 1].readings.append("gamma endpoints written: " + Array(Set(endpoints)).sorted().joined(separator: ", "))
} else {
    print("part B skipped: the boost did not switch to the classic method (\(method))")
}
comparisons[1].readings.append(gammaAReading)
restoreAll()
pump(1)

// MARK: Analysis

let frames = cameraFrames(absoluteCameraFile)
guard frames.count > 100 else {
    FileHandle.standardError.write(Data("gamma-check: the camera recorded no frames (camera permission for Overbright Light Meter?)\n".utf8)); exit(1)
}
struct Result { var ref: Double; var test: Double; var change: Double; var error: Double }
func result(_ c: Comparison) -> Result {
    let pairs = c.windows.map { (cameraMean(frames, $0.ref.0, $0.ref.1), cameraMean(frames, $0.test.0, $0.test.1)) }
        .filter { !$0.0.isNaN && !$0.1.isNaN }
    let diffs = pairs.map { $0.1 - $0.0 }
    let n = Double(max(diffs.count, 1))
    let m = diffs.reduce(0, +) / n
    let sd = (diffs.map { ($0 - m) * ($0 - m) }.reduce(0, +) / max(n - 1, 1)).squareRoot()
    return Result(ref: pairs.map(\.0).reduce(0, +) / n, test: pairs.map(\.1).reduce(0, +) / n, change: m, error: sd / n.squareRoot())
}
func verdict(gamma: Result, control: Result) -> String {
    guard abs(control.change) > 3 * control.error, abs(control.change) > 0.1 else {
        return "inconclusive: the camera did not see the control clearly"
    }
    let share = gamma.change / control.change
    if abs(share) < 0.2 { return String(format: "the gamma table did NOT change the light (%.0f%% of the control)", share * 100) }
    if share > 0.6 { return String(format: "the gamma table changed the light (%.0f%% of the control)", share * 100) }
    return String(format: "partly (%.0f%% of the control)", share * 100)
}

var rows: [String] = []
var results: [String: Result] = [:]
for c in comparisons {
    let r = result(c)
    results[c.name] = r
    rows.append(String(format: "| %@ | %@ | %@ | %.2f | %.2f | %+.2f ± %.2f |", c.name, c.reference, c.test, r.ref, r.test, r.change, r.error))
}
var verdicts: [String] = []
if let g = results["A gamma"], let k = results["A control"] { verdicts.append("- **No HDR:** " + verdict(gamma: g, control: k)) }
if partB, let g = results["B gamma"], let k = results["B control"] { verdicts.append("- **HDR open (classic method):** " + verdict(gamma: g, control: k)) }
if !partB { verdicts.append("- **HDR open:** not measured (the boost did not switch to the classic method)") }
let details = comparisons.flatMap { c in c.readings.filter { !$0.isEmpty }.map { "- \(c.name): \($0)" } }

let os = ProcessInfo.processInfo.operatingSystemVersion
let report = """
# Gamma check

Measured with the built-in camera, \(frames.count) frames, macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion).

Room: \(room.summary).\(room.isDark ? "" : " **Not dark enough; run with --force only to look, not to conclude.**")

\(verdicts.joined(separator: "\n"))

Each row alternates its reference and test four times, two seconds each (2.5 s for B gamma), and compares the camera's mean in the last 0.85 s of each. The change is test minus reference, in camera units (mean luma), ± its standard error over the four cycles. The camera's response is not linear, so only compare a gamma row with its own control: a table that works moves the camera like the control does.

| comparison | reference | test | camera, reference | camera, test | change |
|---|---|---|---|---|---|
\(rows.joined(separator: "\n"))

\(details.joined(separator: "\n"))
"""
let reportFile = (outputDirectory as NSString).appendingPathComponent("report.md")
try? report.write(toFile: reportFile, atomically: true, encoding: .utf8)
print(report)
print("report: \(reportFile)")
