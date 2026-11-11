import AppKit
import Metal
import QuartzCore

/// A full-screen EDR layer that multiplies everything under it by one value.
/// Above 1.0 it lifts ordinary content into the EDR headroom; at 1.0 it leaves
/// the picture exactly as it was. This is the boost on macOS 27.2 and later,
/// where the gamma table no longer changes the light the panel emits (measured
/// with a camera; see AGENTS.md, "Measuring brightness").
/// Draws one colour into a `CAMetalLayer` from a thread of its own.
///
/// The layer must keep receiving frames: one that is drawn once and left
/// alone is, after about a second, shown as an opaque white sheet without the
/// multiply (seen with a camera on a black screen). Frames used to come from a
/// main-thread timer, and in normal use the gap between frames that reached
/// the screen once grew to 2.25 s, long enough for the white sheet. Drawing
/// here does not depend on the main thread at all.
private final class MultiplyRenderer: @unchecked Sendable {
    let layer = CAMetalLayer()
    private let commandQueue: MTLCommandQueue
    private let queue = DispatchQueue(label: "io.github.overbright.overlay", qos: .userInteractive)
    private let lock = NSLock()

    // Guarded by `lock`.
    private var multiplier: Double = 1
    private var lastPresented: CFTimeInterval?
    private var maxGap: CFTimeInterval = 0

    // Used on `queue` only.
    private var timer: DispatchSourceTimer?
    private var interval: TimeInterval = 0
    private var burstFrames = 0

    init?() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else { return nil }
        self.commandQueue = commandQueue
        layer.device = device
        layer.pixelFormat = .rgba16Float
        // Linear, so the multiply scales light, not encoded values.
        layer.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)
        layer.wantsExtendedDynamicRangeContent = true
        layer.isOpaque = false
        layer.framebufferOnly = true
        // One colour everywhere: a tiny drawable stretched over the screen.
        layer.drawableSize = CGSize(width: 16, height: 16)
        layer.contentsGravity = .resize
        layer.allowsNextDrawableTimeout = true
        layer.compositingFilter = "multiplyBlendMode"
    }

    /// The longest time between two frames that reached the screen.
    var maxFrameGap: TimeInterval {
        lock.lock(); defer { lock.unlock() }
        return maxGap
    }

    /// Draws `multiplier` now and keeps redrawing at 120 frames a second for
    /// half a second: a change reaches the screen in about 0.15 s that way,
    /// against 0.4 s at the idle 4 frames a second (measured).
    func show(_ value: Double) {
        lock.lock(); multiplier = value; lock.unlock()
        queue.async {
            self.burstFrames = 60
            self.schedule(interval: 1.0 / 120.0)
            self.draw()
        }
    }

    func stop() {
        queue.sync {
            timer?.cancel()
            timer = nil
            interval = 0
        }
    }

    private func schedule(interval next: TimeInterval) {
        guard timer == nil || interval != next else { return }
        timer?.cancel()
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(
            deadline: .now() + next, repeating: next,
            leeway: .microseconds(Int(next * 100_000))
        )
        source.setEventHandler { [weak self] in self?.tick() }
        source.resume()
        timer = source
        interval = next
    }

    private func tick() {
        // For tests: lets a check see what a stalled layer looks like.
        if UserDefaults.standard.bool(forKey: "debugStopRedraw") { return }
        if burstFrames > 0 {
            burstFrames -= 1
            if burstFrames == 0 { schedule(interval: 0.25) }
        }
        draw()
    }

    private func draw() {
        lock.lock(); let value = multiplier; lock.unlock()
        guard let drawable = layer.nextDrawable(),
              let buffer = commandQueue.makeCommandBuffer() else { return }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColorMake(value, value, value, 1)
        guard let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.endEncoding()
        // Timed where a frame reaches the screen, not where one was asked for.
        drawable.addPresentedHandler { [weak self] presented in
            let at = presented.presentedTime
            guard at > 0, let self else { return }
            self.lock.lock()
            if let last = self.lastPresented, at > last { self.maxGap = max(self.maxGap, at - last) }
            self.lastPresented = max(self.lastPresented ?? 0, at)
            self.lock.unlock()
        }
        buffer.present(drawable)
        buffer.commit()
    }
}

/// Hosts the renderer's layer in a window.
private final class MultiplyView: NSView {
    let renderer: MultiplyRenderer

    init?(size: NSSize) {
        guard let renderer = MultiplyRenderer() else { return nil }
        self.renderer = renderer
        super.init(frame: NSRect(origin: .zero, size: size))
        layer = renderer.layer
        wantsLayer = true
    }

    required init?(coder: NSCoder) { nil }

    var maxFrameGap: TimeInterval { renderer.maxFrameGap }
    func show(_ multiplier: Double) { renderer.show(multiplier) }
    func stopDrawing() { renderer.stop() }
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
    private var lastTrackAt: TimeInterval?

    /// The longest the main thread went without running the 60 Hz tracking
    /// timer while the layer was up. Drawing no longer depends on it; this
    /// shows whether something blocks the app (`mainThreadMaxGap`).
    private(set) var mainThreadMaxGap: TimeInterval = 0

    private func track() {
        let tickAt = ProcessInfo.processInfo.systemUptime
        if let lastTrackAt { mainThreadMaxGap = max(mainThreadMaxGap, tickAt - lastTrackAt) }
        lastTrackAt = tickAt
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
        lastTrackAt = nil
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
