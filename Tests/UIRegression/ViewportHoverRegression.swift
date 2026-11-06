// Hidden AppKit integration regression. Run from the project directory:
// xcrun swiftc -swift-version 5 Sources/MacFileManager/AppSupport.swift \
//   Tests/UIRegression/ViewportHoverRegression.swift -o .build/qa/viewport-hover-regression
// .build/qa/viewport-hover-regression
// Uses real NSClipView bounds notifications; never calls viewportChanged,
// posts input, or orders a window onto the screen.
import AppKit

private struct ViewportHoverFailure: Error, CustomStringConvertible {
    let description: String
}

private final class ViewportHoverWindow: NSWindow {
    var physicalPointer = NSPoint.zero
    override var isKeyWindow: Bool { true }
    override var canBecomeKey: Bool { true }
    override var mouseLocationOutsideOfEventStream: NSPoint { physicalPointer }
}

private final class ViewportHoverDocument: NSView {
    override var isFlipped: Bool { true }
}

private final class ViewportHoverProbe: NSButton {
    lazy var hover = PointerHoverState(view: self) { [weak self] _ in self?.needsDisplay = true }
    override func updateTrackingAreas() { super.updateTrackingAreas(); hover.updateTrackingAreas() }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); if window == nil { hover.reset() } }
}

@main struct ViewportHoverRegression {
    private static var checks = 0

    static func main() {
        do { try run() }
        catch { FileHandle.standardError.write(Data("FAIL: \(error)\n".utf8)); exit(1) }
    }
    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        checks += 1
        if !condition() { throw ViewportHoverFailure(description: message) }
    }
    private static func pump(_ seconds: TimeInterval) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.005)) }
    }
    private static func makeScroll(_ frame: NSRect, in root: NSView) -> NSScrollView {
        let scroll = NSScrollView(frame: frame)
        scroll.hasVerticalScroller = false; scroll.hasHorizontalScroller = false
        let document = ViewportHoverDocument(frame: NSRect(x: 0, y: 0, width: frame.width, height: 1_200))
        scroll.documentView = document; root.addSubview(scroll)
        return scroll
    }
    private static func makeProbe(_ frame: NSRect, in parent: NSView) -> ViewportHoverProbe {
        let probe = ViewportHoverProbe(frame: frame); probe.title = "Hover"
        parent.addSubview(probe); probe.updateTrackingAreas()
        return probe
    }
    private static func run() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let window = ViewportHoverWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 600, height: 420),
                                         styleMask: .borderless, backing: .buffered, defer: false)
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 420))
        window.contentView = root
        defer { window.close() }
        let toolbar = makeProbe(NSRect(x: 20, y: 360, width: 180, height: 35), in: root)
        let registered = makeScroll(NSRect(x: 20, y: 30, width: 260, height: 280), in: root)
        let unregistered = makeScroll(NSRect(x: 320, y: 30, width: 250, height: 280), in: root)
        let first = makeProbe(NSRect(x: 16, y: 20, width: 220, height: 30), in: registered.documentView!)
        let second = makeProbe(NSRect(x: 16, y: 52, width: 220, height: 30), in: registered.documentView!)
        let clip = registered.contentView
        let otherClip = unregistered.contentView
        // A foreign/native preview clip can post these notifications without
        // containing any app-owned hover participant.
        otherClip.postsBoundsChangedNotifications = true
        var registeredNotifications = 0, foreignNotifications = 0
        let firstObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) { _ in registeredNotifications += 1 }
        let secondObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: otherClip, queue: .main) { _ in foreignNotifications += 1 }
        defer {
            NotificationCenter.default.removeObserver(firstObserver)
            NotificationCenter.default.removeObserver(secondObserver)
        }
        let coordinator = PointerHoverCoordinator.shared
        func resizeRegistered(by delta: CGFloat) {
            clip.setBoundsSize(NSSize(width: clip.bounds.width, height: clip.bounds.height + delta))
        }
        func move(_ point: NSPoint) {
            window.physicalPointer = point
            coordinator.pointerMoved(in: window, at: point)
        }
        let toolbarPoint = NSPoint(x: 90, y: 376)
        move(NSPoint(x: 590, y: 410)); move(toolbarPoint)
        try require(toolbar.hover.isHovered, "Toolbar hover must work before viewport changes")

        let originBeforeResize = clip.bounds.origin
        let notificationsBeforeResize = registeredNotifications
        resizeRegistered(by: -8)
        try require(registeredNotifications > notificationsBeforeResize, "Size-only check must emit a real registered-clip notification")
        try require(hypot(clip.bounds.minX - originBeforeResize.x, clip.bounds.minY - originBeforeResize.y) < 0.01,
                    "Size-only fixture must keep the viewport origin unchanged")
        try require(toolbar.hover.isHovered, "Registered clip resizing must not erase unrelated toolbar hover")

        let notificationsBeforeForeignScroll = foreignNotifications
        otherClip.scroll(to: NSPoint(x: 0, y: 60))
        try require(foreignNotifications > notificationsBeforeForeignScroll, "Foreign clip must emit a real origin-change notification")
        try require(toolbar.hover.isHovered, "An unregistered native clip must not suppress app hover")

        let notificationsBeforeOffPointerScroll = registeredNotifications
        clip.scroll(to: NSPoint(x: 0, y: 32))
        try require(registeredNotifications > notificationsBeforeOffPointerScroll, "Off-pointer scroll must emit a real registered-clip notification")
        try require(toolbar.hover.isHovered, "A registered clip scrolling away from the pointer must preserve toolbar hover")

        clip.scroll(to: .zero)
        let firstPoint = first.convert(NSPoint(x: 70, y: 15), to: nil)
        move(firstPoint)
        try require(first.hover.isHovered && !second.hover.isHovered, "A visible scroll-content control must hover on pointer movement")
        let pointerBeforeScroll = window.physicalPointer
        let notificationsBeforePointerScroll = registeredNotifications
        clip.scroll(to: NSPoint(x: 0, y: 32))
        try require(registeredNotifications > notificationsBeforePointerScroll, "Scroll beneath the pointer must emit a real bounds notification")
        try require(window.physicalPointer == pointerBeforeScroll, "Scroll fixture must leave the physical pointer stationary")
        try require(!first.hover.isHovered && !second.hover.isHovered, "Scrolling beneath a stationary pointer must clear descendant hover")
        let entered = NSEvent.enterExitEvent(with: .mouseEntered, location: firstPoint, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil)!
        second.hover.mouseEntered(with: entered)
        pump(0.22)
        try require(!second.hover.isHovered, "A scroll-generated enter must not light the replacement row after idle")
        move(NSPoint(x: firstPoint.x + 4, y: firstPoint.y))
        try require(second.hover.isHovered && !first.hover.isHovered, "Genuine movement must restore the row now beneath the pointer")

        // A size-only update must also preserve a still-visible hovered child.
        // Use origin zero because setBoundsSize rescales nonzero coordinates.
        move(toolbarPoint)
        clip.scroll(to: .zero)
        move(first.convert(NSPoint(x: 70, y: 15), to: nil))
        let childOriginBeforeResize = clip.bounds.origin
        resizeRegistered(by: -4)
        try require(hypot(clip.bounds.minX - childOriginBeforeResize.x, clip.bounds.minY - childOriginBeforeResize.y) < 0.01,
                    "Child size-only fixture must not scroll")
        try require(first.hover.isHovered, "Size-only layout must preserve hover on a visible child")

        // The physical pointer leaves before the app receives its move event.
        // A subsequent off-pointer scroll must still clear stale descendants.
        window.physicalPointer = toolbarPoint
        clip.scroll(to: NSPoint(x: 0, y: 42))
        try require(!first.hover.isHovered, "Off-pointer origin changes must clear hover in the moved clip")
        move(toolbarPoint)
        try require(toolbar.hover.isHovered, "Clearing stale clip descendants must not suppress the toolbar")

        let cover = NSView(frame: registered.frame)
        root.addSubview(cover, positioned: .above, relativeTo: registered)
        let foreground = makeProbe(NSRect(x: 16, y: 30, width: 220, height: 30), in: cover)
        let foregroundPoint = foreground.convert(NSPoint(x: 70, y: 15), to: nil)
        move(foregroundPoint)
        try require(foreground.hover.isHovered, "A foreground control must hover above the clip")
        let beforeCoveredScroll = registeredNotifications
        clip.scroll(to: NSPoint(x: 0, y: 50))
        try require(registeredNotifications > beforeCoveredScroll, "Covered clip must emit an actual origin notification")
        try require(foreground.hover.isHovered, "Scrolling a covered clip must not suppress foreground overlay hover")
        cover.removeFromSuperview()
        move(toolbarPoint)

        // Missing terminal phase + one actual move queues quiet recovery.
        // Unrelated clip origin/size notifications must not cancel that intent.
        coordinator.scroll(in: window, at: firstPoint, phase: .began, momentumPhase: [])
        let recoveryPoint = NSPoint(x: toolbarPoint.x + 8, y: toolbarPoint.y)
        move(recoveryPoint)
        try require(!toolbar.hover.isHovered, "Active scrolling should initially defer the recovery move")
        let beforePendingNotifications = registeredNotifications + foreignNotifications
        for index in 0..<4 {
            clip.scroll(to: .zero)
            let origin = clip.bounds.origin
            resizeRegistered(by: -1)
            try require(hypot(clip.bounds.minX - origin.x, clip.bounds.minY - origin.y) < 0.01,
                        "Pending-recovery size updates must not move the origin")
            otherClip.scroll(to: NSPoint(x: 0, y: 80 + index * 8))
            clip.scroll(to: NSPoint(x: 0, y: 50 + index * 8))
            pump(0.02)
        }
        try require(registeredNotifications + foreignNotifications > beforePendingNotifications,
                    "Pending recovery must be exercised with actual native notifications")
        pump(0.25)
        try require(toolbar.hover.isHovered, "Size-only and off-pointer/foreign clip changes must not cancel pending hover recovery")
        try require(!window.isVisible, "The integration harness must never display a window")
        print("PASS: \(checks) native viewport-hover checks, \(registeredNotifications) registered and \(foreignNotifications) foreign clip notifications")
    }
}
