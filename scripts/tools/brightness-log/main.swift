// Free-running read-only logger. See scripts/brightness-log.sh.
import Foundation

setvbuf(stdout, nil, _IOLBF, 0)
var interval = 0.1
var duration = Double.infinity
var changesOnly = false
var model = BrightnessSampler.Model.panel
var arguments = CommandLine.arguments.dropFirst().makeIterator()
while let argument = arguments.next() {
    switch argument {
    case "--interval": interval = (Double(arguments.next() ?? "") ?? 100) / 1000
    case "--duration": duration = Double(arguments.next() ?? "") ?? .infinity
    case "--changes": changesOnly = true
    case "--once": duration = 0
    case "--model": model = BrightnessSampler.Model(rawValue: arguments.next() ?? "") ?? .panel
    default:
        FileHandle.standardError.write(Data("usage: brightness-log [--interval ms] [--duration s] [--changes] [--once] [--model panel|classic]\n".utf8))
        exit(2)
    }
}
guard let sampler = BrightnessSampler(model: model) else { print("no built-in display"); exit(1) }
print(BrightnessSample.header.joined(separator: "\t"))
let start = Date()
var last: [String]?
while true {
    let elapsed = Date().timeIntervalSince(start)
    let row = sampler.sample(at: elapsed).row()
    let values = Array(row.dropFirst())
    if !changesOnly || values != last {
        print(row.joined(separator: "\t"))
        last = values
    }
    if elapsed >= duration { break }
    Thread.sleep(forTimeInterval: interval)
}
