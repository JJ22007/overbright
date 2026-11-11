// Drives the built-in display through a scenario and measures every step.
// See scripts/brightness-check.sh and AGENTS.md.
//
// One timeline, three sources:
//   - samples every 20 ms from BrightnessSampler (read-only)
//   - the scenario's key presses, sent with `overbright key up|down`, which runs
//     exactly what F1/F2 run, indicator included
//   - screen frames of the top of the built-in display, ~5 per second, to see
//     which indicators appear and when
// Writes samples.tsv, events.tsv, frames/ and report.md into the output folder,
// then puts the display back where it started.
import AppKit
import Foundation

setvbuf(stdout, nil, _IOLBF, 0)

// MARK: Options

var outputDirectory = "outputs/brightness-check"
var scenarioName = "full"
var captureFrames = true
var model = BrightnessSampler.Model.panel
var cli = (NSHomeDirectory() as NSString).appendingPathComponent(".local/bin/overbright")
var arguments = CommandLine.arguments.dropFirst().makeIterator()
while let argument = arguments.next() {
    switch argument {
    case "--out": outputDirectory = arguments.next() ?? outputDirectory
    case "--scenario": scenarioName = arguments.next() ?? scenarioName
    case "--no-frames": captureFrames = false
    case "--model": model = BrightnessSampler.Model(rawValue: arguments.next() ?? "") ?? .panel
    case "--cli": cli = arguments.next() ?? cli
    default:
        FileHandle.standardError.write(Data("usage: brightness-check [--scenario full|boost|native] [--out dir] [--no-frames] [--model panel|classic] [--cli path]\n".utf8))
        exit(2)
    }
}

// MARK: Scenario

enum Step {
    case key(String, fine: Bool)
    case set(Double)
    case wait(Double)
    case note(String)
}

func steps(_ name: String) -> [Step] {
    let pause = 0.7
    func keys(_ direction: String, _ count: Int) -> [Step] {
        (0..<count).flatMap { _ in [Step.key(direction, fine: false), .wait(pause)] }
    }
    let boost: [Step] = [.note("100 → 160, one key at a time")] + keys("up", 10)
        + [.note("160 → 100")] + keys("down", 10)
        + [.note("hold at 100 while macOS releases EDR"), .wait(20)]
    let native: [Step] = [.note("100 → 75 → 100 on the backlight")] + keys("down", 4) + keys("up", 4)
        + [.note("fine steps"), .key("up", fine: true), .wait(pause), .key("down", fine: true), .wait(pause)]
    let enterLeave: [Step] = [.note("off → 106 → off, quickly"), .key("up", fine: false), .wait(2.5),
                              .key("down", fine: false), .wait(20)]
    switch name {
    case "boost": return [.set(100), .wait(2)] + boost
    case "native": return [.set(100), .wait(2)] + native
    default: return [.set(100), .wait(2)] + enterLeave + boost + native
    }
}

// MARK: Helpers

@discardableResult
func run(_ path: String, _ args: [String]) -> (Int32, String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = args
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try? process.run()
    process.waitUntilExit()
    let text = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    return (process.terminationStatus, text.trimmingCharacters(in: .whitespacesAndNewlines))
}

func status() -> [String: Any]? {
    let (code, text) = run(cli, ["status", "--json"])
    guard code == 0 else { return nil }
    return try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
}

guard let sampler = BrightnessSampler(model: model) else { print("no built-in display"); exit(1) }
guard let initial = status(), let initialScale = initial["scale"] as? Double else {
    print("Overbright is not running or too old (needs `status --json` with \"scale\"). Install it first.")
    exit(2)
}

let fm = FileManager.default
let framesDirectory = (outputDirectory as NSString).appendingPathComponent("frames")
try? fm.removeItem(atPath: outputDirectory)
try fm.createDirectory(atPath: framesDirectory, withIntermediateDirectories: true)

// MARK: Sampling and frames, in the background

let start = Date()
func now() -> Double { Date().timeIntervalSince(start) }
let lock = NSLock()
var samples: [BrightnessSample] = []
var frames: [(Double, String)] = []
var running = true

Thread.detachNewThread {
    while lock.withLock({ running }) {
        let sample = sampler.sample(at: now())
        lock.withLock { samples.append(sample) }
        Thread.sleep(forTimeInterval: 0.02)
    }
}

// The top quarter of the built-in display, where macOS and Overbright show
// their indicators.
let bounds = CGDisplayBounds(sampler.displayID)
let region = "\(Int(bounds.minX)),\(Int(bounds.minY)),\(Int(bounds.width)),\(Int(bounds.height / 4))"
if captureFrames {
    Thread.detachNewThread {
        var index = 0
        while lock.withLock({ running }) {
            let t = now()
            let name = String(format: "%04d-%07.2fs.png", index, t)
            let path = (framesDirectory as NSString).appendingPathComponent(name)
            let (code, _) = run("/usr/sbin/screencapture", ["-x", "-t", "png", "-R", region, path])
            if code == 0 { lock.withLock { frames.append((t, name)) } }
            index += 1
            Thread.sleep(forTimeInterval: 0.12)
        }
    }
}

// MARK: Run the scenario

// expect: +1 brighter, -1 dimmer, 0 none. before/after: scale positions.
struct Event { let time: Double; let label: String; let expect: Int; var before = 0.0; var after = 0.0 }
var events: [Event] = []
var exitCode: Int32 = 0

func restore() {
    run(cli, ["set", String(format: "%.4f", initialScale)])
}
signal(SIGINT) { _ in
    run(cli, ["set", "100"])
    exit(130)
}

Thread.sleep(forTimeInterval: 1)
for step in steps(scenarioName) {
    switch step {
    case let .key(direction, fine):
        let before = (status()?["scale"] as? Double) ?? -1
        let t = now()
        let (code, text) = run(cli, ["key", direction] + (fine ? ["--fine"] : []))
        let after = (status()?["scale"] as? Double) ?? -1
        let expect = after > before + 0.01 ? 1 : (after < before - 0.01 ? -1 : 0)
        events.append(Event(time: t, label: String(format: "key %@%@ %.2f → %.2f", direction, fine ? " fine" : "", before, after),
                            expect: expect, before: before, after: after))
        if code != 0 { print("key failed: \(text)"); exitCode = 1 }
    case let .set(percent):
        events.append(Event(time: now(), label: String(format: "set %.0f", percent), expect: 0))
        run(cli, ["set", String(percent)])
    case let .wait(seconds):
        Thread.sleep(forTimeInterval: seconds)
    case let .note(text):
        events.append(Event(time: now(), label: "# " + text, expect: 0))
        print("· " + text)
    }
}
events.append(Event(time: now(), label: String(format: "restore %.2f", initialScale), expect: 0))
restore()
Thread.sleep(forTimeInterval: 2)
lock.withLock { running = false }
Thread.sleep(forTimeInterval: 0.3)

// MARK: Analyse

let all = lock.withLock { samples }
func white(at t: Double) -> Double? {
    // Median of the samples within ±30 ms, to ignore a single odd reading.
    let window = all.filter { abs($0.time - t) <= 0.03 }.compactMap(\.whiteNits).sorted()
    return window.isEmpty ? nil : window[window.count / 2]
}
func whiteBefore(_ t: Double) -> Double? { white(at: t - 0.05) }

var report = "# Brightness check (\(scenarioName), model: \(model.rawValue))\n\n"
report += "Started at scale \(String(format: "%.2f", initialScale))%. Samples every 20 ms; luminance is estimated (see BrightnessSampler.swift).\n\n"
report += "A press is ok when white moves the right way within 0.35 s (0.6 s when entering the boost from an idle display, which waits for macOS's backlight ramp), never goes the wrong way by more than 1%, and does not overshoot by more than 2%.\n\n"
report += "| t (s) | step | white before | +0.1 s | +0.3 s | +1 s | settled at | reached 90% after | result |\n|---|---|---|---|---|---|---|---|---|\n"
var keyResults: [(ok: Bool, latency: Double?)] = []
let keyEvents = events.filter { $0.label.hasPrefix("key") }
for (index, event) in events.enumerated() {
    guard event.label.hasPrefix("key") else {
        if event.label.hasPrefix("#") { report += "| \(String(format: "%.2f", event.time)) | **\(event.label.dropFirst(2))** | | | | | | | |\n" }
        continue
    }
    let next = events[(index + 1)...].first { !$0.label.hasPrefix("#") }?.time ?? (event.time + 1.5)
    let end = min(next - 0.02, event.time + 1.5)
    guard let before = whiteBefore(event.time) else { continue }
    let after = all.filter { $0.time > event.time && $0.time <= end }
    let settled = after.last?.whiteNits ?? before
    let delta = settled - before
    var reached: Double?
    if abs(delta) > 1 {
        reached = after.first { sample in
            guard let w = sample.whiteNits else { return false }
            return (w - before) / delta >= 0.9
        }.map { $0.time - event.time }
    }
    // Monotonic: never moves the wrong way by more than 1% on the way.
    let wrongWay = after.compactMap(\.whiteNits).contains { w in
        delta >= 0 ? w < before * 0.99 : w > before * 1.01
    }
    let overshoot = after.compactMap(\.whiteNits).contains { w in
        delta >= 0 ? w > settled * 1.02 + 1 : w < settled * 0.98 - 1
    }
    let directionOK = event.expect == 0 || (event.expect > 0 ? delta > 1 : delta < -1)
    // Entering the boost from an idle display waits for macOS to start ramping
    // the backlight (about 0.25 s before it moves), which no app can shorten.
    let atPress = all.last { $0.time <= event.time }
    let fromIdle = event.expect > 0 && (atPress.flatMap { s in
        s.panelNits.flatMap { p in s.standardNits.map { p <= $0 * 1.05 } }
    } ?? false) && event.before <= 100.0001 && event.after > 100.0001
    let limit = fromIdle ? 0.6 : 0.35
    let fast = reached.map { $0 <= limit } ?? (event.expect == 0)
    let ok = directionOK && !wrongWay && !overshoot && fast
    keyResults.append((ok, reached))
    func f(_ v: Double?) -> String { v.map { String(format: "%.0f", $0) } ?? "-" }
    var result = ok ? (fromIdle ? "ok (macOS EDR ramp from idle)" : "ok") : "**FAIL**"
    if wrongWay { result += " wrong way" }
    if overshoot { result += " overshoot" }
    if !directionOK { result += " no change" }
    if !fast { result += " slow" }
    let reachedText = reached.map { String(format: "%.2f s", $0) } ?? "-"
    let time = String(format: "%.2f", event.time)
    report += "| \(time) | \(event.label) | \(f(before)) | \(f(white(at: event.time + 0.1))) | \(f(white(at: event.time + 0.3))) | \(f(white(at: event.time + 1))) | \(f(settled)) | \(reachedText) | \(result) |\n"
}
let failures = keyResults.filter { !$0.ok }.count
let latencies = keyResults.compactMap(\.latency).sorted()
let maxGamma = all.compactMap(\.gamma).max() ?? 1
report += "\n**\(keyResults.count - failures)/\(keyResults.count) key presses ok.** "
if !latencies.isEmpty {
    report += String(format: "Time to 90%% of the change: median %.2f s, worst %.2f s. ", latencies[latencies.count / 2], latencies.last!)
}
report += String(format: "Highest gamma endpoint: %.3f%@.\n", maxGamma, (model == .panel && maxGamma > 1.001) ? " (above 1: clipping on this macOS)" : "")
if let last = all.last {
    report += String(format: "\nAt the end: backlight %.3f, panel %.0f nits, standard %.0f nits, gamma %.3f.\n",
                     last.backlight ?? -1, last.panelNits ?? -1, last.standardNits ?? -1, last.gamma ?? -1)
}
let frameList = lock.withLock { frames }
report += "\n\(frameList.count) frames in frames/ (file names carry their time on the same clock).\n"

// MARK: Write

let sampleText = ([BrightnessSample.header.joined(separator: "\t")] + all.map { $0.row().joined(separator: "\t") }).joined(separator: "\n") + "\n"
try sampleText.write(toFile: (outputDirectory as NSString).appendingPathComponent("samples.tsv"), atomically: true, encoding: .utf8)
let eventText = (["t\tevent"] + events.map { String(format: "%.3f\t%@", $0.time, $0.label) }).joined(separator: "\n") + "\n"
try eventText.write(toFile: (outputDirectory as NSString).appendingPathComponent("events.tsv"), atomically: true, encoding: .utf8)
try report.write(toFile: (outputDirectory as NSString).appendingPathComponent("report.md"), atomically: true, encoding: .utf8)
print(report)
exit(failures == 0 ? exitCode : 1)
