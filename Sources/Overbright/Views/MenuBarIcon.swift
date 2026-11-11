import AppKit

/// Menu bar glyphs from Lucide (https://lucide.dev, ISC licence, see LICENSES/lucide.txt).
/// Drawn as template images so macOS tints them for light and dark menu bars and the
/// highlighted state. Boost on: `sun`. Standard brightness: `sun-dim`. Problem: `triangle-alert`.
enum MenuBarIcon {
    static let on = make("""
    <circle cx="12" cy="12" r="4"/><path d="M12 2v2"/><path d="M12 20v2"/><path d="m4.93 4.93 1.41 1.41"/><path d="m17.66 17.66 1.41 1.41"/><path d="M2 12h2"/><path d="M20 12h2"/><path d="m6.34 17.66-1.41 1.41"/><path d="m19.07 4.93-1.41 1.41"/>
    """)
    static let off = make("""
    <circle cx="12" cy="12" r="4"/><path d="M12 4h.01"/><path d="M20 12h.01"/><path d="M12 20h.01"/><path d="M4 12h.01"/><path d="M17.657 6.343h.01"/><path d="M17.657 17.657h.01"/><path d="M6.343 17.657h.01"/><path d="M6.343 6.343h.01"/>
    """)
    static let problem = make("""
    <path d="m21.73 18-8-14a2 2 0 0 0-3.48 0l-8 14A2 2 0 0 0 4 21h16a2 2 0 0 0 1.73-3"/><path d="M12 9v4"/><path d="M12 17h.01"/>
    """)

    private static func make(_ body: String, size: CGFloat = 18) -> NSImage {
        let svg = """
        <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" \
        stroke="black" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round">\(body)</svg>
        """
        let image = NSImage(data: Data(svg.utf8)) ?? NSImage()
        image.size = NSSize(width: size, height: size)
        image.isTemplate = true
        image.accessibilityDescription = AppInfo.name
        return image
    }
}
