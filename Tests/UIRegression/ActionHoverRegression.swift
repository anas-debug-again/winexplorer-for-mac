// Headless native ActionButton hover regression. Run from the project directory:
// xcrun swiftc -swift-version 5 Sources/MacFileManager/AppSupport.swift \
//   Tests/UIRegression/ActionHoverRegression.swift -o .build/qa/action-hover-regression
// .build/qa/action-hover-regression
// Sends Objective-C callbacks directly to the tracking owner. No window is
// displayed/activated, and no input is posted to the application or system.
import AppKit

private final class ActionHoverWindow: NSWindow {
    var reportsKey = true
    var pointer = NSPoint.zero
    override var isKeyWindow: Bool { reportsKey }
    override var mouseLocationOutsideOfEventStream: NSPoint { pointer }
}

private struct ActionHoverFailure: Error, CustomStringConvertible {
    let description: String
}

@main struct ActionHoverRegression {
    static func main() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        NSApp.appearance = NSAppearance(named: .aqua)
        var checks = 0
        func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            checks += 1
            if !condition() { throw ActionHoverFailure(description: message) }
        }
        let window = ActionHoverWindow(contentRect: NSRect(x: -10000, y: -10000, width: 400, height: 240), styleMask: [.titled], backing: .buffered, defer: false)
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 240))
        window.contentView = root
        defer { window.close() }
        var actions = 0
        let button = ActionButton("Copy path", symbol: "doc.on.doc") { actions += 1 }
        button.font = .systemFont(ofSize: 13)
        button.frame = NSRect(x: 30, y: 60, width: 150, height: 30)
        root.addSubview(button)
        button.updateTrackingAreas()
        let owner = button.trackingAreas.compactMap { $0.owner as? PointerHoverState }.first!
        let point = button.convert(NSPoint(x: 50, y: 15), to: nil)
        window.pointer = point
        func dispatch(_ type: NSEvent.EventType, selector: String) throws {
            let method = NSSelectorFromString(selector)
            try require(owner.responds(to: method), "Tracking owner must export \(selector)")
            let event: NSEvent
            if type == .mouseMoved {
                event = NSEvent.mouseEvent(with: type, location: window.pointer, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 0, pressure: 0)!
            } else {
                event = NSEvent.enterExitEvent(with: type, location: window.pointer, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, trackingNumber: 0, userData: nil)!
            }
            _ = owner.perform(method, with: event)
        }
        func pixel() -> CGFloat {
            let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 150, pixelsHigh: 30, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
            NSColor.white.setFill(); button.bounds.fill(); button.draw(button.bounds)
            NSGraphicsContext.restoreGraphicsState()
            return bitmap.colorAt(x: 6, y: 15)!.usingColorSpace(.deviceRGB)!.redComponent
        }
        try dispatch(.mouseEntered, selector: "mouseEntered:")
        try require(owner.isHovered && pixel() < 0.95, "AppKit enter callback must visibly hover the actual ActionButton")
        try dispatch(.mouseExited, selector: "mouseExited:")
        try require(!owner.isHovered && pixel() > 0.99, "AppKit exit callback must clear the actual ActionButton")
        button.updateTrackingAreas()
        try require(!owner.isHovered, "Tracking refresh must not create hover merely because the pointer is inside")
        try dispatch(.mouseMoved, selector: "mouseMoved:")
        try require(owner.isHovered, "AppKit move callback must restore hover")
        button.performClick(nil)
        button.isEnabled = true
        try require(actions == 1 && owner.isHovered, "Click and unchanged enablement must preserve hover")
        button.updateTrackingAreas()
        try require(owner.isHovered && pixel() < 0.95, "Tracking refresh must preserve a still-valid existing hover")
        button.needsDisplay = true; root.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        let deadline = Date().addingTimeInterval(0.15)
        while Date() < deadline { _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
        try require(owner.isHovered, "Deferred AppKit tracking refresh must preserve valid hover after redraw")

        window.pointer = NSPoint(x: 350, y: 200)
        button.updateTrackingAreas()
        try require(!owner.isHovered, "Refresh must clear existing hover when the physical pointer left")
        window.pointer = point
        button.updateTrackingAreas()
        try require(!owner.isHovered, "Refresh must not restore hover when a pointer is newly over the button")
        try dispatch(.mouseMoved, selector: "mouseMoved:")
        let coordinator = PointerHoverCoordinator.shared
        coordinator.scroll(in: window, at: point, phase: .began, momentumPhase: [])
        button.updateTrackingAreas()
        try dispatch(.mouseEntered, selector: "mouseEntered:")
        try require(!owner.isHovered, "Scroll suppression must survive tracking refresh and enter callbacks")
        coordinator.scroll(in: window, at: point, phase: .ended, momentumPhase: [])
        button.updateTrackingAreas()
        try require(!owner.isHovered, "Finger-up must not let tracking refresh recreate hover")
        window.pointer.x += 1
        try dispatch(.mouseMoved, selector: "mouseMoved:")
        try require(owner.isHovered, "Real movement after scroll must still recover hover")
        window.reportsKey = false
        button.updateTrackingAreas()
        try require(!owner.isHovered, "Inactive windows must clear existing hover during tracking refresh")
        window.reportsKey = true
        button.updateTrackingAreas()
        try require(!owner.isHovered, "Reactivation plus tracking refresh must not invent hover")
        try dispatch(.mouseMoved, selector: "mouseMoved:")
        button.isEnabled = false
        button.updateTrackingAreas()
        try require(!owner.isHovered, "Disabled controls must remain clear after tracking refresh")
        button.isEnabled = true
        try dispatch(.mouseMoved, selector: "mouseMoved:")
        let cover = NSView(frame: button.frame)
        root.addSubview(cover, positioned: .above, relativeTo: button)
        button.updateTrackingAreas()
        try require(!owner.isHovered, "A new overlay must invalidate existing hover during tracking refresh")
        cover.removeFromSuperview()
        button.updateTrackingAreas()
        try require(!owner.isHovered, "Removing an overlay must not create a new hover without movement")
        print("PASS: \(checks) ActionButton checks covering exact AppKit callback dispatch, pixels, clicks, valid tracking refresh, scroll suppression, inactivity, disablement and overlays")
    }
}
