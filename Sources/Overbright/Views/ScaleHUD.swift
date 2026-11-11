import AppKit

/// The one brightness indicator for the built-in display, covering the whole
/// 0–160% scale. It takes the place of macOS's own indicator whenever
/// Overbright handles F1/F2, so there is never a second one.
///
/// Styled after the macOS 27.2 volume indicator: a glass capsule at the top
/// centre of the screen with a sun, a bar of 16 thin, evenly spaced dashes and
/// the percentage. The bar spans 0% to the top of the scale, which follows the
/// panel (`BoostLevel.cap`), so each dash is 1/16 of whatever this Mac can do.
@MainActor
final class ScaleHUD {
    private static let size = NSSize(width: 300, height: 60)
    private static let topMargin: CGFloat = 10

    private let panel: NSPanel
    private let icon = NSImageView()
    private let segments = SegmentBar()
    private let valueLabel = NSTextField(labelWithString: "")
    private var hideWork: DispatchWorkItem?

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

        icon.symbolConfiguration = .init(pointSize: 20, weight: .medium)
        icon.contentTintColor = .labelColor
        icon.imageAlignment = .alignCenter
        icon.frame = NSRect(x: 18, y: 16, width: 30, height: 28)
        content.addSubview(icon)

        segments.frame = NSRect(x: 58, y: 28, width: 178, height: 4)
        content.addSubview(segments)

        valueLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        valueLabel.textColor = .secondaryLabelColor
        valueLabel.alignment = .right
        valueLabel.frame = NSRect(x: 238, y: 21, width: 44, height: 18)
        content.addSubview(valueLabel)
    }

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

    /// Shows `percent` on a scale from 0 to `top` (160, or 100 on a display
    /// that cannot boost) on the built-in screen.
    func show(percent: Double, top: Double) {
        guard let screen = DisplayLookup.builtInScreen else { return }
        let symbol = percent < 50 ? "sun.min.fill" : "sun.max.fill"
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        valueLabel.stringValue = "\(Int(percent.rounded()))%"
        segments.set(fills: BuiltInBrightnessScale.segmentFills(percent: percent, top: top))

        let visible = screen.visibleFrame
        let target = NSRect(
            x: visible.midX - Self.size.width / 2,
            y: visible.maxY - Self.size.height - Self.topMargin,
            width: Self.size.width,
            height: Self.size.height
        )
        if !panel.isVisible || panel.alphaValue < 0.5 {
            panel.setFrame(target.offsetBy(dx: 0, dy: 6), display: false)
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().alphaValue = 1
                panel.animator().setFrame(target, display: true)
            }
        } else if panel.frame != target {
            panel.setFrame(target, display: true)
        }

        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.hide() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    private func hide() {
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.3
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated {
                if self.panel.alphaValue < 0.01 { self.panel.orderOut(nil) }
            }
        })
    }
}

/// Sixteen thin, evenly spaced dashes, each filled 0...1.
private final class SegmentBar: NSView {
    private var tracks: [CALayer] = []
    private var fills: [CALayer] = []
    private var values: [Double] = Array(repeating: 0, count: BuiltInBrightnessScale.segmentCount)

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        for _ in 0..<BuiltInBrightnessScale.segmentCount {
            let track = CALayer()
            let fill = CALayer()
            track.masksToBounds = true
            track.addSublayer(fill)
            layer?.addSublayer(track)
            tracks.append(track)
            fills.append(fill)
        }
    }

    required init?(coder: NSCoder) { nil }

    override var wantsUpdateLayer: Bool { true }

    func set(fills newValues: [Double]) {
        values = newValues
        needsDisplay = true
    }

    override func updateLayer() {
        let count = CGFloat(tracks.count)
        let gap: CGFloat = 3
        let width = (bounds.width - gap * (count - 1)) / count
        var x: CGFloat = 0
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.1)
        for index in tracks.indices {
            if index > 0 { x += gap }
            let track = tracks[index]
            track.frame = NSRect(x: x, y: 0, width: width, height: bounds.height)
            track.cornerRadius = bounds.height / 2
            track.backgroundColor = NSColor.labelColor.withAlphaComponent(0.2).cgColor
            let fill = fills[index]
            fill.backgroundColor = NSColor.labelColor.cgColor
            fill.frame = NSRect(x: 0, y: 0, width: width * CGFloat(values[index]), height: bounds.height)
            x += width
        }
        CATransaction.commit()
    }
}
