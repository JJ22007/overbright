import Foundation

/// Loads `config.json`, watches it for changes, and reports problems.
/// The file is the single source of truth for settings; nothing else stores them.
@MainActor
final class ConfigStore {
    static let shared = ConfigStore()

    private(set) var config = Config()
    /// Shown in the menu. Empty when the file is fine.
    private(set) var problems: [String] = []
    var onChange: (() -> Void)?

    private var lastSignature: String?
    private var timer: Timer?

    nonisolated static var fileURL: URL {
        if let override = ProcessInfo.processInfo.environment["OVERBRIGHT_CONFIG"],
           !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/overbright/config.json")
    }

    /// Reads the file, creating it with the defaults on first run.
    func load() {
        let url = Self.fileURL
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try? Config().json.write(to: url, atomically: true, encoding: .utf8)
        }
        lastSignature = signature()

        guard let data = try? Data(contentsOf: url) else {
            problems = ["config.json could not be read; using the previous settings"]
            return
        }
        switch Config.parse(data) {
        case let .success(loaded):
            config = loaded
            problems = loaded.warnings
        case let .failure(.notJSON(detail)):
            // Keep the last good settings so a half-typed edit changes nothing.
            problems = ["config.json is not valid JSON; using the previous settings (\(detail))"]
        case .failure(.notAnObject):
            problems = ["config.json must be a JSON object; using the previous settings"]
        }
    }

    /// Reloads within a second of the file being saved.
    func startWatching() {
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.signature() != self.lastSignature else { return }
                self.load()
                self.onChange?()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func signature() -> String? {
        guard let attributes = try? FileManager.default.attributesOfItem(
            atPath: Self.fileURL.path
        ) else { return nil }
        let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
        return "\(modified)-\(size)"
    }
}
