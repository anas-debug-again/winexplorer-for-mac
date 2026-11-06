// Run: scripts/test-ui.sh AppDelegate
// Hidden windows, a named pasteboard and disposable project fixtures; no posted input.
import AppKit

private struct AppDelegateFailure: Error, CustomStringConvertible { let description: String }

@main struct AppDelegateRegression {
    static var checks = 0
    static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        checks += 1
        if try !condition() { throw AppDelegateFailure(description: message) }
    }
    static func wait(_ label: String, until condition: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(8)
        while !condition(), Date() < deadline { _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.015)) }
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
        let fixture = URL(fileURLWithPath: originalDirectory).appendingPathComponent(".build/qa/app-delegate-\(UUID().uuidString)")
        let a = fixture.appendingPathComponent("First/Projects", isDirectory: true)
        let b = fixture.appendingPathComponent("Second/Projects", isDirectory: true)
        let c = fixture.appendingPathComponent("Downloads", isDirectory: true)
        for folder in [a, b, c] { try manager.createDirectory(at: folder, withIntermediateDirectories: true) }
        try require(manager.changeCurrentDirectoryPath(fixture.path), "Settings must use only the disposable fixture")
        let board = NSPasteboard.withUniqueName()
        defer {
            board.releaseGlobally()
            manager.changeCurrentDirectoryPath(originalDirectory)
            try? manager.removeItem(at: fixture)
        }
        var settings = SavedSettings()
        settings.leftTabs = [a.path]; settings.rightTabs = [b.path]
        settings.split = false; settings.preview = false; settings.singlePreview = false
        AppStorage.save(settings)
        let history = RecentFoldersStore(storageURL: fixture.appendingPathComponent("state/recents.json"))
        var created: [(URL?, Bool)] = []
        var presentations = 0
        var externallyOpened: [URL] = []
        var externalOpenSucceeds = true
        let owner = FileManagerAppDelegate(recentFolders: history, makeController: { url, restores in
            created.append((url, restores))
            return MainWindowController(pasteboard: board, initialURL: url, restoresSession: restores)
        }, presentWindow: { controller in
            presentations += 1
            controller.window?.orderOut(nil)
        }, openFile: { url in
            externallyOpened.append(url)
            return externalOpenSucceeds
        })
        app.delegate = owner
        defer { for controller in owner.controllers { controller.close() }; app.delegate = nil }
        owner.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        try require(owner.controllers.count == 1 && created.first?.1 == true, "Ordinary launch must create one restoring window")
        guard let first = owner.controllers.first else { throw AppDelegateFailure(description: "Missing initial window") }
        try require(first.activePane.currentURL == a && owner.lastActiveController === first, "Initial window must restore its folder and own persistence")
        try require(!owner.applicationShouldTerminateAfterLastWindowClosed(app), "Closing the last window must keep the app running")
        let originalTabs = first.left.openDirectories
        guard let second = owner.openWindow(at: b) else { throw AppDelegateFailure(description: "Missing second window") }
        try require(owner.controllers.count == 2 && created.last?.1 == false && second.left.currentURL == b,
                    "An explicit folder must open in a separate non-restoring window")
        try require(first.left.openDirectories == originalTabs && first !== second, "New windows must preserve existing tabs")
        try require(owner.lastActiveController === second && second.shouldPersistState?() == true && first.shouldPersistState?() == false,
                    "Only the last active window may persist the shared session")
        first.onBecameMain?()
        try require(owner.lastActiveController === first && first.shouldPersistState?() == true && second.shouldPersistState?() == false,
                    "Changing the main window must switch persistence ownership")
        try require(AppStorage.load().leftTabs == first.left.openDirectories.map(\.path), "Main-window activation must save that window's session")
        history.record(a); history.record(b); history.record(c)
        let dockSelector = NSSelectorFromString("applicationDockMenu:")
        try require(owner.responds(to: dockSelector) && app.delegate === owner,
                    "The retained app delegate must expose the exact Objective-C Dock-menu selector")
        guard let dock = owner.perform(dockSelector, with: app)?.takeUnretainedValue() as? NSMenu else {
            throw AppDelegateFailure(description: "Objective-C Dock-menu dispatch did not return a menu")
        }
        let recentItems = dock.items.filter { $0.representedObject is URL }
        try require(recentItems.count == 3 && recentItems.compactMap { $0.representedObject as? URL } == [c, b, a],
                    "Dock menu must publish at most three newest real folders in order")
        try require(recentItems[1].title != recentItems[2].title && recentItems[1].toolTip == b.path,
                    "Matching folder names must be disambiguated while retaining the full path tooltip")
        dock.update()
        try require(!dock.autoenablesItems && recentItems.allSatisfy { $0.isEnabled && !$0.isHidden },
                    "Dock recents must remain explicitly enabled and visible after a menu update")
        try require(dock.item(withTitle: "Recent Folders")?.isEnabled == false && dock.item(withTitle: "Recent Folders")?.isHidden == false,
                    "The recent-folder heading must remain visible informational text")
        let targetIdentity = recentItems[0].target.map(ObjectIdentifier.init)
        // Rebuilding the current menu must not release targets owned by an older
        // menu while AppKit is still holding that menu for a pending selection.
        _ = owner.applicationDockMenu(app)
        try require(targetIdentity != nil && recentItems[0].target.map(ObjectIdentifier.init) == targetIdentity,
                    "Each Dock menu must retain its own action targets through later menu rebuilds")
        guard let recentAction = recentItems[0].action else { throw AppDelegateFailure(description: "Missing recent-folder action") }
        // AppKit forwards Dock item actions with a nil sender, not the NSMenuItem.
        try require(app.sendAction(recentAction, to: recentItems[0].target, from: nil), "Dock recent-folder action must route with a nil sender")
        try require(owner.controllers.count == 3 && owner.controllers.last?.activePane.currentURL == c && first.left.openDirectories == originalTabs,
                    "A Dock folder must create a new window without navigating an existing window")
        let secondRecentAction = recentItems[1].action!
        try require(app.sendAction(secondRecentAction, to: recentItems[1].target, from: nil)
            && owner.controllers.count == 4 && owner.controllers.last?.activePane.currentURL == b,
                    "Each nil-sender Dock action must retain its own distinct folder destination")
        owner.controllers.last?.close()
        let count = owner.controllers.count
        let beforePresent = presentations
        try require(owner.applicationShouldHandleReopen(app, hasVisibleWindows: false) && owner.controllers.count == count && presentations == beforePresent + 1,
                    "Reopen with existing hidden windows must present one rather than create another")
        var confirmed = false
        try require(owner.requestTermination(confirmStop: { confirmed = true; return true }, reply: { _ in }) == .terminateNow && !confirmed,
                    "Quit without transfers must proceed without a stop-transfer prompt")
        for controller in owner.controllers { controller.close() }
        try require(owner.controllers.isEmpty && owner.lastActiveController == nil, "Closed windows must leave the app owner's retained collection")
        guard let newWindow = app.mainMenu?.item(withTitle: "File")?.submenu?.item(withTitle: "New Window") else {
            throw AppDelegateFailure(description: "No-window menu must keep File > New Window")
        }
        try require(newWindow.target === owner && newWindow.keyEquivalent == "n" && newWindow.keyEquivalentModifierMask == .command,
                    "No-window New Window must target the app owner and retain Command-N")
        func menuTargets(_ menu: NSMenu) -> [AnyObject] {
            menu.items.flatMap { item in (item.target.map { [$0] } ?? []) + (item.submenu.map(menuTargets) ?? []) }
        }
        try require(!menuTargets(app.mainMenu!).contains { $0 is MainWindowController }, "No-window menus must not retain closed window-controller targets")
        try require(owner.applicationShouldHandleReopen(app, hasVisibleWindows: false) && owner.controllers.count == 1 && created.last?.1 == false,
                    "Dock reopen with no windows must create a new independent window")
        owner.controllers.first?.close()
        try require(app.sendAction(newWindow.action!, to: newWindow.target, from: newWindow) && owner.controllers.count == 1,
                    "The no-window File menu must create a window")
        owner.controllers.first?.close()

        let alias = fixture.appendingPathComponent("Projects alias")
        let bookmark = try a.bookmarkData(options: .suitableForBookmarkFile, includingResourceValuesForKeys: nil, relativeTo: nil)
        try URL.writeBookmarkData(bookmark, to: alias)
        let regular = fixture.appendingPathComponent("not-a-folder.txt")
        try Data("not a folder".utf8).write(to: regular)
        let opened = owner.openFolderURLs([alias, b, regular, fixture.appendingPathComponent("missing")], reportErrors: false)
        try require(opened == [a, b] && owner.controllers.count == 2, "Open events must resolve real Finder folder aliases and retain successful folder opens")
        try require(owner.controllers.map { $0.activePane.currentURL } == [a, b], "Open events must create a distinct window for each requested folder")
        owner.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        try require(owner.controllers.count == 2, "Already opened folder windows must prevent a duplicate startup window")

        let folderShortcut = fixture.appendingPathComponent("Projects shortcut").appendingPathExtension(AppShortcutDocument.fileExtension)
        let fileShortcut = fixture.appendingPathComponent("Document shortcut").appendingPathExtension(AppShortcutDocument.fileExtension)
        try AppShortcutDocument.data(for: a).write(to: folderShortcut)
        try AppShortcutDocument.data(for: regular).write(to: fileShortcut)
        let beforeShortcuts = owner.controllers.count
        try require(owner.openFolderURLs([folderShortcut, fileShortcut], reportErrors: false) == [a, regular],
                    "App-owned shortcut documents must resolve both folder and file targets")
        try require(owner.controllers.count == beforeShortcuts + 1 && owner.controllers.last?.activePane.currentURL == a,
                    "An app-owned folder shortcut must create exactly one new WinExplorer for Mac window")
        try require(externallyOpened == [regular], "A file shortcut must hand only its resolved target to the default-app opener")
        let fileAlias = fixture.appendingPathComponent("Document alias")
        try URL.writeBookmarkData(regular.bookmarkData(options: .suitableForBookmarkFile, includingResourceValuesForKeys: nil, relativeTo: nil), to: fileAlias)
        try require(owner.openFolderURLs([fileAlias], reportErrors: false) == [regular] && externallyOpened == [regular, regular],
                    "Explicitly opening a native file alias in WinExplorer for Mac must also use the target's default app")
        externalOpenSucceeds = false
        try require(owner.openFolderURLs([fileShortcut], reportErrors: false).isEmpty,
                    "A default-app opener failure must not be reported as a successful open")
        externalOpenSucceeds = true
        let malformed = fixture.appendingPathComponent("Corrupt shortcut").appendingPathExtension(AppShortcutDocument.fileExtension)
        try Data("not a shortcut document".utf8).write(to: malformed)
        let doomed = fixture.appendingPathComponent("Deleted target", isDirectory: true)
        try manager.createDirectory(at: doomed, withIntermediateDirectories: true)
        let brokenShortcut = fixture.appendingPathComponent("Broken shortcut").appendingPathExtension(AppShortcutDocument.fileExtension)
        try AppShortcutDocument.data(for: doomed).write(to: brokenShortcut)
        try manager.removeItem(at: doomed)
        let beforeInvalid = (owner.controllers.count, externallyOpened.count)
        try require(owner.openFolderURLs([malformed, brokenShortcut], reportErrors: false).isEmpty,
                    "Corrupt and broken shortcut documents must be rejected")
        try require(owner.controllers.count == beforeInvalid.0 && externallyOpened.count == beforeInvalid.1,
                    "Invalid shortcut documents must neither open windows nor launch a file app")

        // A file target needs no browser window in either launch-event order.
        let cold = FileManagerAppDelegate(recentFolders: history, makeController: { url, restores in
            MainWindowController(pasteboard: board, initialURL: url, restoresSession: restores)
        }, presentWindow: { $0.window?.orderOut(nil) }, openFile: { url in
            externallyOpened.append(url); return true
        })
        cold.application(app, open: [fileShortcut])
        cold.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        try require(cold.controllers.isEmpty && externallyOpened.last == regular,
                    "A file-shortcut launch must not also open an unrelated restoring window")
        cold.application(app, open: [folderShortcut])
        try require(cold.controllers.count == 1 && cold.controllers.first?.activePane.currentURL == a,
                    "An external folder-shortcut event must create its target window")
        for controller in cold.controllers { controller.close() }
        let late = FileManagerAppDelegate(recentFolders: history, makeController: { url, restores in
            MainWindowController(pasteboard: board, initialURL: url, restoresSession: restores)
        }, presentWindow: { $0.window?.orderOut(nil) }, openFile: { url in
            externallyOpened.append(url); return true
        })
        late.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification,
            userInfo: [NSApplication.launchIsDefaultUserInfoKey: NSNumber(value: false)]))
        try require(late.controllers.isEmpty, "A document launch must not create a home window before a delayed open event")
        late.application(app, open: [folderShortcut])
        try require(late.controllers.count == 1 && late.controllers.first?.activePane.currentURL == a,
                    "A delayed document-open event must create only its requested folder window")
        for controller in late.controllers { controller.close() }
        owner.controllers.last?.activateMenus()
        // Keep the aggregate quit test limited to its original pair of windows.
        while owner.controllers.count > 2 { owner.controllers.last?.close() }

        // Keep two genuine engine jobs waiting at conflicts; this makes cancellation deterministic.
        let sourceFolder = fixture.appendingPathComponent("Sources", isDirectory: true)
        try manager.createDirectory(at: sourceFolder, withIntermediateDirectories: true)
        let source = sourceFolder.appendingPathComponent("report.txt")
        let sourceData = Data("New source contents".utf8)
        let existingData = Data("Existing destination must survive quitting".utf8)
        try sourceData.write(to: source)
        for destination in [a, b] { try existingData.write(to: destination.appendingPathComponent("report.txt")) }
        let running = owner.controllers
        for (controller, destination) in zip(running, [a, b]) { controller.left.onDrop?([source], destination, false) }
        try wait("two waiting transfer conflicts") {
            running.allSatisfy { controller in
                controller.hasRunningTransfers && controller.window?.contentView.map { descendants($0).contains { $0 is ConflictDialogView } } == true
            }
        }
        try require(owner.requestTermination(confirmStop: { false }, reply: { _ in }) == .terminateCancel && running.allSatisfy(\.hasRunningTransfers),
                    "Keep working must leave transfers in every window running")
        var priorCallbacks = 0
        for controller in running { controller.whenTransfersStop = { priorCallbacks += 1 } }
        var replyCount = 0
        var allStoppedAtReply = false
        let decision = owner.requestTermination(confirmStop: { true }, reply: { allowed in
            replyCount += 1
            allStoppedAtReply = allowed && running.allSatisfy { !$0.hasRunningTransfers }
        })
        try require(decision == .terminateLater && replyCount == 0, "Stop and quit must wait and never reply before terminateLater is returned")
        try require(owner.openWindow(at: c) == nil, "No new windows may start work while termination is pending")
        let quittingDock = owner.applicationDockMenu(app)!
        try require(quittingDock.items.filter { $0.action != nil }.allSatisfy { !$0.isEnabled },
                    "Dock actions must be disabled while all-window termination is pending")
        try wait("all windows cancelled before quit reply") { replyCount == 1 && running.allSatisfy { !$0.hasRunningTransfers } }
        try require(allStoppedAtReply && priorCallbacks == 2, "Quit must wait for both jobs and preserve their existing completion callbacks")
        try require(try Data(contentsOf: source) == sourceData, "Cancelling all jobs must preserve the source")
        for destination in [a, b] {
            try require(try Data(contentsOf: destination.appendingPathComponent("report.txt")) == existingData,
                        "Cancelling conflicts during quit must preserve existing destination contents")
        }
        for controller in running { controller.close() }
        _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
        try require(replyCount == 1 && owner.controllers.isEmpty, "Window closure after cancellation must not produce another quit reply")
        print("PASS: \(checks) app window lifecycle, Dock, folder-alias opening and aggregate termination checks")
    }
}
