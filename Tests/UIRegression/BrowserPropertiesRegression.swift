// Headless AppKit regression harness. Run from the project directory:
// xcrun swiftc -swift-version 5 Sources/MacFileManager/AppSupport.swift Sources/MacFileManager/ThisMacViewController.swift Sources/MacFileManager/BrowserPaneViewController.swift Sources/MacFileManager/ShortcutSupport.swift \
//   Tests/UIRegression/BrowserPropertiesRegression.swift -o .build/qa/browser-properties-regression
// .build/qa/browser-properties-regression
// Calls menu(for:) and keyDown directly in an undisplayed window; posts no input.
import AppKit

private struct PropertiesRegressionFailure: Error, CustomStringConvertible {
    let description: String
}

@main struct BrowserPropertiesRegression {
    static func main() throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        app.appearance = NSAppearance(named: .aqua)
        func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            if !condition() { throw PropertiesRegressionFailure(description: message) }
        }
        func descendants(_ view: NSView) -> [NSView] { view.subviews + view.subviews.flatMap(descendants) }
        let manager = FileManager.default
        let fixtures = URL(fileURLWithPath: manager.currentDirectoryPath).appendingPathComponent(".build/qa/properties-fixtures-\(UUID().uuidString)")
        try manager.createDirectory(at: fixtures, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: fixtures) }
        let urls = ["alpha.txt", "beta.txt", "gamma.txt"].map { fixtures.appendingPathComponent($0) }
        for url in urls { try Data(url.lastPathComponent.utf8).write(to: url) }
        let pane = BrowserPaneViewController(url: fixtures)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = pane.view
        window.orderOut(nil)
        defer { window.close() }
        let table = descendants(pane.view).first { $0 is NSTableView } as! NSTableView
        var targets: [[URL]] = []
        var lastSelection: [URL] = []
        var status = ""
        var unexpectedActions = 0
        pane.onSelectionChange = { lastSelection = $0 }
        pane.onStatusChange = { status = $0 }
        pane.onRequestAction = { action in
            if case .properties = action {
                targets.append(pane.selectedURLs.isEmpty ? [pane.currentURL] : pane.selectedURLs)
            } else { unexpectedActions += 1 }
        }
        let deadline = Date().addingTimeInterval(5)
        while table.numberOfRows != 3 && Date() < deadline { _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
        try require(table.numberOfRows == 3, "Fixture directory must load")
        pane.view.layoutSubtreeIfNeeded()
        func contextMenu(in view: NSView, at localPoint: NSPoint) throws -> NSMenu {
            let point = view.convert(localPoint, to: nil)
            let event = NSEvent.mouseEvent(with: .rightMouseDown, location: point, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            guard let menu = view.menu(for: event) else { throw PropertiesRegressionFailure(description: "Missing context menu") }
            pane.menuNeedsUpdate(menu)
            try require(menu.items.last?.title == "Properties…", "Properties must be the last context-menu item")
            try require(menu.items.dropLast().last?.isSeparatorItem == true, "Properties must have its own final group")
            return menu
        }
        func chooseProperties(_ menu: NSMenu) throws {
            let item = menu.items.last!
            try require(item.isEnabled, "Properties must be enabled for real targets")
            try require(app.sendAction(item.action!, to: item.target, from: item), "Properties action must be routed")
        }
        pane.selectFiles(Array(urls.prefix(2)))
        let selectedRow = table.selectedRowIndexes.first!
        var menu = try contextMenu(in: table, at: NSPoint(x: 60, y: table.rect(ofRow: selectedRow).midY))
        try require(Set(pane.selectedURLs) == Set(urls.prefix(2)), "Right-click inside detail selection must preserve multiple files")
        try chooseProperties(menu)
        try require(Set(targets.last!) == Set(urls.prefix(2)), "Properties must receive the selected detail files")
        menu = try contextMenu(in: table, at: NSPoint(x: 60, y: table.rect(ofRow: 2).midY))
        try require(pane.selectedURLs == [urls[2]], "Right-click an unselected detail row must select that file")
        let background = NSPoint(x: 60, y: table.rect(ofRow: 2).maxY + 30)
        try require(table.row(at: background) == -1, "Fixture background must be below the rows")
        menu = try contextMenu(in: table, at: background)
        try require(pane.selectedURLs.isEmpty && lastSelection.isEmpty, "Right-click detail background must clear stale selection and notify")
        try chooseProperties(menu)
        try require(targets.last == [fixtures], "Background Properties must target the current folder")
        try require(pane.currentURL == fixtures, "Context menu must not navigate")

        pane.setViewMode("icons")
        pane.view.layoutSubtreeIfNeeded()
        let collection = descendants(pane.view).first { $0 is NSCollectionView } as! NSCollectionView
        collection.layoutSubtreeIfNeeded()
        pane.selectFiles(Array(urls.prefix(2)))
        let selectedIndex = collection.selectionIndexPaths.sorted { $0.item < $1.item }.first!
        guard let item = collection.item(at: selectedIndex) else { throw PropertiesRegressionFailure(description: "Missing visible icon item") }
        let selectedPoint = collection.convert(NSPoint(x: item.view.bounds.midX, y: item.view.bounds.midY), from: item.view)
        menu = try contextMenu(in: collection, at: selectedPoint)
        try require(Set(pane.selectedURLs) == Set(urls.prefix(2)), "Right-click inside icon selection must preserve multiple files")
        try chooseProperties(menu)
        try require(Set(targets.last!) == Set(urls.prefix(2)), "Properties must receive selected icon files")
        let iconBackground = NSPoint(x: 2, y: 2)
        try require(collection.indexPathForItem(at: iconBackground) == nil, "Fixture icon background must be outside tiles")
        menu = try contextMenu(in: collection, at: iconBackground)
        try require(pane.selectedURLs.isEmpty && lastSelection.isEmpty, "Right-click icon background must clear stale selection and notify")
        try chooseProperties(menu)
        try require(targets.last == [fixtures], "Icon background Properties must target the current folder")
        pane.setViewMode("details")
        try require(pane.selectedURLs.isEmpty, "Background deselection must survive changing view modes")

        func press(_ key: String, code: UInt16, modifiers: NSEvent.ModifierFlags) {
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: key, charactersIgnoringModifiers: key, isARepeat: false, keyCode: code)!
            table.keyDown(with: event)
        }
        pane.selectFiles([urls[0]])
        let beforeKeys = targets.count
        press("\r", code: 36, modifiers: .option)
        press("\r", code: 76, modifiers: .option)
        press("i", code: 34, modifiers: .command)
        press("i", code: 34, modifiers: .control)
        try require(targets.count == beforeKeys + 4 && targets.suffix(4).allSatisfy { $0 == [urls[0]] }, "Option-Return/keypad Enter and Command/Control-I must route Properties")
        try require(unexpectedActions == 0, "Properties shortcuts must not invoke other browser actions")
        try require(pane.currentURL == fixtures, "Properties shortcuts must not navigate")
        pane.showRecents()
        pane.selectFiles([])
        pane.menuNeedsUpdate(menu)
        try require(menu.items.last?.isEnabled == false, "Empty Recents selection must disable Properties")
        let beforeRecents = targets.count
        press("\r", code: 36, modifiers: .option)
        app.sendAction(menu.items.last!.action!, to: menu.items.last!.target, from: nil)
        try require(targets.count == beforeRecents, "Empty Recents must not request folder Properties even through direct action dispatch")

        func waitFor(_ description: String, until condition: () -> Bool) throws {
            let deadline = Date().addingTimeInterval(5)
            while (!condition() || status.contains("Loading") || status.contains("Searching")) && Date() < deadline {
                _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
            }
            try require(condition() && !status.contains("Loading") && !status.contains("Searching"), "Timed out: \(description)")
        }
        func chooseTab(named name: String) throws {
            guard let button = descendants(pane.tabsView).compactMap({ $0 as? NSButton }).first(where: { $0.title == name }) else {
                throw PropertiesRegressionFailure(description: "Missing tab \(name)")
            }
            try require(app.sendAction(button.action!, to: button.target, from: button), "Tab selection must be routed")
        }
        let source = fixtures.appendingPathComponent("Folder", isDirectory: true)
        let child = source.appendingPathComponent("subfolder", isDirectory: true)
        let deep = child.appendingPathComponent("deep", isDirectory: true)
        let sibling = fixtures.appendingPathComponent("Folder-other", isDirectory: true)
        let destination = fixtures.appendingPathComponent("Renamed Folder", isDirectory: true)
        let movedChild = destination.appendingPathComponent("subfolder", isDirectory: true)
        let movedDeep = movedChild.appendingPathComponent("deep", isDirectory: true)
        let keep = source.appendingPathComponent("keep.txt")
        let inside = child.appendingPathComponent("inside.txt")
        try manager.createDirectory(at: deep, withIntermediateDirectories: true)
        try manager.createDirectory(at: sibling, withIntermediateDirectories: true)
        try Data("root selection".utf8).write(to: keep)
        try Data("nested selection".utf8).write(to: inside)
        pane.restoreTabs([source])
        // Keep relocation assertions focused on current-folder filtering and
        // selection. Indexed recursive search has its own integration suite.
        let directScope = NSMenuItem()
        directScope.tag = 0
        app.sendAction(NSSelectorFromString("searchScopeSelected:"), to: pane, from: directScope)
        pane.navigate(to: child)
        pane.navigate(to: source)
        try waitFor("source history", until: { table.numberOfRows == 2 })
        let search = descendants(pane.view).first { $0 is NSSearchField } as! NSSearchField
        search.stringValue = "keep"
        app.sendAction(search.action!, to: search.target, from: search)
        pane.setSort(key: "size", ascending: false)
        pane.selectFiles([keep])
        pane.addTab(url: child)
        pane.navigate(to: deep)
        pane.navigate(to: sibling)
        pane.addTab(url: child)
        try waitFor("active nested tab", until: { table.numberOfRows == 2 })
        search.stringValue = "inside"
        app.sendAction(search.action!, to: search.target, from: search)
        pane.setSort(key: "type", ascending: false)
        pane.setViewMode("icons")
        pane.selectFiles([inside])

        try manager.moveItem(at: source, to: destination)
        pane.relocateAfterMove(from: source, to: destination)
        let movedInside = movedChild.appendingPathComponent("inside.txt")
        try waitFor("renamed active subfolder", until: { pane.selectedURLs == [movedInside] })
        try require(pane.currentURL == movedChild && pane.selectedTabIndex == 2, "Renaming an ancestor must relocate the active subfolder without changing tab index")
        try require(pane.openDirectories == [destination, sibling, movedChild], "All matching tabs must relocate while a sibling sharing the old name prefix stays unchanged")
        try require(search.stringValue == "inside" && pane.currentSortKey == "type" && !pane.currentSortAscending && pane.currentViewMode == "mediumIcons", "Relocation must retain query, sort and view mode")

        try chooseTab(named: destination.lastPathComponent)
        let movedKeep = destination.appendingPathComponent("keep.txt")
        try waitFor("background folder selection", until: { pane.selectedURLs == [movedKeep] })
        try require(pane.currentURL == destination && search.stringValue == "keep" && pane.currentSortKey == "size" && !pane.currentSortAscending, "The renamed folder tab must retain its own selection and options")
        pane.goBack()
        try require(pane.currentURL == movedChild, "Back history must relocate descendants")
        pane.goBack()
        try require(pane.currentURL == destination, "Back history must relocate the source folder itself")
        pane.goBack()
        try require(pane.currentURL == destination, "Relocation must not insert an extra history entry")

        try chooseTab(named: sibling.lastPathComponent)
        try require(pane.currentURL == sibling, "Unrelated current folder must not be relocated by a string-prefix match")
        pane.goBack()
        try require(pane.currentURL == movedDeep, "A background tab's history must relocate even when its current folder was unaffected")
        pane.goBack()
        try require(pane.currentURL == movedChild, "Earlier background history must relocate too")
        try manager.moveItem(at: destination, to: source)
        pane.relocateAfterMove(from: destination, to: source)
        try require(pane.currentURL == child, "Undo relocation must restore the current folder path")
        pane.goForward()
        try require(pane.currentURL == deep, "Undo relocation must restore forward history")
        pane.goForward()
        try require(pane.currentURL == sibling, "Undo relocation must leave prefix-sharing siblings unchanged")

        pane.navigate(to: source)
        try waitFor("parent folder before file rename", until: { table.numberOfRows == 2 })
        pane.selectFiles([keep])
        let renamedFile = source.appendingPathComponent("renamed-keep.txt")
        try manager.moveItem(at: keep, to: renamedFile)
        pane.relocateAfterMove(from: keep, to: renamedFile)
        try waitFor("renamed file selection", until: { pane.selectedURLs == [renamedFile] })
        try require(pane.currentURL == source, "Relocating a file selection must not change its parent folder")
        print("PASS: context targets, Properties shortcuts, Recents guard, folder/file relocation, background histories, path boundaries and undo")
    }
}
