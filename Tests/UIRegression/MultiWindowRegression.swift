// Hidden integration checks; compile with every MacFileManager source except main.swift,
// -I .build/debug/Modules, and .build/debug/FileManagerCore.build/*.swift.o.
// All settings, file operations, and clipboard changes use disposable fixtures.
import AppKit

private struct MultiWindowFailure: Error, CustomStringConvertible { let description: String }

@main struct MultiWindowRegression {
    static func main() {
        do { try run() }
        catch { FileHandle.standardError.write(Data("FAIL: \(error)\n".utf8)); exit(1) }
    }

    private static func run() throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        app.appearance = NSAppearance(named: .aqua)
        let manager = FileManager.default
        let originalDirectory = manager.currentDirectoryPath
        let fixture = URL(fileURLWithPath: originalDirectory).appendingPathComponent(".build/qa/multi-window-\(UUID().uuidString)")
        let sourceFolder = fixture.appendingPathComponent("Source", isDirectory: true)
        let destinationFolder = fixture.appendingPathComponent("Destination", isDirectory: true)
        let otherFolder = fixture.appendingPathComponent("Other", isDirectory: true)
        let staleFolder = fixture.appendingPathComponent("Previously restored", isDirectory: true)
        for folder in [sourceFolder, destinationFolder, otherFolder, staleFolder] {
            try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        let moveSource = sourceFolder.appendingPathComponent("Move.txt")
        let copySource = sourceFolder.appendingPathComponent("Copy.txt")
        let closeSource = sourceFolder.appendingPathComponent("After source window closes.txt")
        for url in [moveSource, copySource, closeSource] { try Data("Contents of \(url.lastPathComponent)".utf8).write(to: url) }
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        guard manager.changeCurrentDirectoryPath(fixture.path) else { throw MultiWindowFailure(description: "Could not isolate settings") }
        defer { manager.changeCurrentDirectoryPath(originalDirectory); try? manager.removeItem(at: fixture) }
        var checks = 0
        func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            checks += 1
            if !condition() { throw MultiWindowFailure(description: message) }
        }
        func wait(_ description: String, until condition: () -> Bool) throws {
            let deadline = Date().addingTimeInterval(10)
            while !condition() && Date() < deadline { _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
            try require(condition(), "Timed out: \(description)")
        }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        func table(_ pane: BrowserPaneViewController) throws -> NSTableView {
            guard let table = descendants(pane.view).first(where: { $0.identifier?.rawValue == "browser.files" }) as? NSTableView else {
                throw MultiWindowFailure(description: "Missing actual browser table")
            }
            return table
        }
        func listing(_ pane: BrowserPaneViewController) -> Set<URL> {
            guard let table = try? table(pane) else { return [] }
            return Set((0..<table.numberOfRows).compactMap { pane.tableView(table, pasteboardWriterForRow: $0) as? URL })
        }
        func send(_ selector: String, to controller: MainWindowController) throws {
            try require(app.sendAction(NSSelectorFromString(selector), to: controller, from: nil), "Connected action: \(selector)")
        }
        func menu(_ path: [String]) throws -> NSMenuItem {
            var current = app.mainMenu
            for (index, title) in path.enumerated() {
                guard let item = current?.items.first(where: { $0.title == title }) else { throw MultiWindowFailure(description: "Missing menu \(path)") }
                if index == path.count - 1 { return item }
                current = item.submenu
            }
            throw MultiWindowFailure(description: "Empty menu path")
        }
        func send(_ item: NSMenuItem) throws {
            guard let action = item.action else { throw MultiWindowFailure(description: "Missing menu action") }
            try require(app.sendAction(action, to: item.target, from: item), "Connected menu: \(item.title)")
        }
        var initial = SavedSettings()
        initial.leftTabs = [staleFolder.path, BrowserPaneViewController.thisMacURL.absoluteString]
        initial.rightTabs = [otherFolder.path, staleFolder.path]
        initial.leftSelectedTab = 1; initial.rightSelectedTab = 1
        initial.activeRightPane = true; initial.split = true
        initial.preview = false; initial.singlePreview = false
        AppStorage.save(initial)
        let source = MainWindowController(pasteboard: pasteboard, initialURL: sourceFolder, restoresSession: false)
        let destination = MainWindowController(pasteboard: pasteboard, initialURL: destinationFolder, restoresSession: false)
        var sourceClosed = 0, destinationClosed = 0
        source.onClosed = { sourceClosed += 1 }
        destination.onClosed = { destinationClosed += 1 }
        var designatedOwner = source
        source.shouldPersistState = { designatedOwner === source }
        destination.shouldPersistState = { designatedOwner === destination }
        defer { if sourceClosed == 0 { source.close() }; if destinationClosed == 0 { destination.close() } }
        try require(source.left.openDirectories == [sourceFolder] && source.right.openDirectories == [sourceFolder], "An explicit new window must not restore old tabs in either pane")
        try require(destination.left.openDirectories == [destinationFolder] && destination.right.openDirectories == [destinationFolder], "Second window must use its own requested initial folder")
        try require(source.activePane === source.left && destination.activePane === destination.left, "New windows must not inherit saved right-pane focus")
        try wait("source listing") { listing(source.left) == [moveSource, copySource, closeSource] }
        try wait("destination listing") { destination.left.canReceiveFiles }

        source.activateMenus()
        let newTabA = try menu(["File", "New Tab"])
        try require(newTabA.target as? MainWindowController === source, "Source activation must retarget global menus")
        try send(newTabA)
        try require(source.left.openDirectories.count == 2 && destination.left.openDirectories.count == 1, "A menu action must mutate only its owner window tabs")
        source.left.closeCurrentTab()
        destination.activateMenus()
        let newTabB = try menu(["File", "New Tab"])
        try require(newTabB.target as? MainWindowController === destination, "Destination activation must retarget global menus")
        try send(newTabB)
        try require(destination.left.openDirectories.count == 2 && source.left.openDirectories.count == 1, "Retargeted New Tab must leave source tabs alone")
        destination.left.closeCurrentTab()
        var requestedWindows: [URL?] = []
        destination.onOpenNewWindow = { requestedWindows.append($0) }
        try send(menu(["File", "New Window"]))
        try require(requestedWindows.count == 1, "New Window menu must use the application callback")
        destination.left.onOpenFolderWindow?(otherFolder)
        try require(requestedWindows.count == 2 && requestedWindows.last! == otherFolder, "Open folder in new window must forward its actual folder")

        // Background navigation must not overwrite the designated window's saved session.
        source.persistState()
        let savedSource = AppStorage.load().leftTabs
        destination.left.navigate(to: otherFolder)
        destination.persistState()
        try require(AppStorage.load().leftTabs == savedSource, "Background window persistence must not replace the active saved session")
        designatedOwner = destination
        destination.persistState()
        try require(AppStorage.load().leftTabs == [otherFolder.path], "Changing persistence owner must save that window's session")
        source.activateMenus()
        try send(menu(["View", "Compact view"]))
        try require(AppStorage.load().explorer.compactView, "Preferences applied from another window must be persisted by the designated session owner")
        destination.activateMenus()
        let compactB = try menu(["View", "Compact view"])
        _ = destination.validateMenuItem(compactB)
        try require(compactB.state == .on, "Global preference changes must reach other existing windows")
        destination.left.navigate(to: destinationFolder)
        try wait("destination ready") { destination.left.canReceiveFiles && destination.left.currentURL == destinationFolder }
        try wait("source ready after tab change") { listing(source.left).contains(moveSource) }

        source.left.selectFiles([moveSource])
        try send("cutAction", to: source)
        let clipboard = FileClipboardState.shared(for: pasteboard)
        try require(clipboard.isCut && clipboard.urls == [moveSource], "Cut intent must be stored with the shared clipboard")
        try send("pasteAction", to: destination)
        try require(destination.hasRunningTransfers && !clipboard.runningCutChanges.isEmpty, "Cross-window paste must reserve the current Cut before processing callbacks")
        // This must be rejected immediately, even in a different window with its own engine.
        source.left.navigate(to: otherFolder)
        try send("pasteAction", to: source)
        try require(!source.hasRunningTransfers, "Duplicate Cut paste must be blocked across windows")
        try wait("cross-window move") { !destination.hasRunningTransfers }
        let moved = destinationFolder.appendingPathComponent(moveSource.lastPathComponent)
        try require(!manager.fileExists(atPath: moveSource.path) && manager.fileExists(atPath: moved.path), "Cut in one window and Paste in another must move the source")
        try require(!manager.fileExists(atPath: otherFolder.appendingPathComponent(moveSource.lastPathComponent).path), "Rejected duplicate paste must not create another destination")
        try require(!clipboard.isCut && clipboard.urls.isEmpty && clipboard.runningCutChanges.isEmpty, "Successful move must clear shared Cut state and reservation")

        source.left.navigate(to: sourceFolder)
        try wait("copy source listing") { listing(source.left).contains(copySource) }
        source.left.selectFiles([copySource])
        try send("copyAction", to: source)
        let copyChange = pasteboard.changeCount
        try send("pasteAction", to: destination)
        try wait("cross-window copy") { !destination.hasRunningTransfers }
        let copied = destinationFolder.appendingPathComponent(copySource.lastPathComponent)
        let copiedData = try Data(contentsOf: copied), originalData = try Data(contentsOf: copySource)
        try require(copiedData == originalData && manager.fileExists(atPath: copySource.path), "Copy across windows must preserve the original and bytes")
        try require(!clipboard.isCut && pasteboard.changeCount == copyChange, "Copy paste must not consume or turn the clipboard into a Cut")

        // Closing the source window must preserve clipboard intent for remaining windows.
        source.left.selectFiles([closeSource])
        try send("cutAction", to: source)
        try require(source.windowShouldClose(source.window!), "An idle window must close independently")
        source.close()
        try require(sourceClosed == 1 && destinationClosed == 0, "Closing one window must leave other window controllers alive")
        try require(clipboard.isCut && clipboard.urls == [closeSource], "Cut state must survive closing the source window")
        try send("pasteAction", to: destination)
        try wait("cut after source window close") { !destination.hasRunningTransfers }
        try require(!manager.fileExists(atPath: closeSource.path) && manager.fileExists(atPath: destinationFolder.appendingPathComponent(closeSource.lastPathComponent).path), "A remaining window must complete Cut from a closed source window")

        // Another app replacing the pasteboard must invalidate app-owned Cut intent.
        destination.left.reload()
        try wait("moved listing") { listing(destination.left).contains(moved) }
        destination.left.selectFiles([moved])
        try send("cutAction", to: destination)
        pasteboard.clearContents(); pasteboard.writeObjects([copied as NSURL])
        destination.left.navigate(to: otherFolder)
        try wait("external copy destination") { destination.left.canReceiveFiles && destination.left.currentURL == otherFolder }
        try send("pasteAction", to: destination)
        try wait("external clipboard copy") { !destination.hasRunningTransfers }
        try require(manager.fileExists(atPath: copied.path) && manager.fileExists(atPath: otherFolder.appendingPathComponent(copySource.lastPathComponent).path), "Replacing the pasteboard must make subsequent Paste copy rather than reuse stale Cut intent")
        try require(!clipboard.isCut, "External clipboard replacement must clear shared Cut state")
        print("PASS: \(checks) hidden multi-window tab, menu, persistence, clipboard and close checks")
    }
}
