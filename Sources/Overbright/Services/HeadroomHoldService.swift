import AppKit
import MetalKit

/// One transparent pixel that asks macOS for a fixed HDR headroom
/// (`DirectPanel.heldHeadroom`, the headroom of a system banner).
///
/// macOS ramps the backlight for two seconds each time the headroom on screen
/// changes, and the direct boost is not on the panel during a ramp
/// (`DirectPacer`). With this pixel on screen, a banner appearing or leaving
/// changes nothing, so there is no ramp. Measured on a 14" MacBook Pro,
/// macOS 27.2.1: with the pixel held, two banner-sized HDR appearances made no
/// change to the backlight at all; held for 95 s at 166% the backlight's power
/// was 10.9 W against 10.6 W without it, steady.
///
/// The pixel is fully transparent and takes no clicks. It is only on screen
/// while the direct boost is on.
@MainActor
final class HeadroomHoldService {
    private final class HoldView: MTKView, MTKViewDelegate {
        private let commandQueue: MTLCommandQueue

        init?(metalDevice: MTLDevice?, headroom: Double) {
            guard let metalDevice, let commandQueue = metalDevice.makeCommandQueue() else { return nil }
            self.commandQueue = commandQueue
            super.init(frame: NSRect(x: 0, y: 0, width: 1, height: 1), device: metalDevice)
            // Without a stated headroom macOS opens the whole range, up to the
            // panel's peak: then nothing is held, so there is no view.
            guard let metalLayer = layer as? CAMetalLayer,
                  metalLayer.responds(to: NSSelectorFromString("setContentsHeadroom:")) else { return nil }
            delegate = self
            colorPixelFormat = .rgba16Float
            colorspace = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)
            clearColor = MTLClearColorMake(0, 0, 0, 0)
            autoResizeDrawable = false
            drawableSize = CGSize(width: 1, height: 1)
            preferredFramesPerSecond = 10
            metalLayer.isOpaque = false
            metalLayer.wantsExtendedDynamicRangeContent = true
            metalLayer.setValue(headroom, forKey: "contentsHeadroom")
        }

        required init(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        func draw(in view: MTKView) {
            guard let descriptor = currentRenderPassDescriptor,
                  let buffer = commandQueue.makeCommandBuffer(),
                  let encoder = buffer.makeRenderCommandEncoder(descriptor: descriptor),
                  let drawable = currentDrawable else { return }
            encoder.endEncoding()
            buffer.present(drawable)
            buffer.commit()
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
    }

    private var window: NSWindow?

    var isOpen: Bool { window != nil }

    @discardableResult
    func open(on screen: NSScreen) -> Bool {
        guard window == nil else { return true }
        guard let view = HoldView(metalDevice: MTLCreateSystemDefaultDevice(),
                                  headroom: DirectPanel.heldHeadroom) else { return false }
        let origin = CGPoint(x: screen.frame.minX, y: screen.frame.maxY - 1)
        let window = NSWindow(
            contentRect: NSRect(origin: origin, size: CGSize(width: 1, height: 1)),
            styleMask: .borderless, backing: .buffered, defer: false, screen: screen
        )
        window.level = .screenSaver
        window.collectionBehavior = [.stationary, .canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        window.animationBehavior = .none
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.hidesOnDeactivate = false
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.orderFrontRegardless()
        self.window = window
        return true
    }

    func close() {
        guard let window else { return }
        (window.contentView as? MTKView)?.isPaused = true
        window.orderOut(nil)
        window.close()
        self.window = nil
    }
}
