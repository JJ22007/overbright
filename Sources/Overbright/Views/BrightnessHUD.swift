import AppKit

/// The brightness indicator shown on an external display while it changes.
///
/// macOS draws its own indicator only for displays it controls itself, so a
/// DDC or software change would otherwise give no feedback until the screen
/// itself changes. This one sits where the system's does on recent macOS:
/// top right, just under the menu bar.
@MainActor
final class BrightnessHUD {
    private static let size = NSSize(width: 288, height: 64)
    private static let margin: CGFloat = 10

    private let panel: NSPanel
    private let icon = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let valueLabel = NSTextField(labelWithString: "")
    private let bar = LevelBar()
    private var hideWork: DispatchWorkItem?
    private var shownOn: CGDirectDisplayID?

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

        let content = NSView(frame: NSRect(origin: .zero, size: Self.size))
        panel.contentView = Self.makeBackground(containing: content)

        icon.symbolConfiguration = .init(pointSize: 17, weight: .semibold)
        icon.contentTintColor = .labelColor
        icon.frame = NSRect(x: 18, y: 20, width: 24, height: 24)
        content.addSubview(icon)

        nameLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        nameLabel.textColor = .labelColor
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.frame = NSRect(x: 54, y: 33, width: 160, height: 16)
        content.addSubview(nameLabel)

        valueLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        valueLabel.textColor = .secondaryLabelColor
        valueLabel.alignment = .right
        valueLabel.frame = NSRect(x: 214, y: 33, width: 56, height: 16)
        content.addSubview(valueLabel)

        bar.frame = NSRect(x: 54, y: 16, width: 216, height: 8)
        content.addSubview(bar)
    }

    /// Liquid Glass where the system has it, the HUD material elsewhere.
    private static func makeBackground(containing content: NSView) -> NSView {
        let radius = size.height / 2
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView(frame: NSRect(origin: .zero, size: size))
            glass.cornerRadius = radius
            glass.contentView = content
            return glass
        }
        let effect = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = radius
        effect.layer?.cornerCurve = .continuous
        effect.layer?.masksToBounds = true
        effect.addSubview(content)
        return effect
    }

    func show(_ display: ExternalDisplay) {
        guard let screen = ExternalDisplayManager.screen(for: display.id) else { return }
        let symbol: String
        switch display.level {
        case ..<0: symbol = "moon.fill"
        case ..<34: symbol = "sun.min.fill"
        default: symbol = "sun.max.fill"
        }
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        nameLabel.stringValue = display.name
        valueLabel.stringValue = ExternalBrightness.label(display.level)

        let alreadyVisible = panel.isVisible && panel.alphaValue > 0.5 && shownOn == display.id
        bar.set(level: display.level, minimum: display.minimum, animated: alreadyVisible)

        let target = Self.frame(on: screen)
        if !alreadyVisible {
            shownOn = display.id
            panel.setFrame(target.offsetBy(dx: 0, dy: 8), display: false)
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.22
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().alphaValue = 1
                panel.animator().setFrame(target, display: true)
            }
        }

        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.hide() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6, execute: work)
    }

    private func hide() {
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.3
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated {
                if self.panel.alphaValue < 0.01 {
                    self.panel.orderOut(nil)
                    self.shownOn = nil
                }
            }
        })
    }

    /// Top right of the screen, just under the menu bar.
    private static func frame(on screen: NSScreen) -> NSRect {
        let visible = screen.visibleFrame
        return NSRect(
            x: visible.maxX - size.width - margin,
            y: visible.maxY - size.height - margin,
            width: size.width,
            height: size.height
        )
    }
}

/// A rounded level bar. With extra dimming the range starts below zero; while
/// the level is below zero, a small mark shows where 0% is.
private final class LevelBar: NSView {
    private let track = CALayer()
    private let fill = CALayer()
    private let zeroMark = CALayer()
    private var fraction: CGFloat = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(track)
        track.addSublayer(fill)
        track.addSublayer(zeroMark)
        track.masksToBounds = true
        zeroMark.isHidden = true
    }

    required init?(coder: NSCoder) { nil }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        let height = bounds.height
        track.frame = bounds
        track.cornerRadius = height / 2
        track.backgroundColor = NSColor.labelColor.withAlphaComponent(0.14).cgColor
        fill.cornerRadius = height / 2
        fill.backgroundColor = NSColor.labelColor.cgColor
        zeroMark.backgroundColor = NSColor.secondaryLabelColor.cgColor
        layoutFill()
    }

    func set(level: Double, minimum: Double, animated: Bool) {
        let span = max(100 - minimum, 1)
        fraction = CGFloat(min(max((level - minimum) / span, 0), 1))
        let zero = CGFloat(-minimum / span)
        // Only inside the extra-dimming range, where it tells you how far below
        // the backlight's minimum you are. Above 0% it would just be a stray line.
        zeroMark.isHidden = minimum >= 0 || level >= 0
        zeroMark.frame = NSRect(x: bounds.width * zero - 1, y: 0, width: 2, height: bounds.height)

        CATransaction.begin()
        CATransaction.setAnimationDuration(animated ? 0.16 : 0)
        CATransaction.setDisableActions(!animated)
        layoutFill()
        CATransaction.commit()
        needsDisplay = true
    }

    private func layoutFill() {
        // Never thinner than the bar is tall, so a low level still reads as a dot.
        let width = fraction > 0 ? max(bounds.width * fraction, bounds.height) : 0
        fill.frame = NSRect(x: 0, y: 0, width: width, height: bounds.height)
    }
}
