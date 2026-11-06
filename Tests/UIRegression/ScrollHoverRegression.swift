// Headless scroll/hover regression harness. Run from the project directory:
// mkdir -p .build/qa .build/module-cache
// xcrun swiftc -swift-version 5 -module-cache-path .build/module-cache \
//   Sources/MacFileManager/AppSupport.swift Tests/UIRegression/ScrollHoverRegression.swift \
//   -o .build/qa/scroll-hover-regression
// .build/qa/scroll-hover-regression
// Calls the coordinator directly; no input is posted, injected, or monitored by
// the harness and no visible window is created.
import AppKit

private struct HoverRegressionFailure: Error, CustomStringConvertible {
    let description: String
}

private final class HoverTestWindow: NSWindow {
    var reportsKey = true
    var testPointer: NSPoint?
    override var isKeyWindow: Bool { reportsKey }
    override var canBecomeKey: Bool { true }
    override var mouseLocationOutsideOfEventStream: NSPoint { testPointer ?? super.mouseLocationOutsideOfEventStream }
}

private final class HoverProbe: NSButton {
    var changes: [Bool] = []
    lazy var hover = PointerHoverState(view: self) { [weak self] value in self?.changes.append(value) }
    override var acceptsFirstResponder: Bool { true }
    override var isEnabled: Bool { didSet { if oldValue != isEnabled { hover.reset() } } }
    override func updateTrackingAreas() { super.updateTrackingAreas(); hover.updateTrackingAreas() }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { hover.reset() }
    }
}

@main
struct ScrollHoverRegression {
    private static var checks = 0
    private static let coordinator = PointerHoverCoordinator.shared

    static func main() {
        do { try run() }
        catch {
            FileHandle.standardError.write(Data("FAIL: \(error)\n".utf8))
            exit(1)
        }
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        checks += 1
        if !condition() { throw HoverRegressionFailure(description: message) }
    }

    private static func entered(at point: NSPoint, window: NSWindow) -> NSEvent {
        NSEvent.enterExitEvent(with: .mouseEntered, location: point, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil)!
    }

    private static func probe(_ frame: NSRect, in parent: NSView) -> HoverProbe {
        let view = HoverProbe(frame: frame)
        view.title = "Probe"
        parent.addSubview(view)
        view.updateTrackingAreas()
        return view
    }

    private static func run() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let window = HoverTestWindow(contentRect: NSRect(x: -10000, y: -10000, width: 440, height: 260),
            styleMask: .borderless, backing: .buffered, defer: false)
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 440, height: 260))
        window.contentView = content
        defer { window.close() }
        let first = probe(NSRect(x: 20, y: 20, width: 130, height: 30), in: content)
        let second = probe(NSRect(x: 20, y: 60, width: 130, height: 30), in: content)
        let firstPoint = NSPoint(x: 50, y: 35)
        let secondPoint = NSPoint(x: 50, y: 75)
        let outside = NSPoint(x: 420, y: 240)
        coordinator.pointerMoved(in: window, at: outside)
        coordinator.pointerMoved(in: window, at: firstPoint)
        try require(first.hover.isHovered && !second.hover.isHovered, "Genuine pointer movement must hover only the hit view")

        coordinator.scroll(in: window, at: firstPoint, phase: .began, momentumPhase: [])
        try require(!first.hover.isHovered, "Scroll begin must clear an existing hover immediately")
        first.hover.mouseEntered(with: entered(at: firstPoint, window: window))
        try require(!first.hover.isHovered, "Scroll-generated enter events must not restore hover")
        first.frame.origin.y = 60
        second.frame.origin.y = 20
        first.updateTrackingAreas(); second.updateTrackingAreas()
        coordinator.viewportChanged(in: window, at: firstPoint)
        second.hover.mouseEntered(with: entered(at: firstPoint, window: window))
        try require(!first.hover.isHovered && !second.hover.isHovered, "Rows passing under a stationary cursor must remain unhovered")
        coordinator.scroll(in: window, at: firstPoint, phase: .changed, momentumPhase: [])
        coordinator.pointerMoved(in: window, at: NSPoint(x: 55, y: 35))
        try require(!second.hover.isHovered, "Pointer movement during a finger-scroll gesture must remain suppressed")
        coordinator.scroll(in: window, at: firstPoint, phase: .ended, momentumPhase: [])
        coordinator.pointerMoved(in: window, at: firstPoint)
        second.hover.mouseEntered(with: entered(at: firstPoint, window: window))
        try require(!second.hover.isHovered, "Ending a gesture or receiving a same-position event must not restore hover")
        coordinator.pointerMoved(in: window, at: NSPoint(x: 50.2, y: 35))
        try require(!second.hover.isHovered, "Subpixel pointer jitter must not restore hover")
        coordinator.pointerMoved(in: window, at: NSPoint(x: 54, y: 35))
        try require(second.hover.isHovered && !first.hover.isHovered, "Movement after scrolling must restore the newly hit row without requiring another enter")

        let momentumPoint = NSPoint(x: 54, y: 35)
        coordinator.scroll(in: window, at: momentumPoint, phase: .began, momentumPhase: [])
        coordinator.scroll(in: window, at: momentumPoint, phase: .ended, momentumPhase: [])
        second.hover.mouseEntered(with: entered(at: momentumPoint, window: window))
        try require(!second.hover.isHovered, "The finger-up/momentum transition must not flash hover")
        coordinator.scroll(in: window, at: momentumPoint, phase: [], momentumPhase: .began)
        coordinator.scroll(in: window, at: momentumPoint, phase: [], momentumPhase: .changed)
        coordinator.pointerMoved(in: window, at: secondPoint)
        try require(!first.hover.isHovered && !second.hover.isHovered, "Momentum must suppress hover even if the pointer moves")
        coordinator.scroll(in: window, at: secondPoint, phase: [], momentumPhase: .ended)
        coordinator.pointerMoved(in: window, at: secondPoint)
        try require(!first.hover.isHovered, "Momentum end must stay idle with a stationary pointer")
        coordinator.pointerMoved(in: window, at: NSPoint(x: 54, y: 75))
        try require(first.hover.isHovered, "Real movement after momentum must restore hover")

        let current = NSPoint(x: 54, y: 75)
        coordinator.scroll(in: window, at: current, phase: [], momentumPhase: [])
        coordinator.pointerMoved(in: window, at: current)
        try require(!first.hover.isHovered, "Phase-less mouse-wheel events must also suppress stationary hover")
        coordinator.pointerMoved(in: window, at: NSPoint(x: 58, y: 75))
        try require(first.hover.isHovered, "Phase-less scrolling must not leave hover permanently disabled")
        coordinator.scroll(in: window, at: NSPoint(x: 58, y: 75), phase: .began, momentumPhase: [])
        coordinator.scroll(in: window, at: NSPoint(x: 58, y: 75), phase: .cancelled, momentumPhase: [])
        coordinator.pointerMoved(in: window, at: NSPoint(x: 62, y: 75))
        try require(first.hover.isHovered, "Cancelled gestures must permit later intentional hover")
        coordinator.scroll(in: window, at: NSPoint(x: 62, y: 75), phase: [], momentumPhase: .began)
        coordinator.scroll(in: window, at: NSPoint(x: 62, y: 75), phase: .began, momentumPhase: [])
        coordinator.scroll(in: window, at: NSPoint(x: 62, y: 75), phase: .ended, momentumPhase: [])
        coordinator.pointerMoved(in: window, at: NSPoint(x: 66, y: 75))
        try require(first.hover.isHovered, "A new finger gesture must clear stale momentum state")

        coordinator.viewportChanged(in: window, at: NSPoint(x: 66, y: 75))
        try require(!first.hover.isHovered, "Viewport movement without a wheel event must clear hover")
        coordinator.pointerMoved(in: window, at: NSPoint(x: 66, y: 75))
        try require(!first.hover.isHovered, "Viewport changes must not accept a stationary move event")
        coordinator.pointerMoved(in: window, at: NSPoint(x: 70, y: 75))
        try require(first.hover.isHovered, "Pointer movement after viewport changes must restore hover")
        first.isEnabled = false
        try require(!first.hover.isHovered, "Disabling a control must clear hover")
        coordinator.pointerMoved(in: window, at: NSPoint(x: 74, y: 75))
        first.hover.mouseEntered(with: entered(at: NSPoint(x: 74, y: 75), window: window))
        try require(!first.hover.isHovered, "Disabled controls must reject enter and move hover")
        first.isEnabled = true
        try require(!first.hover.isHovered, "Re-enabling must not revive stale hover")
        coordinator.pointerMoved(in: window, at: NSPoint(x: 78, y: 75))
        try require(first.hover.isHovered, "An enabled control must hover on later movement")
        first.isEnabled = true
        try require(first.hover.isHovered, "Repeated unchanged enablement assignments must not clear hover")

        first.setButtonType(.switch)
        first.state = .on
        first.isHighlighted = true
        window.makeFirstResponder(first)
        coordinator.scroll(in: window, at: NSPoint(x: 78, y: 75), phase: .began, momentumPhase: [])
        try require(!first.hover.isHovered, "Scrolling must clear the hover layer")
        try require(first.state == .on && first.isHighlighted && window.firstResponder === first,
            "Hover suppression must preserve checked/pressed/keyboard-focus state")
        first.isHighlighted = false
        coordinator.scroll(in: window, at: NSPoint(x: 78, y: 75), phase: .ended, momentumPhase: [])

        first.removeFromSuperview()
        try require(!first.hover.isHovered, "Detached/recycled views must lose hover")
        first.frame = NSRect(x: 20, y: 60, width: 130, height: 30)
        content.addSubview(first); first.updateTrackingAreas()
        first.hover.mouseEntered(with: entered(at: NSPoint(x: 78, y: 75), window: window))
        try require(!first.hover.isHovered, "Recycled views must remain suppressed after scrolling")
        coordinator.pointerMoved(in: window, at: NSPoint(x: 82, y: 75))
        try require(first.hover.isHovered, "A recycled view must recover on genuine movement")

        let cover = NSView(frame: first.frame)
        content.addSubview(cover, positioned: .above, relativeTo: first)
        coordinator.viewportChanged(in: window, at: NSPoint(x: 82, y: 75))
        coordinator.pointerMoved(in: window, at: NSPoint(x: 86, y: 75))
        try require(!first.hover.isHovered, "A covered control must not hover through the frontmost view")
        cover.removeFromSuperview()
        first.isHidden = true
        coordinator.pointerMoved(in: window, at: NSPoint(x: 90, y: 75))
        try require(!first.hover.isHovered, "Hidden controls must not hover")
        first.isHidden = false
        coordinator.pointerMoved(in: window, at: NSPoint(x: 94, y: 75))
        try require(first.hover.isHovered, "Visible controls must resume ordinary pointer behavior")
        coordinator.deactivate(window)
        try require(!first.hover.isHovered, "Window deactivation must clear hover")
        window.reportsKey = false
        coordinator.pointerMoved(in: window, at: NSPoint(x: 98, y: 75))
        try require(!first.hover.isHovered, "Normal controls must not hover in an inactive window")
        window.reportsKey = true
        coordinator.pointerMoved(in: window, at: NSPoint(x: 102, y: 75))
        try require(first.hover.isHovered, "A reactivated window must accept later pointer movement")

        let clip = NSClipView(frame: NSRect(x: 220, y: 20, width: 120, height: 50))
        let document = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 50))
        content.addSubview(clip); clip.documentView = document
        let clipped = probe(NSRect(x: 100, y: 5, width: 100, height: 30), in: document)
        let visiblePoint = clipped.convert(NSPoint(x: 10, y: 10), to: nil)
        let invisiblePoint = clipped.convert(NSPoint(x: 70, y: 10), to: nil)
        coordinator.pointerMoved(in: window, at: visiblePoint)
        try require(clipped.hover.isHovered, "The visible part of a clipped control should hover")
        coordinator.pointerMoved(in: window, at: invisiblePoint)
        try require(!clipped.hover.isHovered, "Clipped-out parts must not hover")
        coordinator.scroll(in: window, at: visiblePoint, phase: .began, momentumPhase: [])
        clip.scroll(to: NSPoint(x: 70, y: 0))
        coordinator.viewportChanged(in: window, at: visiblePoint)
        clipped.hover.mouseEntered(with: entered(at: visiblePoint, window: window))
        try require(!clipped.hover.isHovered, "Horizontal content movement must obey the same suppression")
        coordinator.scroll(in: window, at: visiblePoint, phase: .ended, momentumPhase: [])

        // Native event tracking may omit a terminal scroll event. A phase latch
        // must not permanently veto real pointer movement once activity stops.
        let recoveryPoint = NSPoint(x: 110, y: 75)
        let recoveryTime = ProcessInfo.processInfo.systemUptime
        coordinator.scroll(in: window, at: recoveryPoint, phase: .changed, momentumPhase: [], now: recoveryTime)
        coordinator.pointerMoved(in: window, at: NSPoint(x: 114, y: 75), now: recoveryTime + 0.16)
        try require(first.hover.isHovered, "Missing finger-scroll terminal event must recover after quiet and genuine movement")
        coordinator.scroll(in: window, at: recoveryPoint, phase: [], momentumPhase: .changed, now: recoveryTime + 1)
        coordinator.pointerMoved(in: window, at: NSPoint(x: 114, y: 75), now: recoveryTime + 1.05)
        try require(!first.hover.isHovered, "Recent momentum must still suppress pointer movement")
        coordinator.pointerMoved(in: window, at: NSPoint(x: 118, y: 75), now: recoveryTime + 1.16)
        try require(first.hover.isHovered, "Missing momentum terminal event must recover after quiet and genuine movement")

        for index in 0..<4 {
            let activity = recoveryTime + 2 + Double(index) * 0.1
            coordinator.scroll(in: window, at: recoveryPoint, phase: .changed, momentumPhase: [], now: activity)
            coordinator.pointerMoved(in: window, at: NSPoint(x: 114 + index, y: 75), now: activity + 0.05)
            try require(!first.hover.isHovered, "Continued scroll events must extend suppression despite repeated pointer movement")
        }
        coordinator.pointerMoved(in: window, at: NSPoint(x: 120, y: 75), now: recoveryTime + 2.46)
        try require(first.hover.isHovered, "Recovery must follow the final scroll activity rather than the first one")

        coordinator.scroll(in: window, at: recoveryPoint, phase: .changed, momentumPhase: [], now: recoveryTime + 3)
        coordinator.pointerMoved(in: window, at: recoveryPoint, now: recoveryTime + 10)
        first.hover.mouseEntered(with: entered(at: recoveryPoint, window: window))
        try require(!first.hover.isHovered, "Time alone and same-position enter/move events must never restore stationary hover")
        coordinator.viewportChanged(in: window, at: recoveryPoint, now: recoveryTime + 11)
        coordinator.pointerMoved(in: window, at: NSPoint(x: 114, y: 75), now: recoveryTime + 11.05)
        try require(!first.hover.isHovered, "Viewport movement during a latched scroll must extend the activity interval")
        coordinator.pointerMoved(in: window, at: NSPoint(x: 118, y: 75), now: recoveryTime + 11.16)
        try require(first.hover.isHovered, "Quiet after viewport activity must allow stale-phase recovery")

        // Dispatch only an enter callback at a genuinely displaced point. AppKit
        // need not deliver a separate mouseMoved before entering a tracking area.
        coordinator.scroll(in: window, at: recoveryPoint, phase: .changed, momentumPhase: [], now: ProcessInfo.processInfo.systemUptime - 1)
        window.testPointer = NSPoint(x: 120, y: 75)
        first.hover.mouseEntered(with: entered(at: window.testPointer!, window: window))
        try require(first.hover.isHovered, "A genuine new enter after quiet must recover without a separate mouseMoved event")

        func spin(for duration: TimeInterval) {
            let deadline = Date().addingTimeInterval(duration)
            while Date() < deadline { _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
        }
        func beginPendingMovement() {
            window.testPointer = recoveryPoint
            coordinator.scroll(in: window, at: recoveryPoint, phase: .changed, momentumPhase: [])
            window.testPointer = NSPoint(x: 120, y: 75)
            coordinator.pointerMoved(in: window, at: window.testPointer!)
        }
        beginPendingMovement()
        try require(!first.hover.isHovered, "Movement inside the quiet interval must wait rather than flash hover")
        spin(for: 0.22)
        try require(first.hover.isHovered, "One genuine movement after the final scroll must recover when quiet, without requiring another movement")

        for cancellation in ["scroll", "viewport", "deactivation"] {
            beginPendingMovement()
            switch cancellation {
            case "scroll": coordinator.scroll(in: window, at: window.testPointer!, phase: .changed, momentumPhase: [])
            case "viewport": coordinator.viewportChanged(in: window, at: window.testPointer!)
            default: coordinator.deactivate(window)
            }
            spin(for: 0.22)
            try require(!first.hover.isHovered, "New \(cancellation) must cancel pending pointer intent; timers must not create stationary hover")
        }
        beginPendingMovement()
        window.testPointer = NSPoint(x: 420, y: 240)
        spin(for: 0.22)
        try require(!first.hover.isHovered, "Deferred recovery must reject an old movement when the physical pointer moved elsewhere")
        coordinator.deactivate(window)
        window.testPointer = nil

        weak var releasedState: PointerHoverState?
        autoreleasepool {
            let disposable = NSView(frame: .zero)
            let state = PointerHoverState(view: disposable, onChange: { _ in })
            releasedState = state
        }
        try require(releasedState == nil, "The shared coordinator must retain hover participants weakly")
        print("PASS: \(checks) scroll-hover checks covering missing terminal events, bounded/pending recovery, stationary cursors, ongoing activity, cancellation, viewport changes, disabled/recycled/clipped/covered views, and weak registration")
    }
}
