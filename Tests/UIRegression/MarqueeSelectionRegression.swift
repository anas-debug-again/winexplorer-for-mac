// Hidden native row-click and drag-selection regression. Run from the project directory:
// scripts/test-ui.sh MarqueeSelection
// Optional --render saves hidden overlay/browser snapshots under .build/qa.
// Calls helpers and native component methods directly. No posted/system input or visible windows.
import AppKit

private struct MarqueeRegressionFailure: Error, CustomStringConvertible { let description: String }
private final class MarqueeTestWindow: NSWindow {
    override var isKeyWindow: Bool { true }
    override var canBecomeKey: Bool { true }
}
private final class MarqueeTestDocument: NSView { override var isFlipped: Bool { true } }

@main struct MarqueeSelectionRegression {
    static var checks = 0
    static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        checks += 1
        if try !condition() { throw MarqueeRegressionFailure(description: message) }
    }
    static func descendants(_ view: NSView) -> [NSView] { view.subviews + view.subviews.flatMap(descendants) }
    static func event(_ type: NSEvent.EventType, point: NSPoint, in view: NSView,
                      modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil), modifierFlags: modifiers,
                          timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: view.window!.windowNumber,
                          context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)!
    }
    static func rectangle(_ first: NSPoint, _ second: NSPoint) -> NSRect {
        NSRect(x: min(first.x, second.x), y: min(first.y, second.y),
               width: max(1, abs(first.x - second.x)), height: max(1, abs(first.y - second.y)))
    }
    static func copyKey(in window: NSWindow) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "c", charactersIgnoringModifiers: "c", isARepeat: false, keyCode: 8)!
    }
    static func wait(_ description: String, _ condition: () -> Bool) throws {
        let end = Date().addingTimeInterval(6)
        while !condition(), Date() < end { _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
        try require(condition(), "Timed out: \(description)")
    }
    static func saveRender(_ view: NSView, _ name: String) throws {
        guard CommandLine.arguments.contains("--render") else { return }
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            throw MarqueeRegressionFailure(description: "Could not create hidden marquee bitmap")
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let output = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/qa/" + name)
        try bitmap.representation(using: .png, properties: [:])!.write(to: output)
    }
    static func overlayBitmap(_ overlay: NSView) -> NSBitmapImageRep {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(overlay.bounds.width), pixelsHigh: Int(overlay.bounds.height),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSColor.clear.setFill(); overlay.bounds.fill(using: .copy)
        NSBezierPath(rect: overlay.bounds).addClip()
        overlay.draw(overlay.bounds)
        NSGraphicsContext.restoreGraphicsState()
        return bitmap
    }
    static func verifyOverlayPaint(_ overlay: NSView) throws {
        let bitmap = overlayBitmap(overlay)
        var fill = 0, outline = 0, clear = 0
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                let color = bitmap.colorAt(x: x, y: y)!.usingColorSpace(.deviceRGB)!
                if color.alphaComponent < 0.01 { clear += 1 }
                if color.blueComponent > color.redComponent + 0.15 {
                    if color.alphaComponent > 0.05 && color.alphaComponent < 0.4 { fill += 1 }
                    if color.alphaComponent >= 0.5 { outline += 1 }
                }
            }
        }
        try require(fill > 100 && outline > 30 && clear > 100, "Rectangle painting must contain translucent blue fill, a stronger blue outline, and a clear exterior")
        if CommandLine.arguments.contains("--render") {
            let output = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/qa/marquee-overlay.png")
            try bitmap.representation(using: .png, properties: [:])!.write(to: output)
        }
    }
    static func main() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        NSApp.appearance = NSAppearance(named: .aqua)
        try helperBehavior()
        try actualBrowserBehavior()
        print("PASS: \(checks) marquee checks covering threshold, four quadrants, straight-line drags, modifier snapshots, keyboard commit/cancel ordering, hover suppression/recovery, overlay hit-testing/clipping, autoscroll, grouped rows, and all browser layouts")
    }

    static func helperBehavior() throws {
        let window = MarqueeTestWindow(contentRect: NSRect(x: -10000, y: -10000, width: 320, height: 230),
                                       styleMask: .borderless, backing: .buffered, defer: false)
        defer { window.close() }
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 320, height: 230))
        let document = MarqueeTestDocument(frame: NSRect(x: 0, y: 0, width: 800, height: 900))
        scroll.documentView = document; window.contentView = scroll
        let itemRects: [IndexPath: NSRect] = [
            IndexPath(item: 0, section: 0): NSRect(x: 20, y: 20, width: 30, height: 20),
            IndexPath(item: 1, section: 0): NSRect(x: 80, y: 20, width: 30, height: 20),
            IndexPath(item: 0, section: 1): NSRect(x: 20, y: 65, width: 30, height: 20),
            IndexPath(item: 1, section: 1): NSRect(x: 80, y: 65, width: 30, height: 20),
            IndexPath(item: 2, section: 1): NSRect(x: 220, y: 400, width: 30, height: 20)
        ]
        func hits(_ rectangle: NSRect) -> Set<IndexPath> {
            Set(itemRects.compactMap { rectangle.intersects($0.value) ? $0.key : nil })
        }
        var selection = Set<IndexPath>()
        let marquee = PaneSelectionMarquee(owner: document, selection: { selection },
                                          applySelection: { selection = $0 }, itemsIntersecting: hits)
        let old = IndexPath(item: 2, section: 1)
        selection = [old]
        let anchor = NSPoint(x: 10, y: 10)
        marquee.begin(with: event(.leftMouseDown, point: anchor, in: document))
        try require(marquee.isActive && marquee.rectangle == nil && selection.isEmpty,
                    "Plain blank mouse-down must capture the gesture, clear selection, and wait for drag threshold")
        marquee.update(with: event(.leftMouseDragged, point: NSPoint(x: 12, y: 10), in: document))
        try require(marquee.rectangle == nil && descendants(scroll).allSatisfy { $0.identifier?.rawValue != "browser.selectionRectangle" },
                    "Movement below three points must not create a rectangle")
        marquee.finish(cancelled: true)
        try require(selection == [old] && !marquee.isActive, "Cancelling a pending click must restore its original selection")
        marquee.begin(with: event(.leftMouseDown, point: anchor, in: document))
        marquee.finish()
        try require(selection.isEmpty && !marquee.isActive, "An ordinary blank click must keep its cleared selection")

        let clicked = IndexPath(item: 0, section: 0)
        selection = [old]
        marquee.begin(with: event(.leftMouseDown, point: anchor, in: document), clickSelection: [clicked])
        try require(selection == [clicked] && marquee.rectangle == nil,
                    "A row's pending drag must immediately publish its ordinary click selection")
        marquee.update(with: event(.leftMouseUp, point: NSPoint(x: 12, y: 10), in: document))
        marquee.finish()
        try require(selection == [clicked], "A row click with sub-threshold movement must retain its selection")
        for modifiers: NSEvent.ModifierFlags in [[], .shift, .command] {
            selection = [old]
            marquee.begin(with: event(.leftMouseDown, point: anchor, in: document, modifiers: modifiers), clickSelection: [clicked])
            let endpoint = NSPoint(x: 125, y: 95)
            marquee.update(with: event(.leftMouseDragged, point: endpoint, in: document))
            let intersected = hits(rectangle(anchor, endpoint))
            let expected = modifiers.contains(.command) ? Set([old]).symmetricDifference(intersected)
                : modifiers.contains(.shift) ? Set([old]).union(intersected) : intersected
            try require(selection == expected,
                        "Dragging after a row click must use the original selection, not its temporary clicked-row selection")
            marquee.finish(cancelled: true)
            try require(selection == [old], "Escape after a row-origin drag must restore the pre-click selection")
        }

        let corners: [(NSPoint, NSPoint)] = [
            (NSPoint(x: 10, y: 10), NSPoint(x: 125, y: 95)),
            (NSPoint(x: 125, y: 10), NSPoint(x: 10, y: 95)),
            (NSPoint(x: 10, y: 95), NSPoint(x: 125, y: 10)),
            (NSPoint(x: 125, y: 95), NSPoint(x: 10, y: 10))
        ]
        for (start, end) in corners {
            selection = [old]
            marquee.begin(with: event(.leftMouseDown, point: start, in: document))
            marquee.update(with: event(.leftMouseDragged, point: end, in: document, modifiers: .shift))
            let expected = rectangle(start, end)
            try require(marquee.rectangle == expected && selection == hits(expected), "Every drag quadrant must normalize geometry and use mouse-down modifiers")
            guard let overlay = descendants(scroll).first(where: { $0.identifier?.rawValue == "browser.selectionRectangle" }) else {
                throw MarqueeRegressionFailure(description: "An active drag must expose its rectangle overlay")
            }
            try require(overlay.hitTest(NSPoint(x: overlay.frame.midX, y: overlay.frame.midY)) == nil,
                        "The rectangle overlay must not intercept file mouse events")
            let visible = overlay.convert(overlay.visibleRect, to: scroll.contentView)
            try require(scroll.contentView.bounds.insetBy(dx: -0.5, dy: -0.5).contains(visible),
                        "The overlay's visible drawing must remain clipped to its viewport")
            try verifyOverlayPaint(overlay)
            marquee.finish()
            try require(selection == hits(expected) && marquee.rectangle == nil && !marquee.isActive,
                        "Ordinary release must keep selected items and clear rectangle state")
            try require(descendants(scroll).allSatisfy { $0.identifier?.rawValue != "browser.selectionRectangle" },
                        "Ordinary release must remove its overlay")
        }

        let straightLines: [(NSPoint, NSPoint)] = [
            (NSPoint(x: 10, y: 30), NSPoint(x: 125, y: 30)),
            (NSPoint(x: 125, y: 30), NSPoint(x: 10, y: 30)),
            (NSPoint(x: 30, y: 10), NSPoint(x: 30, y: 95)),
            (NSPoint(x: 30, y: 95), NSPoint(x: 30, y: 10))
        ]
        for (start, end) in straightLines {
            selection = [old]
            marquee.begin(with: event(.leftMouseDown, point: start, in: document))
            marquee.update(with: event(.leftMouseDragged, point: end, in: document))
            let expected = rectangle(start, end)
            try require(marquee.rectangle == expected && (expected.width == 1 || expected.height == 1),
                        "Perfectly horizontal and vertical drags must retain a one-point hit rectangle")
            try require(!selection.isEmpty && selection == hits(expected), "The visible straight line must select exactly the items it intersects")
            let overlay = descendants(scroll).first { $0.identifier?.rawValue == "browser.selectionRectangle" }!
            let bitmap = overlayBitmap(overlay)
            var painted = 0, minX = bitmap.pixelsWide, maxX = -1, minY = bitmap.pixelsHigh, maxY = -1
            for y in 0..<bitmap.pixelsHigh {
                for x in 0..<bitmap.pixelsWide {
                    let color = bitmap.colorAt(x: x, y: y)!.usingColorSpace(.deviceRGB)!
                    if color.alphaComponent > 0.04 && color.blueComponent > color.redComponent + 0.15 {
                        painted += 1; minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
                    }
                }
            }
            let thinExtent = expected.width == 1 ? maxX - minX + 1 : maxY - minY + 1
            try require(painted > 30 && thinExtent >= 1 && thinExtent <= 3,
                        "Straight-line intersection geometry must have a matching visible thin blue outline")
            marquee.finish()
        }

        let hoverView = NSView(frame: NSRect(x: 150, y: 110, width: 80, height: 40))
        document.addSubview(hoverView)
        let hover = PointerHoverState(view: hoverView) { _ in }
        hover.updateTrackingAreas()
        let hoverPoint = NSPoint(x: 165, y: 125)
        let coordinator = PointerHoverCoordinator.shared
        coordinator.pointerMoved(in: window, at: document.convert(hoverPoint, to: nil))
        try require(hover.isHovered, "Hover fixture must be eligible before rectangle selection")
        marquee.begin(with: event(.leftMouseDown, point: anchor, in: document))
        try require(!hover.isHovered, "Starting a selection gesture must clear existing hover")
        marquee.update(with: event(.leftMouseDragged, point: hoverPoint, in: document))
        coordinator.pointerMoved(in: window, at: document.convert(hoverPoint, to: nil))
        try require(!hover.isHovered, "Pointer movement during a rectangle drag must not create row/control hover")
        marquee.finish()
        coordinator.pointerMoved(in: window, at: document.convert(hoverPoint, to: nil))
        try require(!hover.isHovered, "Releasing a rectangle must keep hover suppressed under a stationary pointer")
        coordinator.pointerMoved(in: window, at: document.convert(NSPoint(x: hoverPoint.x + 2, y: hoverPoint.y), to: nil))
        try require(hover.isHovered, "Fresh movement after release must restore hover on the actual hit control")
        hoverView.removeFromSuperview()

        let firstHit = IndexPath(item: 0, section: 0)
        let baseline: Set<IndexPath> = [old, firstHit]
        let end = NSPoint(x: 125, y: 95)
        let smallEnd = NSPoint(x: 55, y: 45)
        for modifier in [NSEvent.ModifierFlags.command, .shift] {
            selection = baseline
            marquee.begin(with: event(.leftMouseDown, point: anchor, in: document, modifiers: modifier))
            try require(selection == baseline, "Modified mouse-down must keep the existing selection")
            marquee.update(with: event(.leftMouseDragged, point: end, in: document))
            let largeHits = hits(rectangle(anchor, end))
            let expected = modifier == .command ? baseline.symmetricDifference(largeHits) : baseline.union(largeHits)
            try require(selection == expected, "Command must toggle and Shift must extend the mouse-down snapshot")
            marquee.update(with: event(.leftMouseDragged, point: end, in: document, modifiers: modifier == .command ? .shift : .command))
            try require(selection == expected, "Repeated updates and changed modifier flags must not cumulatively toggle selection")
            marquee.update(with: event(.leftMouseDragged, point: smallEnd, in: document))
            let smallHits = hits(rectangle(anchor, smallEnd))
            try require(selection == (modifier == .command ? baseline.symmetricDifference(smallHits) : baseline.union(smallHits)),
                        "Shrinking the drag must recompute from the original snapshot")
            marquee.finish(cancelled: true)
            try require(selection == baseline, "Cancelling a modified drag must restore the entire initial selection")
        }

        selection = baseline
        marquee.begin(with: event(.leftMouseDown, point: anchor, in: document))
        marquee.update(with: event(.leftMouseDragged, point: end, in: document))
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        try require(!marquee.isActive && selection == baseline, "Window deactivation must cancel and restore the original selection")

        scroll.contentView.scroll(to: .zero)
        selection = []
        let visible = document.visibleRect
        let scrollStart = NSPoint(x: visible.minX + 8, y: visible.minY + 100)
        let scrollEnd = NSPoint(x: visible.minX + 250, y: visible.maxY + 35)
        marquee.begin(with: event(.leftMouseDown, point: scrollStart, in: document))
        marquee.update(with: event(.leftMouseDragged, point: scrollEnd, in: document))
        let oldOrigin = scroll.contentView.bounds.origin
        let oldRectangle = marquee.rectangle!
        for _ in 0..<5 { marquee.autoscrollTick() }
        try require(scroll.contentView.bounds.origin.y > oldOrigin.y, "Dragging below the viewport must autoscroll its document")
        try require(marquee.rectangle!.maxY > oldRectangle.maxY, "Autoscroll must extend the document-coordinate rectangle under a fixed window pointer")
        try require(selection == hits(marquee.rectangle!), "Autoscroll must recompute selection against document coordinates")
        marquee.finish()
        let stoppedOrigin = scroll.contentView.bounds.origin
        marquee.autoscrollTick()
        try require(scroll.contentView.bounds.origin == stoppedOrigin, "Autoscroll ticks after release must have no effect")
    }

    static func actualBrowserBehavior() throws {
        let manager = FileManager.default
        let fixture = URL(fileURLWithPath: manager.currentDirectoryPath).appendingPathComponent(".build/qa/marquee-fixtures-" + UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: fixture, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: fixture) }
        var urls: [URL] = []
        for name in ["alpha.txt", "bravo.txt", "charlie.md", "delta.md", "echo.csv", "foxtrot.csv"] {
            let url = fixture.appendingPathComponent(name); try Data("fixture content\n".utf8).write(to: url); urls.append(url)
        }
        let folder = fixture.appendingPathComponent("Folder", isDirectory: true)
        try manager.createDirectory(at: folder, withIntermediateDirectories: true); urls.append(folder)
        let pane = BrowserPaneViewController(url: fixture)
        let window = MarqueeTestWindow(contentRect: NSRect(x: -10000, y: -10000, width: 960, height: 760),
                                       styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = pane.view; window.orderOut(nil)
        defer { window.close() }
        var lastSelection: [URL] = []
        pane.onSelectionChange = { lastSelection = $0 }
        guard let table = descendants(pane.view).first(where: { $0 is PaneFileTableView }) as? PaneFileTableView else {
            throw MarqueeRegressionFailure(description: "Native browser table must be available")
        }
        try wait("fixture rows") { table.numberOfRows == urls.count }
        pane.setPresentationMode(split: false); pane.view.layoutSubtreeIfNeeded()
        func rowURL(_ index: Int) -> URL? { pane.tableView(table, pasteboardWriterForRow: index) as? URL }
        func tableHits(_ rectangle: NSRect) -> Set<URL> {
            Set((0..<table.numberOfRows).compactMap { index in
                table.rect(ofRow: index).intersects(rectangle) ? rowURL(index) : nil
            })
        }
        func nameTail(_ row: Int) throws -> NSPoint {
            guard let name = table.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier("name")),
                  let column = table.tableColumns.firstIndex(of: name) else {
                throw MarqueeRegressionFailure(description: "Name column must exist for row-click testing")
            }
            let frame = table.frameOfCell(atColumn: column, row: row)
            return NSPoint(x: frame.maxX - 6, y: frame.midY)
        }
        func clickNameTail(_ row: Int, modifiers: NSEvent.ModifierFlags = [], movement: CGFloat = 0,
                           expected: Set<URL>) throws {
            let point = try nameTail(row)
            try require(table.canStartMarquee(at: point), "Click test must exercise unselected Name-column whitespace")
            table.mouseDown(with: event(.leftMouseDown, point: point, in: table, modifiers: modifiers))
            try require(Set(pane.selectedURLs) == expected && table.selectionMarquee.rectangle == nil,
                        "Name whitespace must select the full row on mouseDown, before any rectangle is drawn")
            table.mouseUp(with: event(.leftMouseUp, point: NSPoint(x: point.x - movement, y: point.y), in: table, modifiers: modifiers))
            try require(Set(pane.selectedURLs) == expected && !table.selectionMarquee.isActive,
                        "Stationary and sub-threshold Name-whitespace clicks must retain the intended row selection")
            try require(Set(lastSelection) == expected, "A row-whitespace click must notify the browser selection callback")
        }
        func tableGesture(start: NSPoint, end: NSPoint, modifiers: NSEvent.ModifierFlags = [], renderName: String? = nil) throws -> NSRect {
            try require(table.canStartMarquee(at: start), "Table test must start in a confirmed blank hit region")
            let down = event(.leftMouseDown, point: start, in: table, modifiers: modifiers)
            if table.bounds.contains(start) { table.mouseDown(with: down) }
            else { table.enclosingScrollView!.contentView.mouseDown(with: down) }
            try require(table.selectionMarquee.isActive, "Blank table mouseDown must enter marquee handling")
            table.mouseDragged(with: event(.leftMouseDragged, point: end, in: table))
            guard let rectangle = table.selectionMarquee.rectangle else {
                throw MarqueeRegressionFailure(description: "Native table drag must create a selection rectangle")
            }
            if let renderName { try saveRender(pane.view, renderName) }
            table.mouseUp(with: event(.leftMouseUp, point: end, in: table))
            try require(!table.selectionMarquee.isActive, "Native table mouseUp must finish the marquee")
            return rectangle
        }
        let lastFrame = table.rect(ofRow: table.numberOfRows - 1)
        let blank = NSPoint(x: 6, y: lastFrame.maxY + 18)
        let clip = table.enclosingScrollView!.contentView
        try require(table.row(at: blank) == -1 && clip.bounds.contains(clip.convert(blank, from: table)), "Table fixture must provide visible blank space below its rows")
        pane.selectFiles([urls[0]])
        let tableRectangle = try tableGesture(start: blank, end: NSPoint(x: table.bounds.maxX - 12, y: table.rect(ofRow: 1).minY + 2), renderName: "marquee-details.png")
        try require(Set(pane.selectedURLs) == tableHits(tableRectangle), "Actual table intersection must map to file URLs")
        try require(Set(lastSelection) == Set(pane.selectedURLs), "Table drag selection must notify the browser's selection callback")
        let committed = Set(pane.selectedURLs)
        pane.setViewMode("mediumIcons"); pane.setViewMode("details")
        try require(Set(pane.selectedURLs) == committed, "Drag selection must survive a view-mode change")

        for clickedURL in [urls[0], folder] {
            pane.selectFiles([clickedURL == folder ? urls[0] : folder])
            guard let row = (0..<table.numberOfRows).first(where: { rowURL($0) == clickedURL }) else {
                throw MarqueeRegressionFailure(description: "Click fixture must expose both a file and a folder row")
            }
            try clickNameTail(row, movement: clickedURL == folder ? 0 : 2, expected: [clickedURL])
            try require(table.selectedRowIndexes == IndexSet(integer: row), "Clicking either a file or folder row must use native full-row selection")
        }
        pane.selectFiles([folder])
        table.enclosingScrollView!.contentView.mouseDown(with: event(.leftMouseDown, point: blank, in: table))
        try require(pane.selectedURLs.isEmpty, "A blank click below the document rows must still clear the selection")
        table.mouseUp(with: event(.leftMouseUp, point: blank, in: table))
        try require(pane.selectedURLs.isEmpty && !table.selectionMarquee.isActive,
                    "Releasing a blank below-row click must not select the nearest file")

        var copied: [Set<URL>] = []
        pane.onRequestAction = { action in if case .copy = action { copied.append(Set(pane.selectedURLs)) } }
        func pendingTableDrag() -> Set<URL> {
            pane.selectFiles([folder])
            table.selectionMarquee.begin(with: event(.leftMouseDown, point: blank, in: table))
            table.selectionMarquee.update(with: event(.leftMouseDragged, point: NSPoint(x: table.bounds.maxX - 12, y: table.rect(ofRow: 1).minY + 2), in: table))
            return Set(pane.selectedURLs)
        }
        for globalMonitorFirst in [true, false] {
            let selectedByDrag = pendingTableDrag()
            try require(!selectedByDrag.isEmpty && selectedByDrag != [folder], "Keyboard test must distinguish original selection from drag selection")
            if globalMonitorFirst {
                try require(pane.endSelectionGesture(), "The window's pre-shortcut hook must report an active gesture")
                try require(!pane.endSelectionGesture(), "Ending an already committed gesture must be harmless")
            }
            table.keyDown(with: copyKey(in: window))
            try require(!table.selectionMarquee.isActive && Set(pane.selectedURLs) == selectedByDrag,
                        "A non-Escape table shortcut must commit the current drag selection")
            try require(copied.last == selectedByDrag, "Copy must receive the same drag selection regardless of monitor/native-handler order")
        }
        _ = pendingTableDrag()
        try require(pane.endSelectionGesture(cancelled: true) && Set(pane.selectedURLs) == [folder],
                    "Explicit pane cancellation must restore the table's original selection")
        try require(!pane.endSelectionGesture(cancelled: true), "Cancelling an idle pane must report no active gesture")

        pane.setGroupBy("type"); pane.view.layoutSubtreeIfNeeded()
        let headers = (0..<table.numberOfRows).filter { pane.tableView(table, isGroupRow: $0) }
        try require(!headers.isEmpty, "Grouped table fixture must contain real headers")
        let header = table.rect(ofRow: headers[0])
        let groupedRectangle = try tableGesture(start: NSPoint(x: 4, y: header.midY),
                                               end: NSPoint(x: table.bounds.maxX - 10, y: table.rect(ofRow: table.numberOfRows - 1).maxY - 2), renderName: "marquee-grouped-details.png")
        try require(Set(pane.selectedURLs) == tableHits(groupedRectangle), "Grouped table selection must ignore header rows and preserve URL mapping")
        try require(table.selectedRowIndexes.allSatisfy { rowURL($0) != nil }, "A group header must never enter native selectedRowIndexes")
        let fileRow = (0..<table.numberOfRows).first { rowURL($0) != nil }!
        if let name = table.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier("name")) {
            let nameIndex = table.tableColumns.firstIndex(of: name)!
            let cell = table.frameOfCell(atColumn: nameIndex, row: fileRow)
            pane.selectFiles([urls[0]])
            let tail = NSPoint(x: cell.maxX - 6, y: cell.midY)
            try require(table.canStartMarquee(at: tail), "Unselected name whitespace must be an eligible blank hit")
            try require(!table.canStartMarquee(at: NSPoint(x: cell.minX + 14, y: cell.midY)), "The actual file icon must retain native click/drag behavior")
            table.mouseDown(with: event(.leftMouseDown, point: tail, in: table))
            try require(table.selectionMarquee.isActive, "Empty tail of the Name cell must start rectangle selection")
            let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!
            table.keyDown(with: escape)
            try require(!table.selectionMarquee.isActive, "Native table Escape must cancel rectangle selection")
            try require(Set(pane.selectedURLs) == [urls[0]], "Cancelling Name-column background selection must restore the selected file")
        }

        pane.selectFiles([folder])
        let headerPoint = NSPoint(x: 4, y: header.midY)
        table.mouseDown(with: event(.leftMouseDown, point: headerPoint, in: table))
        table.mouseUp(with: event(.leftMouseUp, point: headerPoint, in: table))
        try require(pane.selectedURLs.isEmpty && table.selectedRowIndexes.isEmpty,
                    "A stationary group-header click must remain a nonselectable background click")

        let fileRows = (0..<table.numberOfRows).filter { rowURL($0) != nil }
        try require(fileRows.count >= 5, "Modifier-click fixture must contain enough selectable rows")
        let anchorRow = fileRows[3], lowRow = fileRows[1], highRow = fileRows.last!
        func rangeURLs(_ first: Int, _ last: Int) -> Set<URL> {
            Set((min(first, last)...max(first, last)).compactMap(rowURL))
        }
        pane.selectFiles([rowURL(fileRows[0])!])
        try clickNameTail(anchorRow, expected: [rowURL(anchorRow)!])
        try clickNameTail(lowRow, modifiers: .shift, expected: rangeURLs(anchorRow, lowRow))
        try require(table.selectedRowIndexes.allSatisfy { rowURL($0) != nil },
                    "Shift-click ranges must exclude intervening nonselectable group headers")
        try clickNameTail(highRow, modifiers: .shift, expected: rangeURLs(anchorRow, highRow))
        try require(!table.selectedRowIndexes.contains(lowRow),
                    "Repeated Shift clicks must retain the original anchor when the range crosses to its other side")
        let beforeCommand = Set(pane.selectedURLs)
        try clickNameTail(fileRows[0], modifiers: .command,
                          expected: beforeCommand.union([rowURL(fileRows[0])!]))

        for modifiers: NSEvent.ModifierFlags in [.shift, .command] {
            let baseline: Set<URL> = [rowURL(highRow)!]
            pane.selectFiles(Array(baseline))
            let start = try nameTail(lowRow)
            try require(table.canStartMarquee(at: start), "Modified row-origin drag must start on unselected Name whitespace")
            table.mouseDown(with: event(.leftMouseDown, point: start, in: table, modifiers: modifiers))
            try require(pane.selectedURLs.contains(rowURL(lowRow)!), "Modified row-origin mouseDown must first apply its click selection")
            let end = NSPoint(x: table.bounds.maxX - 12, y: table.rect(ofRow: fileRows[2]).midY)
            table.mouseDragged(with: event(.leftMouseDragged, point: end, in: table, modifiers: modifiers))
            guard let dragged = table.selectionMarquee.rectangle else {
                throw MarqueeRegressionFailure(description: "Modified Name-whitespace movement must become a real marquee")
            }
            let hits = tableHits(dragged)
            let expected = modifiers.contains(.command) ? baseline.symmetricDifference(hits) : baseline.union(hits)
            try require(Set(pane.selectedURLs) == expected,
                        "A modified row-origin marquee must calculate against the selection from before mouseDown")
            let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!
            table.keyDown(with: escape)
            try require(Set(pane.selectedURLs) == baseline && !table.selectionMarquee.isActive,
                        "Escape from a modified row-origin marquee must restore the exact pre-click file selection")
        }

        for mode in ["list", "smallIcons", "mediumIcons", "largeIcons", "tiles"] {
            pane.setViewMode(mode); pane.view.layoutSubtreeIfNeeded(); pane.viewDidLayout()
            guard let collection = descendants(pane.view).first(where: { $0 is PaneIconCollectionView }) as? PaneIconCollectionView,
                  let layout = collection.collectionViewLayout else {
                throw MarqueeRegressionFailure(description: "Native collection must exist for \(mode)")
            }
            collection.enclosingScrollView?.contentView.scroll(to: .zero)
            collection.layoutSubtreeIfNeeded()
            try wait("\(mode) layout") { layout.layoutAttributesForItem(at: IndexPath(item: 0, section: 0)) != nil }
            let visible = collection.visibleRect
            let start = NSPoint(x: visible.minX + 2, y: visible.minY + 2)
            let end = NSPoint(x: visible.minX + min(visible.width - 8, 480), y: visible.minY + min(visible.height - 8, 330))
            try require(collection.indexPathForItem(at: start) == nil, "\(mode) fixture must begin in a real collection margin")
            let initial = Set([urls[0], urls[1]])
            pane.selectFiles(Array(initial))
            collection.mouseDown(with: event(.leftMouseDown, point: start, in: collection, modifiers: .command))
            try require(collection.selectionMarquee.isActive, "\(mode) native background mouseDown must enter marquee handling")
            collection.mouseDragged(with: event(.leftMouseDragged, point: end, in: collection, modifiers: .shift))
            guard let rectangle = collection.selectionMarquee.rectangle else {
                throw MarqueeRegressionFailure(description: "\(mode) drag must expose its document rectangle")
            }
            var hits = Set<URL>()
            for section in 0..<collection.numberOfSections {
                for item in 0..<collection.numberOfItems(inSection: section) {
                    let index = IndexPath(item: item, section: section)
                    if let attributes = layout.layoutAttributesForItem(at: index), attributes.frame.intersects(rectangle),
                       let url = pane.collectionView(collection, pasteboardWriterForItemAt: index) as? URL {
                        hits.insert(url)
                    }
                }
            }
            try require(!hits.isEmpty, "\(mode) rectangle must exercise actual item intersections")
            try require(Set(pane.selectedURLs) == initial.symmetricDifference(hits), "\(mode) grouped/column layout must map command-toggle intersections to the correct URLs")
            try require(Set(lastSelection) == Set(pane.selectedURLs), "\(mode) marquee must update selection notifications")
            try saveRender(pane.view, "marquee-\(mode).png")
            collection.mouseUp(with: event(.leftMouseUp, point: end, in: collection))
            try require(!collection.selectionMarquee.isActive && collection.selectionMarquee.rectangle == nil, "\(mode) native release must remove its rectangle")
            try require(Set(pane.selectedURLs) == initial.symmetricDifference(hits), "\(mode) native release must preserve its committed selection")
            try require(collection.selectionIndexPaths.allSatisfy { $0.section < collection.numberOfSections && $0.item < collection.numberOfItems(inSection: $0.section) },
                        "\(mode) native selection must contain items, never supplementary group headers")
            if mode == "tiles" {
                pane.selectFiles(Array(initial))
                collection.mouseDown(with: event(.leftMouseDown, point: start, in: collection))
                collection.mouseDragged(with: event(.leftMouseDragged, point: end, in: collection))
                let dragSelection = Set(pane.selectedURLs)
                collection.keyDown(with: copyKey(in: window))
                try require(!collection.selectionMarquee.isActive && Set(pane.selectedURLs) == dragSelection && copied.last == dragSelection,
                            "Collection Copy must commit its rectangle and pass the current selected URLs")
                pane.selectFiles(Array(initial))
                collection.mouseDown(with: event(.leftMouseDown, point: start, in: collection))
                collection.mouseDragged(with: event(.leftMouseDragged, point: end, in: collection))
                try require(pane.endSelectionGesture(cancelled: true) && Set(pane.selectedURLs) == initial,
                            "Explicit pane cancellation must also restore the collection's original selection")
                collection.mouseDown(with: event(.leftMouseDown, point: start, in: collection))
                collection.mouseDragged(with: event(.leftMouseDragged, point: end, in: collection))
                let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                    windowNumber: window.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!
                collection.keyDown(with: escape)
                try require(!collection.selectionMarquee.isActive && Set(pane.selectedURLs) == initial,
                            "Native collection Escape must restore the original selection")
            }
        }
    }
}
