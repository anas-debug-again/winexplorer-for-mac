// Hidden-window integration checks. All files and settings stay in disposable project fixtures.
// Compile with all MacFileManager sources except main.swift and the FileManagerCore objects.
import AppKit

private struct IntegrationFailure: Error, CustomStringConvertible { let description: String }

@main struct ExplorerIntegrationRegression {
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
        let fixture = URL(fileURLWithPath: originalDirectory).appendingPathComponent(".build/qa/explorer-integration-\(UUID().uuidString)")
        let a = fixture.appendingPathComponent("A", isDirectory: true)
        let b = fixture.appendingPathComponent("B", isDirectory: true)
        let destination = fixture.appendingPathComponent("Sent", isDirectory: true)
        for url in [a, b, destination] { try manager.createDirectory(at: url, withIntermediateDirectories: true) }
        let source = a.appendingPathComponent("sample.txt")
        try Data("Send to must copy this intact".utf8).write(to: source)
        try Data("Hidden".utf8).write(to: a.appendingPathComponent(".hidden"))
        manager.changeCurrentDirectoryPath(fixture.path)
        defer { manager.changeCurrentDirectoryPath(originalDirectory); try? manager.removeItem(at: fixture) }
        var checks = 0
        func require(_ condition: Bool, _ message: String) throws {
            checks += 1
            if !condition { throw IntegrationFailure(description: message) }
        }
        func wait(_ label: String, until condition: () -> Bool) throws {
            let deadline = Date().addingTimeInterval(8)
            while !condition() && Date() < deadline { _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02)) }
            try require(condition(), "Timed out: \(label)")
        }
        func menu(_ path: [String]) throws -> NSMenuItem {
            var current = NSApp.mainMenu
            for (index, title) in path.enumerated() {
                guard let item = current?.items.first(where: { $0.title == title }) else { throw IntegrationFailure(description: "Missing menu \(path)") }
                if index == path.count - 1 { return item }
                current = item.submenu
            }
            throw IntegrationFailure(description: "Empty menu path")
        }
        func send(_ item: NSMenuItem) throws {
            guard let action = item.action else { throw IntegrationFailure(description: "Missing action for \(item.title)") }
            try require(app.sendAction(action, to: item.target, from: item), "Action \(item.title) must be connected")
        }
        func table(in pane: BrowserPaneViewController) throws -> NSTableView {
            func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
            guard let table = descendants(pane.view).first(where: { $0.identifier?.rawValue == "browser.files" }) as? NSTableView else { throw IntegrationFailure(description: "Missing browser table") }
            return table
        }
        var initial = SavedSettings()
        initial.leftTabs = [a.path, BrowserPaneViewController.thisMacURL.absoluteString]
        initial.rightTabs = [b.path]
        initial.leftSelectedTab = 1
        initial.split = true
        initial.preview = false
        var leftDisplay = BrowserTabDisplaySettings()
        leftDisplay.viewMode = "tiles"; leftDisplay.groupBy = "type"
        initial.leftDisplay = [leftDisplay, BrowserTabDisplaySettings()]
        var rightDisplay = BrowserTabDisplaySettings()
        rightDisplay.viewMode = "list"; rightDisplay.groupBy = "size"
        initial.rightDisplay = [rightDisplay]
        AppStorage.save(initial)
        do {
            let main = MainWindowController()
            defer { main.close() }
            var didUndoFile = false
            main.fileUndo.registerUndo(withTarget: main) { _ in didUndoFile = true }
            let undo = try menu(["Edit", "Undo File Operation"])
            try require(!main.validateMenuItem(undo), "Inactive main window must not offer file Undo")
            try send(undo)
            try require(!didUndoFile, "Undo must not fall through to file operations without main-window focus")
            main.fileUndo.removeAllActions()
            try require(main.activePane === main.left && main.left.isShowingThisMac, "Saved This Mac tab must restore as a virtual location")
            try require(main.left.openDirectories == [a, BrowserPaneViewController.thisMacURL], "Virtual and file URLs must remain distinct")
            try require(main.right.currentViewMode == "list" && main.right.currentGroupBy == "size", "Right pane display must restore independently")
            try require(!main.validateMenuItem(try menu(["File", "New Folder…"])), "This Mac must disable folder creation")
            try require(!main.validateMenuItem(try menu(["File", "Properties…"])), "This Mac must not target a fake filesystem URL")
            try require(!main.validateMenuItem(try menu(["File", "Send to", "Desktop (create shortcut)"])), "Send to needs actual selected files")
            try require(!main.validateMenuItem(try menu(["View", "Group by", "Name"])), "Grouping must be unavailable in drive overview")
            main.left.navigate(to: a)
            let fileTable = try table(in: main.left)
            try wait("fixture listing", until: { fileTable.numberOfRows == 1 })
            main.left.selectFiles([source])
            try require(main.validateMenuItem(try menu(["File", "Send to", "Desktop (create shortcut)"])), "A file selection must enable Desktop shortcut")
            try send(menu(["View", "Group by", "Type"]))
            try require(main.left.currentGroupBy == "type" && main.left.selectedURLs == [source], "Group menu must retain actual file selection")
            for (_, title) in ExplorerPreferences.viewModes {
                let item = try menu(["View", "Layout", title])
                try send(item)
                try require(main.left.currentViewMode == item.representedObject as? String && main.left.selectedURLs == [source], "\(title) must preserve the selected file")
            }
            try require(main.right.currentViewMode == "list" && main.right.currentGroupBy == "size", "Changing left pane must not alter right pane")
            try send(menu(["View", "Compact view"]))
            try send(menu(["View", "File name extensions"]))
            try send(menu(["View", "Show Hidden Files"]))
            try wait("hidden file preference", until: { fileTable.numberOfRows >= 3 }) // group headers plus two files
            main.left.selectAllFiles()
            try require(main.left.selectedURLs.count == 2, "Hidden file preference must show both real entries")
            let saved = AppStorage.load()
            try require(saved.explorer.compactView && !saved.explorer.showFileExtensions && saved.explorer.showHiddenFiles, "View menu preferences must persist")
            try require(saved.leftDisplay.last?.viewMode == "tiles" && saved.leftDisplay.last?.groupBy == "type", "Per-tab presentation must persist through callbacks")
            try require(saved.rightDisplay.first?.viewMode == "list", "Saving left display must retain right display")

            // Exercise the exact Send to destination action with a project-local destination.
            let copy = try menu(["File", "Send to", "Documents"])
            copy.representedObject = destination
            main.left.selectFiles([source])
            try send(copy)
            try wait("Send to copy completion", until: { !main.hasRunningTransfers })
            try require(manager.fileExists(atPath: source.path), "Send to must retain its source")
            let sentData = try Data(contentsOf: destination.appendingPathComponent("sample.txt"))
            try require(sentData == Data(contentsOf: source), "Send to must use the real transfer engine to copy bytes")
            main.sidebar.onThisMac?()
            try require(main.left.isShowingThisMac, "Sidebar This Mac must navigate the active pane")
            main.persistState()
            try require(AppStorage.load().leftTabs.last == BrowserPaneViewController.thisMacURL.absoluteString, "Saved This Mac URL must not collapse to an empty path")
            main.left.goBack()
            try require(main.left.currentURL == a && !main.left.isShowingThisMac, "Back from This Mac must return to folder")
        }
        for startup in ["thisMac", "custom", "home"] {
            var settings = initial
            settings.explorer.startupLocation = startup
            settings.explorer.startupPath = b.path
            settings.explorer.defaultViewMode = "largeIcons"
            settings.activeRightPane = true
            AppStorage.save(settings)
            let main = MainWindowController()
            let expected = startup == "thisMac" ? BrowserPaneViewController.thisMacURL : (startup == "custom" ? b : manager.homeDirectoryForCurrentUser)
            try require(main.left.currentURL == expected && main.left.openDirectories.count == 1 && main.activePane === main.left, "\(startup) startup must take precedence over prior left tabs and focus")
            try require(main.left.currentViewMode == "largeIcons", "New startup tabs must use preferred default view")
            try require(main.right.openDirectories == [b] && main.right.currentViewMode == "list", "Startup choice must preserve the other pane")
            main.close()
        }
        print("PASS: \(checks) Explorer menu, startup, sidebar, persistence and Send to integration checks")
    }
}
