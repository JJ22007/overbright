import Foundation

/// Names that change when you fork and rename the app. Keep them in one place.
enum AppInfo {
    static let name = "Overbright"
    static let bundleID = "io.github.overbright"
    static let repoURL = "https://github.com/JJ22007/overbright"
    /// Name of the distributed notification the CLI uses to reach the app.
    static let commandChannel = "io.github.overbright.command"

    static var version: String {
        let key = "CFBundleShortVersionString"
        if let version = Bundle.main.object(forInfoDictionaryKey: key) as? String {
            return version
        }
        // Run through the ~/.local/bin symlink, the bundle is not found by
        // itself: follow the link back to Overbright.app/Contents/Info.plist.
        if let executable = Bundle.main.executableURL?.resolvingSymlinksInPath(),
           let info = NSDictionary(contentsOf: executable
               .deletingLastPathComponent()
               .deletingLastPathComponent()
               .appendingPathComponent("Info.plist")),
           let version = info[key] as? String {
            return version
        }
        return "dev"
    }
}
