import AppKit

/// A small brightness indicator shown on the display being adjusted.
///
/// macOS draws its own indicator only for displays it controls itself, so a
/// DDC or software change would otherwise give no feedback until the screen
/// itself changes.
@MainActor
final class BrightnessHUD {
    private let panel: NSPanel
    private let icon = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let valueLabel = NSTextField(labelWithString: "")
    private let track = NSView()
    private let fill = NSView()
    private var hideWork: DispatchWorkItem?

    private static let size = NSSize(width: 240, height: 76)

    init() {
        panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.alphaValue = 0

        let background = NSVisualEffectView(frame: NSRect(origin: .zero, size: Self.size))
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 16
        background.layer?.masksToBounds = true
        panel.contentView = background

        icon.image = NSImage(systemSymbolName: "sun.max.fill", accessibilityDescription: nil)
        icon.contentTintColor = .labelColor
        icon.frame = NSRect(x: 16, y: 38, width: 20, height: 20)
        background.addSubview(icon)

        nameLabel.font = .systemFont(ofSize: 12, weight: .medium)
        nameLabel.textColor = .secondaryLabelColor
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.frame = NSRect(x: 44, y: 39, width: 130, height: 16)
        background.addSubview(nameLabel)

        valueLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        valueLabel.alignment = .right
        valueLabel.frame = NSRect(x: 176, y: 39, width: 48, height: 16)
        background.addSubview(valueLabel)

        track.wantsLayer = true
        track.layer?.cornerRadius = 3
        track.layer?.backgroundColor = NSColor.tertiaryLabelColor.cgColor
        track.frame = NSRect(x: 16, y: 18, width: 208, height: 6)
        background.addSubview(track)

        fill.wantsLayer = true
        fill.layer?.cornerRadius = 3
        fill.layer?.backgroundColor = NSColor.labelColor.cgColor
        track.addSubview(fill)
    }

    func show(_ display: ExternalDisplay) {
        guard let screen = ExternalDisplayManager.screen(for: display.id) else { return }
        nameLabel.stringValue = display.name
        valueLabel.stringValue = ExternalBrightness.label(display.level)
        let span = max(100 - display.minimum, 1)
        let fraction = min(max((display.level - display.minimum) / span, 0), 1)
        fill.frame = NSRect(x: 0, y: 0, width: track.bounds.width * fraction, height: track.bounds.height)
        icon.image = NSImage(
            systemSymbolName: display.level < 34 ? "sun.min.fill" : "sun.max.fill",
            accessibilityDescription: nil
        )

        let visible = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(
            x: visible.midX - Self.size.width / 2,
            y: visible.minY + 80
        ))
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            panel.animator().alphaValue = 1
        }

        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.35
                self.panel.animator().alphaValue = 0
            }, completionHandler: {
                MainActor.assumeIsolated {
                    if self.panel.alphaValue == 0 { self.panel.orderOut(nil) }
                }
            })
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: work)
    }
}
