// Hidden integration regression. Compile with every MacFileManager source except main.swift,
// plus .build/debug/FileManagerCore.build/*.swift.o and -I .build/debug/Modules.
// Run from the project directory. Uses a named clipboard and disposable .build/qa fixtures;
// never changes the general clipboard, posts input, or displays a window.
import AppKit

private struct PasteShortcutFailure: Error, CustomStringConvertible { let description: String }

@main struct PasteShortcutRegression {
    static var checks = 0
    static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        checks += 1
        if try !condition() { throw PasteShortcutFailure(description: message) }
    }
    static func wait(_ label: String, until condition: () -> Bool) throws {
        let end = Date().addingTimeInterval(8)
        while !condition(), Date() < end { _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.015)) }
        try require(condition(), "Timed out: \(label)")
    }
    static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    static func main() {
        do { try run() }
        catch { FileHandle.standardError.write(Data("FAIL: \(error)\n".utf8)); exit(1) }
    }

    static func run() throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited); app.appearance = NSAppearance(named: .aqua)
        let manager = FileManager.default
        let originalDirectory = manager.currentDirectoryPath
        let fixture = URL(fileURLWithPath: originalDirectory).appendingPathComponent(".build/qa/paste-shortcut-" + UUID().uuidString, isDirectory: true)
        let sources = fixture.appendingPathComponent("Sources", isDirectory: true)
        let detailsDestination = fixture.appendingPathComponent("Details destination", isDirectory: true)
        let iconDestination = fixture.appendingPathComponent("Icon destination", isDirectory: true)
        let moveDestination = fixture.appendingPathComponent("Move destination", isDirectory: true)
        let restricted = fixture.appendingPathComponent("Read only", isDirectory: true)
        for folder in [sources, detailsDestination, iconDestination, moveDestination, restricted] {
            try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        let file = sources.appendingPathComponent("Report.txt")
        let folder = sources.appendingPathComponent("Project", isDirectory: true)
        let nested = folder.appendingPathComponent("notes.md")
        let cutSource = sources.appendingPathComponent("Cut source.txt")
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("Original report contents".utf8).write(to: file)
        try Data("# Original folder contents\n".utf8).write(to: nested)
        try Data("Cut intent must survive Paste shortcut".utf8).write(to: cutSource)
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        try require(manager.changeCurrentDirectoryPath(fixture.path), "Test settings must be isolated in a disposable project folder")
        defer {
            try? manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: restricted.path)
            manager.changeCurrentDirectoryPath(originalDirectory)
            try? manager.removeItem(at: fixture)
        }
        var settings = SavedSettings()
        settings.leftTabs = [detailsDestination.path]; settings.rightTabs = [sources.path]
        settings.preview = false; settings.singlePreview = false; settings.split = false
        AppStorage.save(settings)
        let main = MainWindowController(pasteboard: pasteboard)
        defer { main.close() }
        let pane = main.left
        guard let table = descendants(pane.view).first(where: { $0 is PaneFileTableView }) as? PaneFileTableView else {
            throw PasteShortcutFailure(description: "Missing actual browser table")
        }
        func contents(_ url: URL) -> Set<URL> {
            Set((try? manager.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? [])
        }
        func listing() -> Set<URL> {
            Set((0..<table.numberOfRows).compactMap { pane.tableView(table, pasteboardWriterForRow: $0) as? URL })
        }
        func navigate(_ url: URL) throws {
            pane.navigate(to: url)
            try wait("listing \(url.lastPathComponent)") { pane.currentURL == url && pane.canReceiveFiles && listing() == contents(url) }
            pane.view.layoutSubtreeIfNeeded()
        }
        func contextMenu(selecting selected: URL? = nil) throws -> NSMenu {
            pane.view.layoutSubtreeIfNeeded()
            let target: NSView
            let point: NSPoint
            if let selected {
                if pane.currentViewMode == "details" {
                    guard let row = (0..<table.numberOfRows).first(where: { (pane.tableView(table, pasteboardWriterForRow: $0) as? URL) == selected }) else {
                        throw PasteShortcutFailure(description: "Selected file not found in details")
                    }
                    target = table; point = NSPoint(x: 65, y: table.rect(ofRow: row).midY)
                } else {
                    guard let collection = descendants(pane.view).first(where: { $0 is PaneIconCollectionView }) as? PaneIconCollectionView else {
                        throw PasteShortcutFailure(description: "Missing actual icon collection")
                    }
                    collection.layoutSubtreeIfNeeded()
                    var selectedFrame: NSRect?
                    for section in 0..<collection.numberOfSections {
                        for item in 0..<collection.numberOfItems(inSection: section) {
                            let index = IndexPath(item: item, section: section)
                            if (pane.collectionView(collection, pasteboardWriterForItemAt: index) as? URL) == selected {
                                selectedFrame = collection.collectionViewLayout?.layoutAttributesForItem(at: index)?.frame
                            }
                        }
                    }
                    guard let frame = selectedFrame else { throw PasteShortcutFailure(description: "Selected icon has no layout frame") }
                    target = collection; point = NSPoint(x: frame.midX, y: frame.midY)
                }
            } else {
                guard let scroll = descendants(pane.view).compactMap({ $0 as? NSScrollView }).first(where: {
                    $0.documentView is PaneFileTableView || $0.documentView is PaneIconCollectionView
                }) else { throw PasteShortcutFailure(description: "Missing real file viewport") }
                target = scroll.contentView
                point = NSPoint(x: target.bounds.minX + 3, y: target.bounds.maxY - 6)
            }
            let event = NSEvent.mouseEvent(with: .rightMouseDown, location: target.convert(point, to: nil), modifierFlags: [], timestamp: 0,
                windowNumber: main.window!.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            guard let menu = target.menu(for: event) else { throw PasteShortcutFailure(description: "File viewport must forward a context menu") }
            pane.menuNeedsUpdate(menu)
            return menu
        }
        func item(_ title: String, in menu: NSMenu) throws -> NSMenuItem {
            guard let item = menu.item(withTitle: title) else { throw PasteShortcutFailure(description: "Missing menu item: \(title)") }
            return item
        }
        func send(_ item: NSMenuItem) throws {
            guard let action = item.action else { throw PasteShortcutFailure(description: "Missing action: \(item.title)") }
            try require(app.sendAction(action, to: item.target, from: item), "Menu action must route: \(item.title)")
        }
        guard let editMenu = NSApp.mainMenu?.item(withTitle: "Edit")?.submenu else { throw PasteShortcutFailure(description: "Missing Edit menu") }
        let editShortcut = try item("Paste shortcut", in: editMenu)
        func clipboardURLs() -> Set<URL> {
            Set((pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? [])
        }
        func aliases(in destination: URL) -> Set<URL> {
            Set(contents(destination).filter { AppShortcutDocument.isShortcut($0) })
        }
        func verifyAliases(_ urls: Set<URL>, targetURLs: Set<URL>) throws {
            var resolved = Set<URL>()
            for alias in urls {
                let info = try alias.resourceValues(forKeys: [.isAliasFileKey, .isSymbolicLinkKey, .isRegularFileKey])
                try require(AppShortcutDocument.isShortcut(alias) && info.isAliasFile != true && info.isRegularFile == true && info.isSymbolicLink != true, "Paste shortcut must create an app-owned shortcut document")
                let target = try AppShortcutDocument.resolve(alias)
                resolved.insert(target.standardizedFileURL)
            }
            try require(resolved == Set(targetURLs.map(\.standardizedFileURL)), "Created aliases must resolve to the copied originals")
        }
        func waitForAliases(in destination: URL, previous: Set<URL>, count: Int) throws -> Set<URL> {
            try wait("alias completion and selection") {
                let created = aliases(in: destination).subtracting(previous)
                return !main.hasRunningTransfers && created.count == count && Set(pane.selectedURLs) == created
            }
            let created = aliases(in: destination).subtracting(previous)
            try require(created.count == count && Set(pane.selectedURLs) == created, "Only aliases created by this paste must become selected")
            return created
        }

        try navigate(detailsDestination)
        pasteboard.clearContents()
        var menu = try contextMenu()
        try require(!(try item("Paste shortcut", in: menu)).isEnabled && !main.validateMenuItem(editShortcut), "Empty clipboard must disable context and Edit Paste shortcut")
        try send(item("Paste shortcut", in: menu))
        try require(!main.hasRunningTransfers && contents(detailsDestination).isEmpty, "Dispatching a disabled shortcut action must not create a job")
        pasteboard.clearContents(); pasteboard.setString("ordinary clipboard text", forType: .string)
        menu = try contextMenu()
        try require(!(try item("Paste shortcut", in: menu)).isEnabled && !main.validateMenuItem(editShortcut), "Text-only clipboard must disable Paste shortcut")

        try navigate(sources)
        pane.selectFiles([file, folder])
        try send(item("Copy", in: contextMenu(selecting: file)))
        let copiedURLs: Set<URL> = [file, folder]
        let copyChangeCount = pasteboard.changeCount
        try require(clipboardURLs() == copiedURLs, "Actual Copy must write the injected clipboard, including file and folder URLs")
        try navigate(detailsDestination)
        menu = try contextMenu()
        try require((try item("Paste shortcut", in: menu)).isEnabled && main.validateMenuItem(editShortcut), "Copied file URLs must enable Paste shortcut in an empty Details viewport")
        try send(item("Paste shortcut", in: menu))
        try require(main.hasRunningTransfers && !main.validateMenuItem(editShortcut), "Alias creation must count as running work and block a second job")
        pane.menuNeedsUpdate(menu)
        try require(!(try item("Paste shortcut", in: menu)).isEnabled, "Context Paste shortcut must also be disabled while its job is active")
        let firstAliases = try waitForAliases(in: detailsDestination, previous: [], count: 2)
        try verifyAliases(firstAliases, targetURLs: copiedURLs)
        try require(Set(firstAliases.map(\.lastPathComponent)) == ["Report.txt - Shortcut.fmlink", "Project - Shortcut.fmlink"],
                    "First paste must use Name - Shortcut with the internal document extension")
        let nameColumn = table.tableColumns.first { $0.identifier.rawValue == "name" }!
        let shownNames = Set((0..<table.numberOfRows).compactMap { row -> String? in
            guard let url = pane.tableView(table, pasteboardWriterForRow: row) as? URL, firstAliases.contains(url) else { return nil }
            return (pane.tableView(table, viewFor: nameColumn, row: row) as? NSTableCellView)?.textField?.stringValue
        })
        try require(shownNames == ["Report.txt - Shortcut", "Project - Shortcut"],
                    "The actual Details name cells must hide .fmlink while retaining the original file extension")
        try require(pasteboard.changeCount == copyChangeCount && clipboardURLs() == copiedURLs, "Paste shortcut must preserve copied clipboard contents")
        try send(editShortcut)
        let secondAliases = try waitForAliases(in: detailsDestination, previous: firstAliases, count: 2)
        try verifyAliases(secondAliases, targetURLs: copiedURLs)
        try require(Set(secondAliases.map(\.lastPathComponent)) == ["Report.txt - Shortcut (2).fmlink", "Project - Shortcut (2).fmlink"],
                    "Repeated paste must number duplicates as Name - Shortcut (2) before the internal extension")
        try require(firstAliases.isDisjoint(with: secondAliases) && aliases(in: detailsDestination).count == 4, "Repeated pastes must choose new names without overwriting earlier aliases")

        let child = detailsDestination.appendingPathComponent("Selected child", isDirectory: true)
        try manager.createDirectory(at: child, withIntermediateDirectories: true)
        pane.reload(); try wait("child-folder listing") { listing().contains(child) }
        pane.selectFiles([child])
        menu = try contextMenu(selecting: child)
        try require(pane.selectedURLs == [child], "Right-click must retain the selected child folder")
        let beforeChildPaste = aliases(in: detailsDestination)
        try send(item("Paste shortcut", in: menu))
        let childPaste = try waitForAliases(in: detailsDestination, previous: beforeChildPaste, count: 2)
        try verifyAliases(childPaste, targetURLs: copiedURLs)
        try require(contents(child).isEmpty, "Paste shortcut must target the current folder rather than a selected child folder")

        try navigate(iconDestination); pane.setViewMode("mediumIcons"); pane.view.layoutSubtreeIfNeeded()
        menu = try contextMenu()
        try require((try item("Paste shortcut", in: menu)).isEnabled, "Empty icon viewport must forward an enabled Paste shortcut menu")
        try send(item("Paste shortcut", in: menu))
        let iconAliases = try waitForAliases(in: iconDestination, previous: [], count: 2)
        try verifyAliases(iconAliases, targetURLs: copiedURLs)
        try require(pasteboard.changeCount == copyChangeCount && clipboardURLs() == copiedURLs, "Repeated details/icon pastes must not consume Copy clipboard data")

        pane.showThisMac(); pane.menuNeedsUpdate(menu)
        try require(!(try item("Paste shortcut", in: menu)).isEnabled && !main.validateMenuItem(editShortcut), "This Mac must not accept shortcut files")
        pane.showRecents(); pane.menuNeedsUpdate(menu)
        try require(!(try item("Paste shortcut", in: menu)).isEnabled && !main.validateMenuItem(editShortcut), "Recents must not accept shortcut files")
        if geteuid() != 0 {
            try manager.setAttributes([.posixPermissions: 0o500], ofItemAtPath: restricted.path)
            try navigate(restricted)
            menu = try contextMenu()
            try require(!(try item("Paste shortcut", in: menu)).isEnabled && !main.validateMenuItem(editShortcut), "A readable but unwritable current folder must disable Paste shortcut")
            try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: restricted.path)
        }
        try require(try String(contentsOf: file, encoding: .utf8) == "Original report contents" && String(contentsOf: nested, encoding: .utf8) == "# Original folder contents\n", "Copy-based shortcut creation must leave file and folder contents untouched")

        try navigate(sources); pane.setViewMode("details"); pane.selectFiles([cutSource])
        try send(item("Cut", in: contextMenu(selecting: cutSource)))
        let cutChangeCount = pasteboard.changeCount
        try require(clipboardURLs() == [cutSource], "Actual Cut must place the selected source on the private clipboard")
        try navigate(iconDestination)
        let beforeCutPaste = aliases(in: iconDestination)
        try send(item("Paste shortcut", in: contextMenu()))
        let cutAliases = try waitForAliases(in: iconDestination, previous: beforeCutPaste, count: 1)
        try verifyAliases(cutAliases, targetURLs: [cutSource])
        try require(manager.fileExists(atPath: cutSource.path) && pasteboard.changeCount == cutChangeCount && clipboardURLs() == [cutSource],
                    "Pasting a shortcut after Cut must neither move the original nor consume its clipboard entry")
        try navigate(moveDestination)
        table.paste(nil) // Actual native browser responder routes ordinary Paste to Main.
        try wait("normal Paste after shortcut") { !main.hasRunningTransfers && !manager.fileExists(atPath: cutSource.path) }
        let moved = moveDestination.appendingPathComponent(cutSource.lastPathComponent)
        try require(try String(contentsOf: moved, encoding: .utf8) == "Cut intent must survive Paste shortcut", "A subsequent normal Paste must still move the Cut source intact")
        try require(manager.fileExists(atPath: file.path) && manager.fileExists(atPath: nested.path), "Other copied originals must survive all integration actions")
        try require(!main.hasRunningTransfers, "The integration harness must leave no in-flight jobs")
        print("PASS: \(checks) Paste shortcut integration checks covering named-clipboard isolation, real Details/icon context and Edit actions, aliases and selection, unique repeats, current-folder targeting, unavailable destinations, and preserved Copy/Cut intent")
    }
}
