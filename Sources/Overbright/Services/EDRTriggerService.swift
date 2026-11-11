import AppKit
import MetalKit

private final class EDRTriggerView: MTKView, MTKViewDelegate {
    private let commandQueue: MTLCommandQueue

    init?(metalDevice: MTLDevice?) {
        guard let metalDevice,
              let commandQueue = metalDevice.makeCommandQueue() else {
            return nil
        }
        self.commandQueue = commandQueue
        super.init(
            frame: NSRect(x: 0, y: 0, width: 1, height: 1),
            device: metalDevice
        )

        delegate = self
        colorPixelFormat = .rgba16Float
        colorspace = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)
        clearColor = MTLClearColorMake(1, 1, 1, 1)
        autoResizeDrawable = false
        drawableSize = CGSize(width: 1, height: 1)
        preferredFramesPerSecond = 5
        framebufferOnly = true

        if let metalLayer = layer as? CAMetalLayer {
            metalLayer.wantsExtendedDynamicRangeContent = true
            metalLayer.isOpaque = false
        }
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setEnabled(_ enabled: Bool) {
        isPaused = !enabled
        (layer as? CAMetalLayer)?.wantsExtendedDynamicRangeContent = enabled
        if enabled { draw() }
    }

    func draw(in view: MTKView) {
        guard let descriptor = currentRenderPassDescriptor,
              let buffer = commandQueue.makeCommandBuffer(),
              let encoder = buffer.makeRenderCommandEncoder(descriptor: descriptor),
              let drawable = currentDrawable else {
            return
        }

        encoder.endEncoding()
        buffer.present(drawable)
        buffer.commit()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
}

@MainActor
final class EDRTriggerService {
    private var window: NSWindow?
    private weak var triggerView: EDRTriggerView?

    func start(on screen: NSScreen) -> Bool {
        stop()
        guard let triggerView = EDRTriggerView(
            metalDevice: MTLCreateSystemDefaultDevice()
        ) else { return false }

        let origin = CGPoint(x: screen.frame.minX, y: screen.frame.maxY - 1)
        let window = NSWindow(
            contentRect: NSRect(origin: origin, size: CGSize(width: 1, height: 1)),
            styleMask: .borderless,
            backing: .buffered,
            defer: false,
            screen: screen
        )
        window.level = .screenSaver
        window.collectionBehavior = [
            .stationary,
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .ignoresCycle
        ]
        window.animationBehavior = .none
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.hidesOnDeactivate = false
        window.isReleasedWhenClosed = false
        window.contentView = triggerView
        window.orderFrontRegardless()

        triggerView.setEnabled(true)
        self.triggerView = triggerView
        self.window = window
        return true
    }

    func stop() {
        triggerView?.setEnabled(false)
        window?.orderOut(nil)
        window?.close()
        triggerView = nil
        window = nil
    }
}
