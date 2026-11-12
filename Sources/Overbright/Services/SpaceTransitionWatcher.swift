import AppKit
import os

/// Tells when macOS is about to draw a Spaces or Mission Control transition.
///
/// Those transitions draw the boost layer without its multiply, so it shows as
/// a white sheet over the whole screen (seen by the user on macOS 27.2: Mission
/// Control, and trackpad swipes between Spaces, white and flickering; Control+
/// arrow switches stayed fine once the layer moved to the shielding level).
/// The overlay hides while this reports a transition.
///
/// - Trackpad swipes: the Dock's swipe gestures arrive as `kCGSEventDockControl`
///   events (type 30) at the HID tap, before the animation starts. The tap
///   hides the layer before passing them on unchanged.
/// - Mission Control, however it is opened (gesture, key, hot corner): the
///   window manager puts up full-screen windows above the desktop
///   ("ExposeShieldWindow", layer 19). Window names need the Screen Recording
///   permission, so the check uses the owner and layer, which do not.
@MainActor
final class SpaceTransitionWatcher {
    /// Called with true when a transition starts and false once it is over.
    var onChange: ((Bool) -> Void)?
    private(set) var isTransitioning = false
    /// Diagnostics for `status --json`: events seen per type, and how often
    /// the layer was hidden.
    private(set) var eventCounts: [UInt32: Int] = [:]
    private(set) var hideCount = 0
    private(set) var tapRunning = false

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var pollTimer: Timer?
    private var lastGestureAt: TimeInterval = 0
    private var missionControlOpen = false
    private let logger = Logger(subsystem: AppInfo.bundleID, category: "Spaces")

    /// How long after the last swipe event a transition counts as over: the
    /// Space slide and the bounce at the first or last Space take about this.
    /// 0.8 s still let the layer back while a swipe's slide or bounce was
    /// running (white on about 70% of swipes to the first or last Space).
    private static let settleTime: TimeInterval = 1.5
    static let dockControlType: UInt32 = 30
    static let gestureType: UInt32 = 29

    func start() {
        guard pollTimer == nil else { return }
        startTap()
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CFMachPortInvalidate(tap) }
        source = nil
        tap = nil
        missionControlOpen = false
        update()
    }

    private func startTap() {
        guard tap == nil else { return }
        let mask = (CGEventMask(1) << CGEventMask(Self.dockControlType))
            | (CGEventMask(1) << CGEventMask(Self.gestureType))
            | (CGEventMask(1) << CGEventMask(CGEventType.keyDown.rawValue))
        let callback: CGEventTapCallBack = { _, type, event, context in
            if let context {
                let watcher = Unmanaged<SpaceTransitionWatcher>.fromOpaque(context).takeUnretainedValue()
                let raw = type.rawValue
                MainActor.assumeIsolated { watcher.received(type: raw, event: event) }
            }
            return Unmanaged.passUnretained(event)
        }
        guard let newTap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            // An active tap (the event is passed on unchanged): macOS waits for
            // this callback, so the layer is gone before the Dock sees the
            // gesture or key and starts its animation. A listen-only tap raced
            // the Dock and lost on some swipes.
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ), let newSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, newTap, 0) else {
            logger.notice("no gesture tap (Accessibility not granted?)")
            return
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), newSource, .commonModes)
        CGEvent.tapEnable(tap: newTap, enable: true)
        tap = newTap
        source = newSource
        tapRunning = CGEvent.tapIsEnabled(tap: newTap)
    }

    private func received(type: UInt32, event: CGEvent) {
        if type == CGEventType.tapDisabledByTimeout.rawValue || type == CGEventType.tapDisabledByUserInput.rawValue {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }
        eventCounts[type, default: 0] += 1
        if UserDefaults.standard.bool(forKey: "debugGestureLog") {
            let kind = event.getIntegerValueField(CGEventField(rawValue: 110)!)
            let phase = event.getIntegerValueField(CGEventField(rawValue: 132)!)
            logger.notice("gesture event type \(type, privacy: .public) kind \(kind, privacy: .public) phase \(phase, privacy: .public)")
        }
        if type == CGEventType.keyDown.rawValue {
            guard Self.startsTransition(event) else { return }
        } else if type != Self.dockControlType {
            return
        }
        lastGestureAt = ProcessInfo.processInfo.systemUptime
        update()
        // Push the hide to the window server before the event moves on.
        CATransaction.flush()
    }

    private func poll() {
        missionControlOpen = Self.missionControlIsOpen()
        update()
    }

    private func update() {
        let swiping = ProcessInfo.processInfo.systemUptime - lastGestureAt < Self.settleTime
        let now = swiping || missionControlOpen
        guard now != isTransitioning else { return }
        isTransitioning = now
        if now { hideCount += 1 }
        onChange?(now)
    }

    /// Keys that switch Spaces or open Mission Control: Control or Option
    /// with an arrow key (the Spaces shortcuts, as the user has them), and the
    /// Mission Control key.
    static func startsTransition(_ event: CGEvent) -> Bool {
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags
        let arrows: Set<Int64> = [123, 124, 125, 126]
        if arrows.contains(code), flags.contains(.maskControl) || flags.contains(.maskAlternate) {
            return true
        }
        return code == 160 // Mission Control (F3)
    }

    static func missionControlIsOpen() -> Bool {
        guard let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return false }
        return windows.contains { window in
            guard (window[kCGWindowOwnerName as String] as? String) == "WindowManager",
                  let layer = window[kCGWindowLayer as String] as? Int, (1...100).contains(layer),
                  let bounds = window[kCGWindowBounds as String] as? [String: Any],
                  let width = (bounds["Width"] as? NSNumber)?.doubleValue else { return false }
            return width >= 800
        }
    }
}
