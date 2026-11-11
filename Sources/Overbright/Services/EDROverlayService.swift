import AppKit
import MetalKit

/// A full-screen EDR layer that multiplies everything under it by one value.
/// Above 1.0 it lifts ordinary content into the EDR headroom; at 1.0 it leaves
/// the picture exactly as it was. This is the boost on macOS 27.2 and later,
/// where the gamma table no longer changes the light the panel emits (measured
/// with a camera; see AGENTS.md, "Measuring brightness").
private final class MultiplyView: MTKView, MTKViewDelegate {
    private let commandQueue: MTLCommandQueue

    init?(size: NSSize) {
        let frame = NSRect(origin: .zero, size: size)
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else { return nil }
        self.commandQueue = commandQueue
        super.init(frame: frame, device: device)
        delegate = self
        colorPixelFormat = .rgba16Float
        // Linear, so the multiply scales light, not encoded values.
        colorspace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)
        clearColor = MTLClearColorMake(1, 1, 1, 1)
        // One colour everywhere: a tiny drawable stretched over the screen.
        autoResizeDrawable = false
        drawableSize = CGSize(width: 16, height: 16)
        framebufferOnly = true
        // Keep redrawing. A layer that is drawn once and left alone is, after
        // about a second, shown as an opaque white sheet without the multiply
        // (seen with a camera on a black screen). MTKView's own display link
        // stops when macOS naps a background app or decides the window is not
        // visible, so the view is paused and driven by a timer of ours instead;
        // the overlay service also keeps the app out of App Nap.
        isPaused = true
        enableSetNeedsDisplay = false
        if let metalLayer = layer as? CAMetalLayer {
            metalLayer.wantsExtendedDynamicRangeContent = true
            metalLayer.isOpaque = false
            metalLayer.contentsGravity = .resize
            metalLayer.compositingFilter = "multiplyBlendMode"
        }
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private var timer: Timer?
    private var burstFrames = 0
    private var lastDrawAt: TimeInterval?

    /// The longest time between two redraws since the layer was shown. Above
    /// about a second the layer turns into an opaque sheet; `status --json`
    /// reports it as `overlayMaxFrameGap`.
    private(set) var maxFrameGap: TimeInterval = 0

    /// Draws `multiplier` now and keeps redrawing at 120 frames a second for
    /// half a second: a change reaches the screen in about 0.15 s that way,
    /// against 0.4 s at the idle 4 frames a second (measured).
    func show(_ multiplier: Double) {
        clearColor = MTLClearColorMake(multiplier, multiplier, multiplier, 1)
        burstFrames = 60
        schedule(interval: 1.0 / 120.0)
        draw()
    }

    private func schedule(interval: TimeInterval) {
        if let timer, timer.isValid, timer.timeInterval == interval { return }
        timer?.invalidate()
        let next = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        next.tolerance = interval / 10
        RunLoop.main.add(next, forMode: .common)
        timer = next
    }

    private func tick() {
        if burstFrames > 0 {
            burstFrames -= 1
            if burstFrames == 0 { schedule(interval: 0.25) }
        }
        draw()
    }

    func stopDrawing() {
        timer?.invalidate()
        timer = nil
    }

    func draw(in view: MTKView) {
        guard let descriptor = currentRenderPassDescriptor,
              let buffer = commandQueue.makeCommandBuffer(),
              let encoder = buffer.makeRenderCommandEncoder(descriptor: descriptor),
              let drawable = currentDrawable else { return }
        encoder.endEncoding()
        buffer.present(drawable)
        // Measured where a frame reaches the screen, not where one was asked
        // for: a draw without a drawable shows nothing.
        drawable.addPresentedHandler { [weak self] presented in
            let at = presented.presentedTime
            guard at > 0 else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.framePresented(at: at) }
            }
        }
        buffer.commit()
    }

    private func framePresented(at time: CFTimeInterval) {
        if let lastDrawAt, time > lastDrawAt { maxFrameGap = max(maxFrameGap, time - lastDrawAt) }
        lastDrawAt = max(lastDrawAt ?? 0, time)
    }

    /// Time since the last frame reached the screen.
    var sinceLastFrame: TimeInterval {
        lastDrawAt.map { CACurrentMediaTime() - $0 } ?? 0
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
}

@MainActor
final class EDROverlayService {
    private var window: NSWindow?
    private var view: MultiplyView?
    private(set) var multiplier: Float = 1

    var isShowing: Bool { window?.isVisible ?? false }

    /// Longest gap between redraws while showing (see `MultiplyView.maxFrameGap`).
    var maxFrameGap: TimeInterval { view?.maxFrameGap ?? 0 }

    /// Keeps macOS from napping the app while the layer is up: a napped app's
    /// timers stall, and a layer that is not redrawn turns white.
    private var activity: NSObjectProtocol?

    func start(on screen: NSScreen) -> Bool {
        stop()
        guard let view = MultiplyView(size: screen.frame.size) else { return false }
        let window = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false, screen: screen)
        window.level = .screenSaver
        window.collectionBehavior = [.stationary, .canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        window.animationBehavior = .none
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.hidesOnDeactivate = false
        window.isReleasedWhenClosed = false
        // Screenshots and recordings show the picture as apps drew it.
        window.sharingType = UserDefaults.standard.bool(forKey: "debugCapturableOverlay") ? .readOnly : .none
        window.contentView = view
        window.setFrame(screen.frame, display: false)
        window.orderFrontRegardless()
        self.window = window
        self.view = view
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
            reason: "Overbright boost layer must keep redrawing"
        )
        level = 1
        startTracking()
        render()
        return true
    }

    /// Keeps the layer covering the screen after a resolution or arrangement change.
    func follow(_ screen: NSScreen) {
        guard let window, window.frame != screen.frame else { return }
        window.setFrame(screen.frame, display: false)
        view?.show(Double(multiplier))
    }

    private let panelLight = PanelLightService()

    /// The screen's EDR headroom, reported once the backlight has settled at
    /// its peak (and again if it changes), for `PanelCeiling`.
    var onHeadroom: ((Double) -> Void)?
    private var reportedHeadroom: Double?
    private var trackingTimer: Timer?
    private var peakReachedAt: TimeInterval?
    private(set) var correction: Double = 1

    /// The boost level the layer is showing, 1.0-1.6.
    private(set) var level: Float = 1

    /// Shows a boost level: multiplies everything under the layer by
    /// `level × EDRWhiteCorrection`, so a level is relative to the real
    /// standard brightness (106% is 6% above it, not 3% below).
    @discardableResult
    func show(level proposed: Float) -> Bool {
        guard view != nil, proposed.isFinite else { return false }
        level = min(max(proposed, 1), BoostLevel.maximum)
        render()
        return true
    }

    private func render() {
        multiplier = level * Float(correction)
        view?.show(Double(multiplier))
    }

    /// Follows the backlight at 60 Hz until the correction is complete, then
    /// at 4 Hz in case the backlight leaves its peak (another display mode,
    /// a thermal limit).
    private func startTracking() {
        trackingTimer?.invalidate()
        peakReachedAt = nil
        correction = 1
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.track() }
        }
        RunLoop.main.add(timer, forMode: .common)
        trackingTimer = timer
    }

    private var slowTicks = 0
    private func track() {
        if correction >= EDRWhiteCorrection.full {
            slowTicks += 1
            if slowTicks % 15 != 0 { return }
        }
        let now = ProcessInfo.processInfo.systemUptime
        let atPeak = panelLight.panelNits.map {
            EDRWhiteCorrection.isAtPeak(panelNits: $0, peakNits: panelLight.peakNits)
        } ?? true
        if atPeak {
            if peakReachedAt == nil { peakReachedAt = now }
        } else {
            peakReachedAt = nil
        }
        let next = EDRWhiteCorrection.value(sincePeak: peakReachedAt.map { now - $0 })
        if atPeak, next >= EDRWhiteCorrection.full,
           let headroom = window?.screen?.maximumExtendedDynamicRangeColorComponentValue,
           abs(headroom - (reportedHeadroom ?? 0)) > 0.005 {
            reportedHeadroom = headroom
            onHeadroom?(Double(headroom))
        }
        if abs(next - correction) > 0.0005 {
            correction = next
            render()
        }
    }

    func stop() {
        trackingTimer?.invalidate()
        trackingTimer = nil
        peakReachedAt = nil
        reportedHeadroom = nil
        correction = 1
        view?.stopDrawing()
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
        window?.orderOut(nil)
        window?.close()
        window = nil
        view = nil
        level = 1
        multiplier = 1
    }
}
