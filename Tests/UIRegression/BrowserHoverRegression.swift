// Headless AppKit regression harness. Run from the project directory:
// xcrun swiftc -swift-version 5 Sources/MacFileManager/AppSupport.swift Sources/MacFileManager/ThisMacViewController.swift Sources/MacFileManager/BrowserPaneViewController.swift Sources/MacFileManager/ShortcutSupport.swift \
//   Tests/UIRegression/BrowserHoverRegression.swift -o .build/qa/browser-hover-regression
// .build/qa/browser-hover-regression
// Uses an undisplayed native window. No activation, input posting or CUA.
// Only temporary fixtures under .build/qa are created and removed.
import AppKit

// Hidden native component probe. A key-window override permits hover eligibility
// without displaying/activating a window or sending input events to the app.
private final class HoverTestWindow: NSWindow {
    override var isKeyWindow: Bool { true }
}

@main struct BrowserHoverRegression {
    static func main() throws {
        var failed = 0
        func check(_ condition: Bool, _ message: String) {
            if !condition { failed += 1; FileHandle.standardError.write(Data("CHECK FAILED: \(message)\n".utf8)) }
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        app.appearance = NSAppearance(named: .aqua)
        let trackingProbeView = NSView()
        let trackingProbe = PointerHoverState(view: trackingProbeView) { _ in }
        // A tracking owner derived from NSObject needs the exact NSResponder
        // Objective-C selectors; inferred mouseEnteredWith: is never dispatched.
        for selector in ["mouseEntered:", "mouseExited:", "mouseMoved:"] {
            check(trackingProbe.responds(to: NSSelectorFromString(selector)), "Tracking helper must expose AppKit's \(selector) selector")
        }
        let manager = FileManager.default
        let fixtures = URL(fileURLWithPath: manager.currentDirectoryPath).appendingPathComponent(".build/qa/hover-fixtures-\(UUID().uuidString)")
        try manager.createDirectory(at: fixtures, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: fixtures) }
        for index in 0..<40 {
            try Data("hover check".utf8).write(to: fixtures.appendingPathComponent(String(format: "file-%02d.txt", index)))
        }
        let pane = BrowserPaneViewController(url: fixtures)
        let window = HoverTestWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 420), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = pane.view
        window.orderOut(nil)
        defer { window.close() }
        func descendants(_ view: NSView) -> [NSView] { view.subviews + view.subviews.flatMap(descendants) }
        let table = descendants(pane.view).first { $0 is NSTableView } as! NSTableView
        func wait(_ condition: () -> Bool) {
            let deadline = Date().addingTimeInterval(5)
            while !condition() && Date() < deadline {
                _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
            }
            check(condition(), "Native browser content did not settle")
        }
        wait { table.numberOfRows == 40 }
        pane.view.layoutSubtreeIfNeeded()
        let row = table.rowView(atRow: 0, makeIfNecessary: true)!
        row.updateTrackingAreas()
        let coordinator = PointerHoverCoordinator.shared
        // NSTableView consumes hit-testing for cell clicks, so its returned hit is
        // the table itself. The shared helper must accept this owning ancestor
        // while still requiring the pointer to be inside this row's visibleRect.
        let point = row.convert(NSPoint(x: 70, y: row.bounds.midY), to: nil)
        func rowPixel() -> NSColor {
            let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(row.bounds.width), pixelsHigh: Int(row.bounds.height), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
            NSColor.white.setFill(); row.bounds.fill()
            row.drawBackground(in: row.bounds)
            if row.isSelected { row.drawSelection(in: row.bounds) }
            NSGraphicsContext.restoreGraphicsState()
            return bitmap.colorAt(x: 10, y: 10)!.usingColorSpace(.deviceRGB)!
        }
        let idle = rowPixel()
        coordinator.pointerMoved(in: window, at: point)
        let hover = rowPixel()
        check(hover.redComponent < idle.redComponent - 0.02, "Actual table row must hover through contentView hitTest")
        coordinator.scroll(in: window, at: point, phase: .began, momentumPhase: [])
        check(rowPixel().redComponent > 0.99, "Scroll must clear actual row hover")
        coordinator.pointerMoved(in: window, at: NSPoint(x: point.x + 1, y: point.y))
        check(rowPixel().redComponent > 0.99, "Pointer movement during scrolling must remain suppressed")
        coordinator.scroll(in: window, at: point, phase: .ended, momentumPhase: [])
        coordinator.scroll(in: window, at: point, phase: [], momentumPhase: .began)
        coordinator.pointerMoved(in: window, at: NSPoint(x: point.x + 2, y: point.y))
        check(rowPixel().redComponent > 0.99, "Momentum must keep row hover suppressed")
        coordinator.scroll(in: window, at: point, phase: [], momentumPhase: .ended)
        coordinator.pointerMoved(in: window, at: point)
        check(rowPixel().redComponent > 0.99, "Stationary pointer must not restore row hover after momentum")
        coordinator.pointerMoved(in: window, at: NSPoint(x: point.x + 1, y: point.y))
        check(rowPixel().redComponent < 0.99, "Movement within the same row must restore hover")
        coordinator.viewportChanged(in: window, at: point)
        check(rowPixel().redComponent > 0.99, "Viewport movement must clear row hover")
        coordinator.pointerMoved(in: window, at: NSPoint(x: point.x + 1, y: point.y))
        row.isSelected = true
        let selected = rowPixel()
        coordinator.viewportChanged(in: window, at: point)
        let selectedCleared = rowPixel()
        check(abs(selected.redComponent - selectedCleared.redComponent) < 0.01 && selectedCleared.blueComponent > selectedCleared.redComponent, "Suppression must preserve blue row selection")
        row.isSelected = false
        coordinator.pointerMoved(in: window, at: NSPoint(x: point.x + 1, y: point.y))
        pane.tableView(table, didRemove: row, forRow: 0)
        check(rowPixel().redComponent > 0.99, "Removed row must reset helper hover")

        pane.setViewMode("icons")
        pane.view.layoutSubtreeIfNeeded()
        let collection = descendants(pane.view).first { $0 is NSCollectionView } as! NSCollectionView
        wait { collection.numberOfItems(inSection: 0) == 40 }
        collection.layoutSubtreeIfNeeded()
        guard let item = collection.item(at: IndexPath(item: 0, section: 0)) else { preconditionFailure("Actual icon item missing") }
        let tile = item.view
        tile.updateTrackingAreas()
        item.isSelected = false
        let tilePoint = tile.convert(NSPoint(x: tile.bounds.midX, y: tile.bounds.midY), to: nil)
        coordinator.pointerMoved(in: window, at: tilePoint)
        check((tile.layer?.backgroundColor?.alpha ?? 0) > 0.99, "Actual icon tile must hover through contentView hitTest")
        coordinator.scroll(in: window, at: tilePoint, phase: [], momentumPhase: [])
        check((tile.layer?.backgroundColor?.alpha ?? 1) == 0, "Scroll must clear icon hover")
        let movedTilePoint = NSPoint(x: tilePoint.x + 1, y: tilePoint.y)
        coordinator.pointerMoved(in: window, at: movedTilePoint)
        check((tile.layer?.backgroundColor?.alpha ?? 0) > 0.99, "Pointer movement within same icon tile must restore hover")
        coordinator.viewportChanged(in: window, at: movedTilePoint)
        check((tile.layer?.backgroundColor?.alpha ?? 1) == 0, "Viewport change must clear icon hover")
        coordinator.pointerMoved(in: window, at: tilePoint)
        item.isSelected = true
        let selectedTile = tile.layer!.backgroundColor!
        coordinator.viewportChanged(in: window, at: tilePoint)
        check(selectedTile == tile.layer!.backgroundColor!, "Suppression must preserve selected icon color")
        item.isSelected = false
        coordinator.pointerMoved(in: window, at: movedTilePoint)
        item.prepareForReuse()
        check((tile.layer?.backgroundColor?.alpha ?? 1) == 0, "Reused icon must reset helper hover")
        if failed > 0 { throw NSError(domain: "BrowserHoverRegression", code: failed, userInfo: [NSLocalizedDescriptionKey: "Failed \(failed) hover checks"]) }
        print("PASS: actual row/icon hit-testing, scroll and momentum suppression, stationary-pointer latch, movement restoration, selection priority, and reuse reset")
    }
}
