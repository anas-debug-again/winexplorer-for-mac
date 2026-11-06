import AppKit

final class FileManagerAppDelegate: NSObject, NSApplicationDelegate {
    private(set) var controllers: [MainWindowController] = []
    private(set) weak var lastActiveController: MainWindowController?
    let recentFolders: RecentFoldersStore
    private let makeController: (URL?, Bool) -> MainWindowController
    private let presentWindow: (MainWindowController) -> Void
    private let openFile: (URL) -> Bool
    private var receivedExternalOpenRequest = false
    private var keyMonitor: Any?
    private var currentDockMenu: FileManagerDockMenu?
    private var waitingForTermination = false
    private var terminationReply: ((Bool) -> Void)?

    init(recentFolders: RecentFoldersStore = RecentFoldersStore(),
         makeController: @escaping (URL?, Bool) -> MainWindowController = { MainWindowController(initialURL: $0, restoresSession: $1) },
         presentWindow: @escaping (MainWindowController) -> Void = {
             $0.showWindow(nil)
             $0.window?.deminiaturize(nil)
             $0.window?.makeKeyAndOrderFront(nil)
             NSApp.activate(ignoringOtherApps: true)
         },
         openFile: @escaping (URL) -> Bool = { NSWorkspace.shared.open($0) }) {
        self.recentFolders = recentFolders
        self.makeController = makeController
        self.presentWindow = presentWindow
        self.openFile = openFile
        super.init()
    }

    deinit { if let keyMonitor { NSEvent.removeMonitor(keyMonitor) } }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .aqua)
        installIdleMenus()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.controllers.isEmpty, !self.waitingForTermination,
                  event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .control,
                  shortcutKey(for: event) == "n" else { return event }
            self.appNewWindow(nil)
            return nil
        }
        // Document-open events may arrive on either side of the launch notification.
        // AppKit marks those launches non-default, so do not create an unrelated window.
        let isDefaultLaunch = (notification.userInfo?[NSApplication.launchIsDefaultUserInfoKey] as? NSNumber)?.boolValue ?? true
        if controllers.isEmpty && !receivedExternalOpenRequest && isDefaultLaunch { openWindow(restoresSession: true) }
    }

    @discardableResult
    func openWindow(at url: URL? = nil, restoresSession: Bool = false) -> MainWindowController? {
        guard !waitingForTermination else { return nil }
        let previousWindow = lastActiveController?.window
        let controller = makeController(url, restoresSession)
        controllers.append(controller)
        lastActiveController = controller
        controller.onOpenNewWindow = { [weak self] url in self?.openWindow(at: url) }
        controller.onDirectoryVisited = { [weak self] url in self?.recentFolders.record(url) }
        controller.onBecameMain = { [weak self, weak controller] in
            guard let self, let controller, self.controllers.contains(where: { $0 === controller }) else { return }
            self.lastActiveController = controller
            controller.persistState()
        }
        controller.shouldPersistState = { [weak self, weak controller] in
            guard let self, let controller else { return false }
            return self.lastActiveController === controller
        }
        controller.onClosed = { [weak self, weak controller] in
            guard let self, let controller else { return }
            self.closed(controller)
        }
        recentFolders.record(controller.activePane.currentURL)
        controller.activateMenus()
        if let previousWindow, let window = controller.window {
            var frame = window.frame
            frame.origin = NSPoint(x: previousWindow.frame.minX + 24, y: previousWindow.frame.maxY - frame.height - 24)
            if let visible = previousWindow.screen?.visibleFrame ?? NSScreen.main?.visibleFrame {
                frame.origin.x = min(max(frame.origin.x, visible.minX), max(visible.minX, visible.maxX - frame.width))
                frame.origin.y = min(max(frame.origin.y, visible.minY), max(visible.minY, visible.maxY - frame.height))
            }
            window.setFrame(frame, display: false)
        }
        presentWindow(controller)
        return controller
    }

    @objc func appNewWindow(_ sender: Any?) { openWindow() }

    private func closed(_ controller: MainWindowController) {
        controllers.removeAll { $0 === controller }
        if lastActiveController === controller {
            lastActiveController = controllers.first(where: { $0.window?.isMainWindow == true }) ?? controllers.last
        }
        if let active = lastActiveController { active.activateMenus(); active.persistState() }
        else { installIdleMenus() }
        completeTerminationIfReady()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard !waitingForTermination else { return false }
        if controllers.isEmpty { openWindow() }
        else if !flag, let controller = lastActiveController ?? controllers.last { presentWindow(controller) }
        return true
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = FileManagerDockMenu(title: "WinExplorer for Mac")
        menu.autoenablesItems = false
        let newWindow = menu.addItem(withTitle: "New Window", action: #selector(appNewWindow(_:)), keyEquivalent: "")
        newWindow.target = self
        newWindow.isEnabled = !waitingForTermination
        menu.addItem(.separator())
        let heading = menu.addItem(withTitle: "Recent Folders", action: nil, keyEquivalent: "")
        heading.isEnabled = false
        let folders = recentFolders.folders
        for folder in folders {
            var title = folder.lastPathComponent.isEmpty ? folder.path : folder.lastPathComponent
            if folders.filter({ $0.lastPathComponent == folder.lastPathComponent }).count > 1 {
                let parent = folder.deletingLastPathComponent()
                title += " — " + (parent.lastPathComponent.isEmpty ? parent.path : parent.lastPathComponent)
            }
            let action = DockFolderAction { [weak self] in self?.openFolderURLs([folder]) }
            menu.retainedTargets.append(action)
            let item = menu.addItem(withTitle: title, action: #selector(DockFolderAction.openFolder(_:)), keyEquivalent: "")
            item.target = action; item.representedObject = folder; item.toolTip = folder.path
            item.isEnabled = !waitingForTermination
            item.image = NSWorkspace.shared.icon(forFile: folder.path)
            item.image?.size = NSSize(width: 16, height: 16)
        }
        if folders.isEmpty {
            menu.addItem(withTitle: "No recent folders", action: nil, keyEquivalent: "").isEnabled = false
        }
        currentDockMenu = menu
        return menu
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        if !urls.isEmpty { receivedExternalOpenRequest = true }
        openFolderURLs(urls)
    }

    /// Folder targets open here; file/package shortcut targets use their normal application.
    /// Both document shortcuts and Finder aliases resolve without UI or mounting volumes.
    @discardableResult
    func openFolderURLs(_ urls: [URL], reportErrors: Bool = true) -> [URL] {
        var opened: [URL] = []
        var failures: [String] = []
        for url in urls {
            do {
                guard !waitingForTermination else { continue }
                guard url.isFileURL else { throw CocoaError(.fileReadUnsupportedScheme) }
                let isShortcut = ShortcutSupport.isShortcut(url)
                let resolved = try ShortcutSupport.resolve(url)
                guard resolved.isFileURL, try resolved.checkResourceIsReachable() else { throw CocoaError(.fileReadNoSuchFile) }
                if ShortcutSupport.isBrowsableFolder(resolved), let folder = RecentFoldersStore.validatedFolder(resolved) {
                    guard openWindow(at: folder) != nil else { continue }
                    opened.append(folder)
                } else if isShortcut {
                    guard !ShortcutSupport.isShortcut(resolved), openFile(resolved) else { throw CocoaError(.fileReadUnknown) }
                    opened.append(resolved)
                } else { throw CocoaError(.fileReadUnsupportedScheme) }
            } catch { failures.append(url.lastPathComponent.isEmpty ? url.absoluteString : url.lastPathComponent) }
        }
        if reportErrors && !failures.isEmpty {
            let alert = NSAlert()
            alert.messageText = failures.count == 1 ? "The item couldn’t be opened" : "Some items couldn’t be opened"
            alert.informativeText = failures.joined(separator: ", ") + "\nChoose an existing folder or a valid shortcut to a folder or file."
            alert.addButton(withTitle: "OK")
            if let window = lastActiveController?.window { alert.beginSheetModal(for: window) }
            else { alert.runModal() }
        }
        return opened
    }

    func applicationWillTerminate(_ notification: Notification) { lastActiveController?.persistState() }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        requestTermination(confirmStop: {
            let alert = NSAlert()
            alert.messageText = "Stop transfers and quit?"
            alert.informativeText = "Remaining work in all windows will stop. Completed transfers will be kept."
            alert.addButton(withTitle: "Keep working")
            alert.addButton(withTitle: "Stop and quit")
            return alert.runModal() == .alertSecondButtonReturn
        }, reply: { sender.reply(toApplicationShouldTerminate: $0) })
    }

    func requestTermination(confirmStop: () -> Bool, reply: @escaping (Bool) -> Void) -> NSApplication.TerminateReply {
        if waitingForTermination { return .terminateLater }
        guard controllers.contains(where: \.hasRunningTransfers) else { return .terminateNow }
        guard confirmStop() else { return .terminateCancel }
        let running = controllers.filter(\.hasRunningTransfers)
        guard !running.isEmpty else { return .terminateNow }
        waitingForTermination = true
        terminationReply = reply
        for controller in running {
            let previous = controller.whenTransfersStop
            controller.whenTransfersStop = { [weak self] in
                previous?()
                self?.completeTerminationIfReady()
            }
        }
        for controller in running { controller.cancelAllTransfers() }
        // Always reply on a later turn, after AppKit receives terminateLater.
        DispatchQueue.main.async { [weak self] in self?.completeTerminationIfReady() }
        return .terminateLater
    }

    private func completeTerminationIfReady() {
        guard waitingForTermination, !controllers.contains(where: \.hasRunningTransfers), let reply = terminationReply else { return }
        terminationReply = nil
        DispatchQueue.main.async { reply(true) }
    }

    private func installIdleMenus() {
        guard controllers.isEmpty else { return }
        let bar = NSMenu()
        func addMenu(_ title: String) -> NSMenu {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let menu = NSMenu(title: title); item.submenu = menu; bar.addItem(item)
            return menu
        }
        let app = addMenu("WinExplorer for Mac")
        app.addItem(withTitle: "About WinExplorer for Mac", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "").target = NSApp
        app.addItem(.separator())
        app.addItem(withTitle: "Quit WinExplorer for Mac", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q").target = NSApp
        let file = addMenu("File")
        file.addItem(withTitle: "New Window", action: #selector(appNewWindow(_:)), keyEquivalent: "n").target = self
        let window = addMenu("Window")
        NSApp.windowsMenu = window
        NSApp.mainMenu = bar
    }
}

/// The Dock forwards actions with a nil sender. Each target owns its destination
/// instead of depending on an NSMenuItem surviving the cross-process dispatch.
private final class DockFolderAction: NSObject {
    private let handler: () -> Void
    init(handler: @escaping () -> Void) { self.handler = handler; super.init() }
    @objc func openFolder(_ sender: Any?) { handler() }
}

/// NSMenuItem.target is weak; keep targets alive for the full lifetime of each menu.
private final class FileManagerDockMenu: NSMenu {
    var retainedTargets: [DockFolderAction] = []
}
