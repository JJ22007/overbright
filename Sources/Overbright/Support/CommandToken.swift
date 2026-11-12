import Foundation
import Darwin

/// A secret the app writes when it starts and the `overbright` command sends
/// with every request. Distributed notifications reach every process in the
/// login session, sandboxed apps included; the token, readable only by this
/// user and outside any sandbox container, keeps those from driving the boost.
enum CommandToken {
    private static var file: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent(AppInfo.name, isDirectory: true)
            .appendingPathComponent("command-token")
    }

    /// A new token for this run of the app, written with mode 0600.
    static func create() -> String? {
        guard let file else { return nil }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { return nil }
        let token = bytes.map { String(format: "%02x", $0) }.joined()
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: file)
        let descriptor = Darwin.open(file.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, mode_t(S_IRUSR | S_IWUSR))
        guard descriptor >= 0 else { return nil }
        defer { Darwin.close(descriptor) }
        let data = Array(token.utf8)
        guard Darwin.write(descriptor, data, data.count) == data.count else { return nil }
        return token
    }

    /// The running app's token, for the command line.
    static func read() -> String? {
        guard let file, let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        let token = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return token.isEmpty ? nil : token
    }

    /// Compares without stopping at the first difference.
    static func matches(_ given: String?, _ expected: String) -> Bool {
        guard let given else { return false }
        let a = Array(given.utf8), b = Array(expected.utf8)
        guard a.count == b.count else { return false }
        return zip(a, b).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }
}
