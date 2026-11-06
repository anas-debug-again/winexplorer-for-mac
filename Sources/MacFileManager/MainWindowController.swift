import AppKit
import UniformTypeIdentifiers
import FileManagerCore

private extension Notification.Name {
    static let fileManagerPreferencesChanged = Notification.Name("FileManagerPreferencesChanged")
}

final class MainWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation {
    let left: BrowserPaneViewController
    let right: BrowserPaneViewController
    let sidebar = SidebarViewController()
    let previewController = PreviewViewController()
    let engine = TransferEngine()
    let fileUndo = UndoManager()
    private var activeIsLeft = true
    private var settings: SavedSettings
    private var split = false
    private var previewVisible = true
    private var singlePreviewVisible = true
    private var restoringSettings = true
    private let temporarySession = CommandLine.arguments.contains("--temporary-session")
    private let paneStack = NSStackView()
    private let toolbar = NSStackView()
    private let rightArea = NSStackView()
    private var panesWidthConstraint: NSLayoutConstraint?
    private let headerHost = NSView()
    private var headerConstraints: [NSLayoutConstraint] = []
    private var headerIsSplit: Bool?
    private let statusLabel = makeLabel("", size: 16, color: .labelColor)
    private var drawerHeight: NSLayoutConstraint?
    private var drawer: TransferDrawer!
    private var previewSeparator = separator(vertical: true)
    private var buttons: [String: NSButton] = [:]
    private let clipboardState: FileClipboardState
    private var clipboardURLs: [URL] { get { clipboardState.urls } set { clipboardState.urls = newValue } }
    private let pasteboard: NSPasteboard
    private var clipboardIsCut: Bool { get { clipboardState.isCut } set { clipboardState.isCut = newValue } }
    private var clipboardChangeCount: Int { get { clipboardState.changeCount } set { clipboardState.changeCount = newValue } }
    private var displayedCutURLs = Set<URL>()
    private struct CutPasteSnapshot {
        let changeCount: Int
        let sources: [URL]
        let identities: [URL: FileIdentity]
    }
    private var cutPasteJobs: [UUID: CutPasteSnapshot] = [:]
    private var eventMonitor: Any?
    private var refreshTimer: Timer?
    private var jobs: [UUID: TransferProgress] = [:]
    private var pendingJobIDs: Set<UUID> = []
    private var conflicts: [(FileConflict, (ConflictResolution) -> Void)] = []
    private var showingConflict = false
    private var pendingDialog: ConflictDialogView?
    private var conflictOverlay: NSView?
    private var drawerVisibleBeforeConflict = false
    private var pendingConflictID: UUID?
    private var propertiesWindows: [UUID: PropertiesWindowController] = [:]
    private var optionsWindow: ExplorerOptionsWindowController?
    private var creatingAliases = false
    private var aliasCancellation: SendToService.Cancellation?
    var whenTransfersStop: (() -> Void)?
    var onOpenNewWindow: ((URL?) -> Void)?
    var onDirectoryVisited: ((URL) -> Void)?
    var onClosed: (() -> Void)?
    var onBecameMain: (() -> Void)?
    var shouldPersistState: (() -> Bool)?
    private var closingAfterTransfers = false
    var activePane: BrowserPaneViewController { activeIsLeft ? left : right }
    var hasRunningTransfers: Bool { !pendingJobIDs.isEmpty || creatingAliases }

    init(pasteboard: NSPasteboard = .general, initialURL: URL? = nil, restoresSession: Bool = true) {
        self.pasteboard = pasteboard
        clipboardState = FileClipboardState.shared(for: pasteboard)
        settings = AppStorage.load()
        let home = FileManager.default.homeDirectoryForCurrentUser
        func location(_ value: String) -> URL {
            value == BrowserPaneViewController.thisMacURL.absoluteString ? BrowserPaneViewController.thisMacURL : URL(fileURLWithPath: value)
        }
        let restoreLeft = restoresSession && initialURL == nil && settings.explorer.startupLocation == "restore"
        let preferredURL: URL
        switch settings.explorer.startupLocation {
        case "thisMac": preferredURL = BrowserPaneViewController.thisMacURL
        case "custom": preferredURL = URL(fileURLWithPath: (settings.explorer.startupPath as NSString).expandingTildeInPath, isDirectory: true)
        default: preferredURL = home
        }
        let leftURL = initialURL ?? (restoresSession ? AppStorage.argument("--left").map { URL(fileURLWithPath: $0) } : nil)
            ?? (restoreLeft ? settings.leftTabs.first.map(location) : preferredURL) ?? home
        let rightURL = restoresSession ? (AppStorage.argument("--right").map { URL(fileURLWithPath: $0) } ?? settings.rightTabs.first.map(location) ?? home.appendingPathComponent("Downloads")) : leftURL
        left = BrowserPaneViewController(url: leftURL)
        right = BrowserPaneViewController(url: rightURL)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1440, height: 900), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "WinExplorer for Mac"
        window.tabbingMode = .disallowed
        window.titleVisibility = .hidden; window.titlebarAppearsTransparent = true
        for control in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] { window.standardWindowButton(control)?.isHidden = true }
        window.appearance = NSAppearance(named: .aqua)
        window.minSize = NSSize(width: 1320, height: 790)
        window.center(); window.delegate = self
        split = restoresSession && !CommandLine.arguments.contains("--single") && (settings.split || CommandLine.arguments.contains("--split"))
        previewVisible = !restoresSession ? settings.singlePreview : (CommandLine.arguments.contains("--split") ? false
            : (CommandLine.arguments.contains("--single") ? settings.singlePreview : settings.preview)
        )
        singlePreviewVisible = settings.singlePreview
        let restoredActiveRight = restoreLeft && settings.activeRightPane
        configureView()
        configurePanes()
        let savedLeftTabs = settings.leftTabs, savedRightTabs = settings.rightTabs
        if restoreLeft, AppStorage.argument("--left") == nil, !savedLeftTabs.isEmpty { left.restoreTabs(savedLeftTabs.map(location), selectedIndex: settings.leftSelectedTab) }
        if restoresSession, AppStorage.argument("--right") == nil, !savedRightTabs.isEmpty { right.restoreTabs(savedRightTabs.map(location), selectedIndex: settings.rightSelectedTab) }
        for pane in [left, right] {
            pane.setDisplayPreferences(showExtensions: settings.explorer.showFileExtensions, compact: settings.explorer.compactView, defaultViewMode: settings.explorer.defaultViewMode)
        }
        if restoreLeft, AppStorage.argument("--left") == nil { left.restoreDisplaySettings(settings.leftDisplay) }
        if restoresSession, AppStorage.argument("--right") == nil { right.restoreDisplaySettings(settings.rightDisplay) }
        left.setHiddenFiles(settings.showHidden); right.setHiddenFiles(settings.showHidden)
        setActive(left: !split || !restoredActiveRight)
        restoringSettings = false
        installMenus()
        installKeyboardMonitor()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.updateButtons() }
        NotificationCenter.default.addObserver(self, selector: #selector(didBecomeActive), name: NSApplication.didBecomeActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(sheetDidEnd), name: NSWindow.didEndSheetNotification, object: window)
        NotificationCenter.default.addObserver(self, selector: #selector(clipboardDidChange), name: FileClipboardState.didChange, object: clipboardState)
        NotificationCenter.default.addObserver(self, selector: #selector(preferencesDidChange(_:)), name: .fileManagerPreferencesChanged, object: nil)
        updateButtons()
        if restoresSession, let path = AppStorage.argument("--select") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.left.selectFiles([URL(fileURLWithPath: path)]); self?.left.focusFiles() }
        }
        if restoresSession, let path = AppStorage.argument("--snapshot") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.saveSnapshot(to: URL(fileURLWithPath: path)) }
        }
    }
    override func showWindow(_ sender: Any?) { super.showWindow(sender); activePane.focusFiles() }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    deinit { if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }; refreshTimer?.invalidate(); NotificationCenter.default.removeObserver(self) }

    private func configureView() {
        let content = NSView(); content.wantsLayer = true; content.layer?.backgroundColor = NSColor(calibratedWhite: 0.97, alpha: 1).cgColor
        window?.contentView = content
        let root = NSStackView(); root.orientation = .vertical; root.spacing = 0; root.alignment = .leading; root.distribution = .fill
        content.addSubview(root); edgePin(root, to: content)
        let titlebar = WindowTitleView(); root.addArrangedSubview(titlebar)
        titlebar.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true; titlebar.heightAnchor.constraint(equalToConstant: 44).isActive = true
        let title = makeLabel("WinExplorer for Mac", size: 21, bold: true); title.translatesAutoresizingMaskIntoConstraints = false; titlebar.addSubview(title)
        NSLayoutConstraint.activate([title.centerXAnchor.constraint(equalTo: titlebar.centerXAnchor), title.centerYAnchor.constraint(equalTo: titlebar.centerYAnchor)])
        let controls = NSStackView(); controls.orientation = .horizontal; controls.spacing = 9; controls.translatesAutoresizingMaskIntoConstraints = false
        controls.addArrangedSubview(TrafficLightButton(color: NSColor(calibratedRed: 1, green: 0.37, blue: 0.34, alpha: 1), label: "Close window", handler: { [weak self] in self?.window?.performClose(nil) }))
        controls.addArrangedSubview(TrafficLightButton(color: NSColor(calibratedRed: 1, green: 0.74, blue: 0.18, alpha: 1), label: "Minimize window", handler: { [weak self] in self?.window?.miniaturize(nil) }))
        controls.addArrangedSubview(TrafficLightButton(color: NSColor(calibratedRed: 0.15, green: 0.78, blue: 0.25, alpha: 1), label: "Zoom window", handler: { [weak self] in self?.window?.zoom(nil) }))
        titlebar.addSubview(controls); NSLayoutConstraint.activate([controls.leadingAnchor.constraint(equalTo: titlebar.leadingAnchor, constant: 18), controls.centerYAnchor.constraint(equalTo: titlebar.centerYAnchor)])
        root.addArrangedSubview(headerHost); headerHost.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        toolbar.orientation = .horizontal; toolbar.distribution = .equalSpacing; toolbar.spacing = 8; toolbar.edgeInsets = NSEdgeInsets(top: 9, left: 14, bottom: 9, right: 14)
        addToolbar("New", symbol: "plus.circle", chevron: true, action: { [weak self] in self?.showNewMenu() }); toolbarDivider()
        addToolbar("Cut", symbol: "scissors", action: { [weak self] in self?.putClipboard(cut: true) })
        addToolbar("Copy", symbol: "doc.on.doc", action: { [weak self] in self?.putClipboard(cut: false) })
        addToolbar("Paste", symbol: "doc.on.clipboard", action: { [weak self] in self?.paste() }); toolbarDivider()
        addToolbar("Rename", symbol: "pencil", action: { [weak self] in self?.rename() })
        addToolbar("Move to Trash", symbol: "trash", action: { [weak self] in self?.trash() }); toolbarDivider()
        addToolbar("Sort", symbol: "arrow.up.arrow.down", chevron: true, action: { [weak self] in self?.showSortMenu() })
        addToolbar("View", symbol: "square.grid.2x2", chevron: true, action: { [weak self] in self?.showViewMenu() }); toolbarDivider()
        addToolbar("Split view", symbol: "rectangle.split.2x1", action: { [weak self] in self?.toggleSplit() }); toolbarDivider()
        addToolbar("Preview", symbol: "sidebar.right", action: { [weak self] in self?.togglePreview() })
        root.addArrangedSubview(toolbar); toolbar.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        let line = separator(); root.addArrangedSubview(line); line.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        let body = NSStackView(); body.orientation = .horizontal; body.spacing = 0; body.alignment = .top; body.distribution = .fill
        root.addArrangedSubview(body); body.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        body.addArrangedSubview(sidebar.view); sidebar.view.widthAnchor.constraint(equalToConstant: 280).isActive = true
        sidebar.view.heightAnchor.constraint(equalTo: body.heightAnchor).isActive = true
        let sideLine = separator(vertical: true); body.addArrangedSubview(sideLine); sideLine.heightAnchor.constraint(equalTo: body.heightAnchor).isActive = true
        rightArea.orientation = .vertical; rightArea.spacing = 0; rightArea.alignment = .leading; rightArea.distribution = .fill
        body.addArrangedSubview(rightArea); rightArea.heightAnchor.constraint(equalTo: body.heightAnchor).isActive = true
        rightArea.widthAnchor.constraint(equalTo: body.widthAnchor, constant: -281).isActive = true
        let browsing = NSStackView(); browsing.orientation = .horizontal; browsing.spacing = 0; browsing.alignment = .top; browsing.distribution = .fill
        rightArea.addArrangedSubview(browsing); browsing.widthAnchor.constraint(equalTo: rightArea.widthAnchor).isActive = true
        paneStack.orientation = .horizontal; paneStack.spacing = 1; paneStack.distribution = .fillEqually; paneStack.alignment = .top
        paneStack.wantsLayer = true; paneStack.layer?.backgroundColor = NSColor(calibratedWhite: 0.84, alpha: 1).cgColor
        paneStack.addArrangedSubview(left.view); paneStack.addArrangedSubview(right.view)
        left.view.heightAnchor.constraint(equalTo: paneStack.heightAnchor).isActive = true
        right.view.heightAnchor.constraint(equalTo: paneStack.heightAnchor).isActive = true
        browsing.addArrangedSubview(paneStack); paneStack.heightAnchor.constraint(equalTo: browsing.heightAnchor).isActive = true
        panesWidthConstraint = paneStack.widthAnchor.constraint(equalTo: browsing.widthAnchor); panesWidthConstraint?.isActive = true
        browsing.addArrangedSubview(previewSeparator); previewSeparator.heightAnchor.constraint(equalTo: browsing.heightAnchor).isActive = true
        browsing.addArrangedSubview(previewController.view)
        previewController.view.widthAnchor.constraint(equalToConstant: 345).isActive = true
        previewController.view.heightAnchor.constraint(equalTo: browsing.heightAnchor).isActive = true
        drawer = TransferDrawer(onCancel: { [weak self] id in self?.engine.cancel(id) }, onHide: { [weak self] in self?.drawer.isHidden = true })
        rightArea.addArrangedSubview(drawer); drawer.widthAnchor.constraint(equalTo: rightArea.widthAnchor).isActive = true
        drawerHeight = drawer.heightAnchor.constraint(equalToConstant: 330); drawerHeight?.isActive = true
        drawer.isHidden = true
        let footerLine = separator(); root.addArrangedSubview(footerLine); footerLine.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        let footer = NSStackView(); footer.orientation = .horizontal; footer.spacing = 8; footer.edgeInsets = NSEdgeInsets(top: 7, left: 20, bottom: 7, right: 20)
        footer.addArrangedSubview(statusLabel)
        let spacer = NSView(); spacer.setContentHuggingPriority(.defaultLow, for: .horizontal); footer.addArrangedSubview(spacer)
        let shortcuts = ActionButton("Windows shortcuts", symbol: "keyboard", handler: { [weak self] in self?.showShortcuts() }); shortcuts.flat = true; shortcuts.font = .systemFont(ofSize: 15)
        shortcuts.heightAnchor.constraint(equalToConstant: 26).isActive = true; footer.addArrangedSubview(shortcuts)
        root.addArrangedSubview(footer); footer.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        footer.heightAnchor.constraint(equalToConstant: 40).isActive = true
        updateLayout()
    }
    private func toolbarDivider() {
        let holder = NSView(); holder.translatesAutoresizingMaskIntoConstraints = false
        holder.widthAnchor.constraint(equalToConstant: 13).isActive = true; holder.heightAnchor.constraint(equalToConstant: 26).isActive = true
        let line = separator(vertical: true); holder.addSubview(line)
        NSLayoutConstraint.activate([line.centerXAnchor.constraint(equalTo: holder.centerXAnchor), line.topAnchor.constraint(equalTo: holder.topAnchor), line.bottomAnchor.constraint(equalTo: holder.bottomAnchor)])
        toolbar.addArrangedSubview(holder)
    }
    private func addToolbar(_ title: String, symbol: String, chevron: Bool = false, action: @escaping () -> Void) {
        let button = ActionButton(title, symbol: symbol, handler: action); button.flat = true; button.showsChevron = chevron; button.font = .systemFont(ofSize: 18)
        button.setAccessibilityIdentifier("toolbar-" + title.lowercased().replacingOccurrences(of: " ", with: "-"))
        let keys = ["New": "Ctrl+Shift+N", "Cut": "Ctrl+X", "Copy": "Ctrl+C", "Paste": "Ctrl+V", "Rename": "F2", "Move to Trash": "Delete", "Split view": "Command+Shift+S", "Preview": "Space"]
        button.toolTip = keys[title].map { title + " (" + $0 + ")" } ?? title
        buttons[title] = button; toolbar.addArrangedSubview(button)
    }
    private func showShortcuts() {
        guard let window else { return }
        let alert = NSAlert(); alert.messageText = "Windows shortcuts"
        alert.informativeText = "Ctrl+C   Copy\nCtrl+X   Cut\nCtrl+V   Paste\nCtrl+A   Select all\nCtrl+L   Edit address\nCtrl+F   Search folder\nCtrl+N   New window\nCtrl+T   New tab\nCtrl+W   Close tab\nCtrl+Shift+N   New folder\nCtrl+I / Alt+Enter   Properties\nF2   Rename\nSpace   Preview\n\nCommand shortcuts work too."
        alert.addButton(withTitle: "Done"); alert.beginSheetModal(for: window)
    }
    private func configurePanes() {
        for (pane, isLeft) in [(left, true), (right, false)] {
            pane.onStatusChange = { [weak self] text in if self?.activeIsLeft == isLeft { self?.statusLabel.stringValue = text } }
            pane.onActivate = { [weak self] in self?.setActive(left: isLeft) }
            pane.onSelectionChange = { [weak self] urls in
                guard let self, self.activeIsLeft == isLeft else { return }
                self.previewController.show(url: self.previewVisible && urls.count == 1 ? urls.first : nil); self.updateButtons()
            }
            pane.onDirectoryChange = { [weak self, weak pane] url in
                guard let self else { return }
                if self.activeIsLeft == isLeft { self.updateSidebarSelection() }
                self.updateButtons(); self.saveSettings()
                if !self.restoringSettings, pane?.isShowingRecents == false, url.isFileURL {
                    self.onDirectoryVisited?(url)
                }
            }
            pane.onOpenFolderWindow = { [weak self] url in self?.onOpenNewWindow?(url) }
            pane.onOpenError = { [weak self] message in self?.showError(message) }
            pane.onPresentationChange = { [weak self] in self?.saveSettings() }
            pane.onRequestAction = { [weak self] action in self?.setActive(left: isLeft); self?.perform(action) }
            pane.canPasteShortcut = { [weak self, weak pane] in
                guard let self, let pane else { return false }
                return self.canPasteShortcut(into: pane)
            }
            pane.onDrop = { [weak self] urls, destination, move in self?.startTransfer(kind: move ? .move : .copy, sources: urls, destination: destination) }
            pane.onSendToFolder = { [weak self] urls, destination in
                guard let self, !urls.isEmpty else { return }
                self.setActive(left: isLeft)
                self.startTransfer(kind: .copy, sources: urls, destination: destination)
            }
        }
        previewController.onOpen = { [weak self] url in self?.activePane.openURL(url) }
        sidebar.onNavigate = { [weak self] url in self?.activePane.navigate(to: url) }
        sidebar.onRecents = { [weak self] in self?.activePane.showRecents(); self?.sidebar.selectRecents(); self?.updateButtons() }
        sidebar.onProperties = { [weak self] url in self?.showProperties(urls: [url]) }
        sidebar.onThisMac = { [weak self] in self?.activePane.showThisMac() }
        previewController.onClose = { [weak self] in self?.togglePreview() }
    }
    private func setActive(left isLeft: Bool) {
        activeIsLeft = isLeft; left.setActive(isLeft); right.setActive(!isLeft)
        updateSidebarSelection()
        previewController.show(url: previewVisible && activePane.selectedURLs.count == 1 ? activePane.selectedURLs.first : nil)
        updateButtons(); saveSettings()
    }
    private func updateSidebarSelection() {
        let title = activePane.isShowingThisMac ? "This Mac" : (activePane.isShowingRecents ? "Recents" : FileManager.default.displayName(atPath: activePane.currentURL.path))
        window?.title = "\(title) — WinExplorer for Mac"
        if activePane.isShowingThisMac { sidebar.selectThisMac() }
        else if activePane.isShowingRecents { sidebar.selectRecents() }
        else { sidebar.select(url: activePane.currentURL) }
    }
    private var isVirtualLocation: Bool { activePane.isShowingRecents || activePane.isShowingThisMac }
    private func updateLayout() {
        if headerIsSplit != split {
            NSLayoutConstraint.deactivate(headerConstraints); headerConstraints = []
            left.setPresentationMode(split: split); right.setPresentationMode(split: true)
            if !split {
                let header = left.navigationHeaderView; header.removeFromSuperview(); headerHost.addSubview(header); header.translatesAutoresizingMaskIntoConstraints = false
                headerConstraints = [header.leadingAnchor.constraint(equalTo: headerHost.leadingAnchor), header.trailingAnchor.constraint(equalTo: headerHost.trailingAnchor), header.topAnchor.constraint(equalTo: headerHost.topAnchor), header.bottomAnchor.constraint(equalTo: headerHost.bottomAnchor)]
                NSLayoutConstraint.activate(headerConstraints)
            }
            headerIsSplit = split
        }
        headerHost.isHidden = split; statusLabel.isHidden = split
        right.view.isHidden = !split
        previewController.view.isHidden = !previewVisible; previewSeparator.isHidden = !previewVisible
        panesWidthConstraint?.constant = previewVisible ? -346 : 0
        (buttons["Split view"] as? ActionButton)?.selected = split
        (buttons["Preview"] as? ActionButton)?.selected = previewVisible
    }
    private func toggleSplit() {
        split.toggle()
        if split {
            singlePreviewVisible = previewVisible; previewVisible = false
        } else {
            previewVisible = singlePreviewVisible; setActive(left: true)
        }
        previewController.show(url: previewVisible && activePane.selectedURLs.count == 1 ? activePane.selectedURLs.first : nil)
        updateLayout(); activePane.focusFiles(); saveSettings()
    }
    private func togglePreview() {
        previewVisible.toggle()
        if !split { singlePreviewVisible = previewVisible }
        previewController.show(url: previewVisible && activePane.selectedURLs.count == 1 ? activePane.selectedURLs.first : nil)
        updateLayout(); activePane.focusFiles(); saveSettings()
    }
    private func toggleTransfers() { drawer.isHidden.toggle() }
    private func updateButtons() {
        let blocked = showingConflict || window?.attachedSheet != nil
        for button in buttons.values { button.isEnabled = !blocked }
        guard !blocked else { return }
        let selection = activePane.selectedURLs
        for key in ["Cut", "Copy", "Move to Trash"] { buttons[key]?.isEnabled = !selection.isEmpty }
        buttons["Rename"]?.isEnabled = selection.count == 1
        clipboardState.refresh(from: pasteboard)
        let cuts = clipboardIsCut ? Set(clipboardURLs) : []
        if displayedCutURLs != cuts {
            displayedCutURLs = cuts
            left.setCutURLs(cuts); right.setCutURLs(cuts)
        }
        buttons["Paste"]?.isEnabled = !readClipboard().isEmpty && !isVirtualLocation && !isCurrentCutPasteRunning
        buttons["New"]?.isEnabled = !isVirtualLocation
        buttons["Sort"]?.isEnabled = !activePane.isShowingThisMac
    }
    private func perform(_ action: BrowserAction) {
        switch action {
        case .cut: putClipboard(cut: true)
        case .copy: putClipboard(cut: false)
        case .paste: paste()
        case .pasteShortcut: pasteShortcut()
        case .rename: rename()
        case .trash: trash()
        case .newFolder: createItem(folder: true)
        case .newFile: createItem(folder: false)
        case .preview: togglePreview()
        case .copyPath: pasteboard.clearContents(); pasteboard.setString(activePane.selectedURLs.map(\.path).joined(separator: "\n"), forType: .string)
        case .openWith: openWith()
        case .properties: showProperties()
        case .sendToDesktopAlias: sendToDesktopAlias()
        case .sendToChooseFolder: chooseSendToFolder()
        }
    }
    private func showProperties(urls requestedURLs: [URL]? = nil) {
        guard !showingConflict, window?.attachedSheet == nil else { return }
        let urls = requestedURLs ?? (activePane.selectedURLs.isEmpty
            ? (isVirtualLocation ? [] : [activePane.currentURL]) : activePane.selectedURLs)
        guard !urls.isEmpty else { return }
        let id = UUID()
        let controller = PropertiesWindowController(urls: urls)
        var identities = Dictionary(uniqueKeysWithValues: urls.compactMap { url in FileIdentity(url: url).map { (url, $0) } })
        controller.onClose = { [weak self] in self?.propertiesWindows.removeValue(forKey: id) }
        controller.onOpenLocation = { [weak self, weak controller] location in
            guard let self else { return }
            self.showWindow(nil); self.activePane.navigate(to: location); self.activePane.focusFiles()
            if let controller {
                self.activePane.selectFiles(controller.urls.filter { $0.deletingLastPathComponent() == location })
            }
        }
        controller.onRename = { [weak self] source, name, completion in
            do {
                guard let self else { throw CocoaError(.userCancelled) }
                guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0"), !name.contains(":") else {
                    throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteInvalidFileNameError, userInfo: [NSLocalizedDescriptionKey: "Choose a name without / or :."])
                }
                guard let identity = identities[source] else { throw CocoaError(.fileNoSuchFile) }
                let destination = source.deletingLastPathComponent().appendingPathComponent(name, isDirectory: source.hasDirectoryPath)
                try self.performMoveWithUndo(from: source, to: destination, actionName: "Rename", expected: identity)
                identities.removeValue(forKey: source); identities[destination] = FileIdentity(url: destination)
                completion(.success(destination))
            } catch { completion(.failure(error)) }
        }
        propertiesWindows[id] = controller
        controller.showWindow(nil)
    }
    private func readClipboard() -> [URL] {
        if clipboardChangeCount == pasteboard.changeCount { return clipboardURLs }
        return (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }
    private func putClipboard(cut: Bool) {
        let urls = activePane.selectedURLs; guard !urls.isEmpty else { return }
        pasteboard.clearContents(); pasteboard.writeObjects(urls as [NSURL])
        clipboardURLs = urls; clipboardIsCut = cut; clipboardChangeCount = pasteboard.changeCount
        clipboardState.notify(); updateButtons()
    }
    private var isCurrentCutPasteRunning: Bool {
        clipboardIsCut && clipboardState.runningCutChanges.contains(pasteboard.changeCount)
    }
    private func paste() {
        clipboardState.refresh(from: pasteboard)
        guard !isCurrentCutPasteRunning else { return }
        let urls = readClipboard(); guard !urls.isEmpty, !isVirtualLocation else { return }
        let cut = clipboardIsCut && clipboardChangeCount == pasteboard.changeCount
        let snapshot = cut ? CutPasteSnapshot(changeCount: clipboardChangeCount, sources: urls,
            identities: Dictionary(uniqueKeysWithValues: urls.compactMap { url in FileIdentity(url: url).map { (url, $0) } })) : nil
        let id = startTransfer(kind: cut ? .move : .copy, sources: urls, destination: activePane.currentURL)
        if let snapshot {
            cutPasteJobs[id] = snapshot
            clipboardState.runningCutChanges.insert(snapshot.changeCount)
            clipboardState.notify()
        }
        activePane.focusFiles(); updateButtons()
    }
    private func finishCutPaste(_ id: UUID) {
        guard let snapshot = cutPasteJobs.removeValue(forKey: id) else { return }
        clipboardState.runningCutChanges.remove(snapshot.changeCount)
        defer { clipboardState.notify() }
        guard clipboardIsCut,
              clipboardChangeCount == snapshot.changeCount, pasteboard.changeCount == snapshot.changeCount else { return }
        // A cancelled or failed move stays ready to retry. Completed sources leave the Cut selection.
        let remaining = snapshot.sources.filter { url in
            guard let identity = snapshot.identities[url] else { return false }
            return FileIdentity(url: url) == identity
        }
        if remaining != clipboardURLs {
            pasteboard.clearContents()
            if !remaining.isEmpty { pasteboard.writeObjects(remaining as [NSURL]) }
            clipboardURLs = remaining; clipboardChangeCount = pasteboard.changeCount
        }
        clipboardIsCut = !remaining.isEmpty
        updateButtons()
    }
    @discardableResult
    private func startTransfer(kind: TransferKind, sources: [URL], destination: URL) -> UUID {
        drawer.isHidden = false
        let id = engine.start(kind: kind, sources: sources, destination: destination, onProgress: { [weak self] progress in
            guard let self else { return }
            self.jobs[progress.id] = progress; self.drawer.update(progress); self.updateButtons()
            if self.isTerminal(progress.phase) {
                self.pendingJobIDs.remove(progress.id)
                self.finishCutPaste(progress.id)
                BrowserSearchSupport.index.invalidate(in: destination, recursive: false)
                if kind == .move {
                    for parent in Set(sources.map { $0.deletingLastPathComponent() }) {
                        BrowserSearchSupport.index.invalidate(in: parent, recursive: false)
                    }
                }
                self.left.reload(); self.right.reload(); self.sidebar.refresh()
                self.conflicts.removeAll { $0.0.jobID == progress.id }
                if self.pendingConflictID == progress.id { self.pendingDialog?.cancel() }
                self.transfersDidFinish()
            }
        }, onConflict: { [weak self] conflict, reply in
            guard let self else { reply(ConflictResolution(choice: .cancel)); return }
            guard self.jobs[conflict.jobID].map({ !self.isTerminal($0.phase) }) ?? true else { reply(ConflictResolution(choice: .cancel)); return }
            self.conflicts.append((conflict, reply)); self.presentNextConflict()
        })
        pendingJobIDs.insert(id)
        return id
    }
    func cancelAllTransfers() {
        for id in pendingJobIDs { engine.cancel(id) }
        aliasCancellation?.cancel()
    }
    private func isTerminal(_ phase: TransferPhase) -> Bool { phase == .completed || phase == .cancelled || phase == .failed }
    private func presentNextConflict() {
        conflicts.removeAll { jobs[$0.0.jobID].map { isTerminal($0.phase) } ?? false }
        guard !showingConflict, window?.attachedSheet == nil, !conflicts.isEmpty, let content = window?.contentView else { return }
        let (conflict, reply) = conflicts.removeFirst(); showingConflict = true
        drawerVisibleBeforeConflict = !drawer.isHidden; drawer.isHidden = true
        let overlay = ModalScrimView(); content.addSubview(overlay); edgePin(overlay, to: content)
        let dialog = ConflictDialogView(conflict: conflict, moving: jobs[conflict.jobID]?.kind == .move) { [weak self] resolution in
            guard let self else { reply(ConflictResolution(choice: .cancel)); return }
            self.conflictOverlay?.removeFromSuperview(); self.conflictOverlay = nil
            self.pendingDialog = nil; self.pendingConflictID = nil; self.showingConflict = false
            self.updateButtons()
            self.drawer.isHidden = !self.drawerVisibleBeforeConflict
            reply(resolution)
            self.activePane.focusFiles()
            self.presentNextConflict()
        }
        dialog.translatesAutoresizingMaskIntoConstraints = false; overlay.addSubview(dialog)
        NSLayoutConstraint.activate([dialog.centerXAnchor.constraint(equalTo: overlay.centerXAnchor), dialog.centerYAnchor.constraint(equalTo: overlay.centerYAnchor, constant: 24), dialog.widthAnchor.constraint(equalToConstant: 730), dialog.heightAnchor.constraint(equalToConstant: 600)])
        conflictOverlay = overlay; pendingDialog = dialog; pendingConflictID = conflict.jobID
        window?.makeFirstResponder(dialog); updateButtons()
    }
    private func promptName(title: String, initial: String, selectStem: Bool = false, completion: @escaping (String) -> Void) {
        guard let window else { return }
        let alert = NSAlert(); alert.messageText = title
        alert.addButton(withTitle: "Save"); alert.addButton(withTitle: "Cancel")
        let field = NSTextField(string: initial); field.frame = NSRect(x: 0, y: 0, width: 360, height: 26)
        field.setAccessibilityIdentifier("name-input"); alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { self?.activePane.focusFiles(); return }
            let value = field.stringValue
            guard !value.isEmpty, value != ".", value != "..", !value.contains("/"), !value.contains("\0"), !value.contains(":") else { self?.showError("Choose a name without / or :."); return }
            completion(value)
            self?.activePane.focusFiles()
        }
        DispatchQueue.main.async {
            alert.window.makeFirstResponder(field); field.selectText(nil)
            if selectStem, let editor = field.currentEditor() as? NSTextView {
                let stem = (initial as NSString).deletingPathExtension
                editor.setSelectedRange(NSRange(location: 0, length: stem.utf16.count))
            }
        }
    }
    private func createItem(folder: Bool) {
        guard !isVirtualLocation else { return }
        let destination = activePane.currentURL
        let parentIdentity = FileIdentity(url: destination.resolvingSymlinksInPath())
        promptName(title: folder ? "New folder" : "New file", initial: folder ? "New Folder" : "Untitled.txt") { [weak self] name in
            guard let self else { return }
            let url = destination.appendingPathComponent(name)
            do {
                guard let parentIdentity, FileIdentity(url: destination.resolvingSymlinksInPath()) == parentIdentity else { self.showError("The destination folder changed. Open it again before creating an item."); return }
                if folder { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false) }
                else { try Data().write(to: url, options: [.withoutOverwriting]) }
                BrowserSearchSupport.index.invalidate(in: destination, recursive: false)
                self.refreshBrowsers()
                if self.activePane.currentURL == destination { self.activePane.selectFiles([url]) }
            } catch { self.showError(error.localizedDescription) }
        }
    }
    private func rename() {
        guard let url = activePane.selectedURLs.first, activePane.selectedURLs.count == 1 else { return }
        guard let identity = FileIdentity(url: url) else { showError("This item is no longer available."); return }
        let shortcut = AppShortcutDocument.isShortcut(url)
        let displayName = shortcut ? url.deletingPathExtension().lastPathComponent : url.lastPathComponent
        promptName(title: "Rename “\(displayName)”", initial: displayName, selectStem: !shortcut && !url.hasDirectoryPath && !url.pathExtension.isEmpty) { [weak self] name in
            let filename = shortcut && (name as NSString).pathExtension.lowercased() != AppShortcutDocument.fileExtension
                ? name + "." + AppShortcutDocument.fileExtension : name
            self?.moveWithUndo(from: url, to: url.deletingLastPathComponent().appendingPathComponent(filename), actionName: "Rename", expected: identity)
        }
    }
    private func moveWithUndo(from source: URL, to destination: URL, actionName: String, expected: FileIdentity? = nil) {
        do {
            try performMoveWithUndo(from: source, to: destination, actionName: actionName, expected: expected)
        } catch { showError(error.localizedDescription) }
    }
    private func performMoveWithUndo(from source: URL, to destination: URL, actionName: String, expected: FileIdentity? = nil) throws {
        if let expected, FileIdentity(url: source) != expected {
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError,
                userInfo: [NSLocalizedDescriptionKey: "This item was replaced or removed. Open the current item again before trying this operation."])
        }
        if source == destination { return }
        let selectedPanes = [left, right].filter { $0.selectedURLs.contains(source) }
        try FileMutation.renameWithoutReplacing(from: source, to: destination)
        BrowserSearchSupport.index.invalidate(in: source.deletingLastPathComponent(), recursive: false)
        if source.deletingLastPathComponent() != destination.deletingLastPathComponent() {
            BrowserSearchSupport.index.invalidate(in: destination.deletingLastPathComponent(), recursive: false)
        }
        if let identity = FileIdentity(url: destination) {
            fileUndo.registerUndo(withTarget: self) { $0.moveWithUndo(from: destination, to: source, actionName: actionName, expected: identity) }; fileUndo.setActionName(actionName)
        }
        left.relocateAfterMove(from: source, to: destination)
        right.relocateAfterMove(from: source, to: destination)
        refreshBrowsers()
        for pane in selectedPanes where pane.currentURL == destination.deletingLastPathComponent() { pane.selectFiles([destination]) }
    }
    private func trash() {
        let urls = activePane.selectedURLs; guard !urls.isEmpty, let window else { return }
        let identities = Dictionary(uniqueKeysWithValues: urls.compactMap { url in FileIdentity(url: url).map { (url, $0) } })
        let alert = NSAlert(); alert.messageText = "Move \(urls.count == 1 ? "“\(urls[0].lastPathComponent)”" : "\(urls.count) items") to Trash?"
        alert.informativeText = "You can undo this move or restore the items from Trash."
        alert.addButton(withTitle: "Move to Trash"); alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            var errors: [String] = []; self.fileUndo.beginUndoGrouping()
            for url in urls {
                do {
                    guard let identity = identities[url], FileIdentity(url: url) == identity else { errors.append("\(url.lastPathComponent): the item was replaced or removed, so it was left untouched."); continue }
                    var trashed: NSURL?
                    try FileManager.default.trashItem(at: url, resultingItemURL: &trashed)
                    BrowserSearchSupport.index.invalidate(in: url.deletingLastPathComponent(), recursive: false)
                    if let trashed, let identity = FileIdentity(url: trashed as URL) { self.fileUndo.registerUndo(withTarget: self) { $0.moveWithUndo(from: trashed as URL, to: url, actionName: "Move to Trash", expected: identity) } }
                } catch { errors.append("\(url.lastPathComponent): \(error.localizedDescription)") }
            }
            self.fileUndo.endUndoGrouping(); self.fileUndo.setActionName("Move to Trash"); self.refreshBrowsers()
            if !errors.isEmpty { self.showError(errors.joined(separator: "\n")) }
        }
    }
    private func openWith() {
        let urls = activePane.selectedURLs; guard !urls.isEmpty, let window else { return }
        let picker = NSOpenPanel(); picker.title = "Choose an application"; picker.allowedContentTypes = [.application]; picker.directoryURL = URL(fileURLWithPath: "/Applications"); picker.canChooseDirectories = false
        picker.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let application = picker.url else { return }
            NSWorkspace.shared.open(urls, withApplicationAt: application, configuration: NSWorkspace.OpenConfiguration()) { _, error in
                if let error { DispatchQueue.main.async { self?.showError(error.localizedDescription) } }
            }
        }
    }
    private func refreshBrowsers() { left.reload(); right.reload(); sidebar.refresh(); updateButtons() }
    private func showOptions() {
        guard !showingConflict, window?.attachedSheet == nil else { return }
        if let optionsWindow { optionsWindow.showWindow(nil); optionsWindow.window?.makeKeyAndOrderFront(nil); return }
        let controller = ExplorerOptionsWindowController(preferences: settings.explorer)
        controller.onApply = { [weak self] preferences in self?.applyExplorerPreferences(preferences) }
        controller.onClose = { [weak self] in self?.optionsWindow = nil }
        optionsWindow = controller
        controller.showWindow(nil)
    }
    private func applyExplorerPreferences(_ preferences: ExplorerPreferences) {
        updateExplorerPreferences(preferences)
        if !temporarySession {
            var saved = AppStorage.load()
            saved.explorer = settings.explorer; saved.showHidden = settings.showHidden
            AppStorage.save(saved)
        }
        saveSettings()
        NotificationCenter.default.post(name: .fileManagerPreferencesChanged, object: self, userInfo: ["preferences": settings.explorer])
    }
    private func updateExplorerPreferences(_ preferences: ExplorerPreferences) {
        settings.explorer = preferences.normalized()
        settings.showHidden = settings.explorer.showHiddenFiles
        for pane in [left, right] {
            pane.setDisplayPreferences(showExtensions: settings.explorer.showFileExtensions,
                                       compact: settings.explorer.compactView,
                                       defaultViewMode: settings.explorer.defaultViewMode)
            pane.setHiddenFiles(settings.showHidden)
        }
    }
    @objc private func preferencesDidChange(_ notification: Notification) {
        guard notification.object as? MainWindowController !== self,
              let preferences = notification.userInfo?["preferences"] as? ExplorerPreferences,
              preferences != settings.explorer else { return }
        let wasRestoring = restoringSettings
        restoringSettings = true
        updateExplorerPreferences(preferences)
        restoringSettings = wasRestoring
    }
    private func chooseSendToFolder() {
        let sources = activePane.selectedURLs
        guard !sources.isEmpty, !showingConflict, let window, window.attachedSheet == nil else { return }
        let picker = NSOpenPanel()
        picker.title = "Send to folder"; picker.prompt = "Copy here"
        picker.message = "Copy the selected items to this folder. Originals will stay in place."
        picker.canChooseDirectories = true; picker.canChooseFiles = false; picker.canCreateDirectories = true
        picker.allowsMultipleSelection = false
        picker.directoryURL = FileManager.default.homeDirectoryForCurrentUser
        picker.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let destination = picker.url else { return }
            self?.startTransfer(kind: .copy, sources: sources, destination: destination)
        }
    }
    private func sendToDesktopAlias() {
        let sources = activePane.selectedURLs
        let desktop = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop", isDirectory: true)
        createAliases(for: sources, in: desktop)
    }
    private func canPasteShortcut(into pane: BrowserPaneViewController) -> Bool {
        guard pane.canReceiveFiles, !creatingAliases, !isCurrentCutPasteRunning, !showingConflict, window?.attachedSheet == nil,
              pane.currentURL.isFileURL, !readClipboard().isEmpty else { return false }
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: pane.currentURL.path, isDirectory: &isDirectory)
            && isDirectory.boolValue && FileManager.default.isWritableFile(atPath: pane.currentURL.path)
    }
    private func pasteShortcut() {
        guard canPasteShortcut(into: activePane) else { return }
        createAliases(for: readClipboard(), in: activePane.currentURL, selectIn: activePane)
    }
    private func createAliases(for sources: [URL], in destination: URL, selectIn pane: BrowserPaneViewController? = nil) {
        guard !sources.isEmpty, !creatingAliases, !showingConflict, window?.attachedSheet == nil else { return }
        let selectedTab = pane?.selectedTabIndex
        let cancellation = SendToService.Cancellation()
        aliasCancellation = cancellation; creatingAliases = true
        statusLabel.stringValue = "Creating shortcuts…"
        DispatchQueue.global(qos: .userInitiated).async { [weak self, weak pane] in
            let result = Result { try SendToService.createAliases(for: sources, in: destination, isCancelled: { cancellation.isCancelled }) }
            DispatchQueue.main.async { [weak self, weak pane] in
                guard let self else { return }
                self.creatingAliases = false; self.aliasCancellation = nil
                BrowserSearchSupport.index.invalidate(in: destination, recursive: false)
                self.refreshBrowsers()
                let createdURLs: [URL]
                switch result {
                case .success(let urls): createdURLs = urls
                case .failure(let error): createdURLs = (error as? SendToService.Failure)?.createdURLs ?? []
                }
                for url in createdURLs {
                    NSWorkspace.shared.setIcon(ShortcutSupport.icon(for: url, size: 128), forFile: url.path, options: [])
                }
                if let pane, pane.currentURL == destination, pane.selectedTabIndex == selectedTab,
                   !pane.isShowingRecents, !createdURLs.isEmpty { pane.selectFiles(createdURLs) }
                switch result {
                case .success(let urls):
                    self.statusLabel.stringValue = "Created \(urls.count) shortcut\(urls.count == 1 ? "" : "s")"
                case .failure(let error):
                    if !cancellation.isCancelled { self.showError(error.localizedDescription) }
                }
                self.transfersDidFinish()
            }
        }
    }
    func showError(_ message: String) {
        guard let window else { return }
        let alert = NSAlert(); alert.messageText = "The operation couldn’t be completed"; alert.informativeText = message; alert.addButton(withTitle: "OK"); alert.beginSheetModal(for: window)
    }
    func persistState() { saveSettings() }
    private func saveSettings() {
        guard !restoringSettings && !temporarySession, shouldPersistState?() ?? true else { return }
        settings.leftTabs = left.openDirectories.map { $0.isFileURL ? $0.path : $0.absoluteString }
        settings.rightTabs = right.openDirectories.map { $0.isFileURL ? $0.path : $0.absoluteString }
        settings.leftDisplay = left.displaySettings; settings.rightDisplay = right.displaySettings
        settings.leftSelectedTab = left.selectedTabIndex; settings.rightSelectedTab = right.selectedTabIndex
        settings.activeRightPane = !activeIsLeft
        settings.split = split; settings.preview = previewVisible; settings.singlePreview = singlePreviewVisible; AppStorage.save(settings)
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if hasRunningTransfers {
            guard !closingAfterTransfers, sender.attachedSheet == nil else { return false }
            let alert = NSAlert()
            alert.messageText = "Stop transfers and close this window?"
            alert.informativeText = "Transfers in this window will stop. Completed files will be kept. Other windows will stay open."
            alert.addButton(withTitle: "Keep working")
            alert.addButton(withTitle: "Stop and close")
            alert.beginSheetModal(for: sender) { [weak self] response in
                guard let self, response == .alertSecondButtonReturn else { return }
                self.closingAfterTransfers = true
                if self.hasRunningTransfers { self.cancelAllTransfers() }
                else { self.window?.performClose(nil) }
            }
            return false
        }
        saveSettings(); return true
    }
    func windowWillClose(_ notification: Notification) {
        for controller in Array(propertiesWindows.values) { controller.close() }
        propertiesWindows.removeAll()
        optionsWindow?.close(); optionsWindow = nil
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor); self.eventMonitor = nil }
        refreshTimer?.invalidate(); refreshTimer = nil
        NotificationCenter.default.removeObserver(self)
        onClosed?()
    }
    func activateMenus() { installMenus() }
    func windowDidBecomeMain(_ notification: Notification) {
        onBecameMain?()
        activateMenus()
        updateButtons()
        saveSettings()
    }
    @objc private func clipboardDidChange() { updateButtons() }
    private func transfersDidFinish() {
        guard !hasRunningTransfers else { return }
        let callback = whenTransfersStop; whenTransfersStop = nil
        callback?()
        if closingAfterTransfers { window?.performClose(nil) }
    }
    @objc private func sheetDidEnd() { DispatchQueue.main.async { [weak self] in self?.updateButtons(); self?.presentNextConflict() } }
    @objc private func didBecomeActive() { left.reload(); right.reload(); updateButtons() }
    private func saveSnapshot(to url: URL) {
        if let content = window?.contentView {
            func describe(_ view: NSView, depth: Int = 0) -> String {
                let line = String(repeating: " ", count: depth) + "\(type(of: view)) frame=\(view.frame) hidden=\(view.isHidden) ambiguous=\(view.hasAmbiguousLayout)\n"
                return line + view.subviews.map { describe($0, depth: depth + 1) }.joined()
            }
            try? describe(content).write(to: url.deletingPathExtension().appendingPathExtension("layout.txt"), atomically: true, encoding: .utf8)
        }
        guard let view = window?.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        do { try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true); try data.write(to: url) } catch { NSLog("Snapshot error: %@", error.localizedDescription) }
    }

    private func showNewMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: "New Folder", action: #selector(newFolderAction), keyEquivalent: "").target = self
        menu.addItem(withTitle: "New File…", action: #selector(newFileAction), keyEquivalent: "").target = self
        popUp(menu, at: "New")
    }
    private func showSortMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false
        if activePane.isSearching {
            let best = menu.addItem(withTitle: "Best match", action: #selector(sortAction(_:)), keyEquivalent: "")
            best.representedObject = "bestMatch"; best.target = self
            best.state = activePane.currentSortKey == "bestMatch" ? .on : .off
            menu.addItem(.separator())
        }
        for (name, key) in [("Name", "name"), ("Date modified", "date"), ("Size", "size"), ("Type", "type")] {
            let item = menu.addItem(withTitle: name, action: #selector(sortAction(_:)), keyEquivalent: ""); item.representedObject = key; item.target = self
            item.state = activePane.currentSortKey == key ? .on : .off
        }
        menu.addItem(.separator())
        for (name, ascending) in [("Ascending", true), ("Descending", false)] {
            let item = menu.addItem(withTitle: name, action: #selector(sortDirectionAction(_:)), keyEquivalent: "")
            item.representedObject = ascending; item.target = self; item.state = activePane.currentSortAscending == ascending ? .on : .off
            item.isEnabled = activePane.currentSortKey != "bestMatch"
        }
        menu.addItem(.separator())
        let grouping = NSMenuItem(title: "Group by", action: nil, keyEquivalent: "")
        grouping.submenu = makeGroupingMenu(); menu.addItem(grouping)
        popUp(menu, at: "Sort")
    }
    private func makeGroupingMenu() -> NSMenu {
        let menu = NSMenu(title: "Group by")
        for (title, key) in [("None", "none"), ("Name", "name"), ("Date modified", "date"), ("Type", "type"), ("Size", "size")] {
            let item = menu.addItem(withTitle: title, action: #selector(groupAction(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = key
            item.state = activePane.currentGroupBy == key ? .on : .off
        }
        return menu
    }
    private func appendLayoutItems(to menu: NSMenu) {
        for (mode, name) in ExplorerPreferences.viewModes {
            let item = menu.addItem(withTitle: name, action: #selector(viewAction(_:)), keyEquivalent: "")
            item.representedObject = mode; item.target = self
            item.state = activePane.currentViewMode == mode ? .on : .off
        }
    }
    private func makeSendToMenu() -> NSMenu {
        let menu = NSMenu(title: "Send to")
        menu.addItem(withTitle: "Desktop (create shortcut)", action: #selector(desktopAliasAction), keyEquivalent: "").target = self
        menu.addItem(.separator())
        let home = FileManager.default.homeDirectoryForCurrentUser
        for name in ["Documents", "Downloads"] {
            let item = menu.addItem(withTitle: name, action: #selector(sendToCopyAction(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = home.appendingPathComponent(name, isDirectory: true)
        }
        menu.addItem(withTitle: "Choose folder…", action: #selector(sendToChooseAction), keyEquivalent: "").target = self
        return menu
    }
    private func showViewMenu() {
        let menu = NSMenu()
        appendLayoutItems(to: menu)
        menu.addItem(.separator())
        let compact = menu.addItem(withTitle: "Compact view", action: #selector(compactAction), keyEquivalent: "")
        compact.target = self; compact.state = settings.explorer.compactView ? .on : .off
        let grouping = NSMenuItem(title: "Group by", action: nil, keyEquivalent: "")
        grouping.submenu = makeGroupingMenu(); menu.addItem(grouping)
        menu.addItem(withTitle: "Choose columns…", action: #selector(columnsAction), keyEquivalent: "").target = self
        menu.addItem(.separator())
        let extensions = menu.addItem(withTitle: "File name extensions", action: #selector(extensionsAction), keyEquivalent: "")
        extensions.target = self; extensions.state = settings.explorer.showFileExtensions ? .on : .off
        let hidden = menu.addItem(withTitle: "Show Hidden Files", action: #selector(hiddenAction), keyEquivalent: ""); hidden.state = settings.showHidden ? .on : .off; hidden.target = self
        menu.addItem(withTitle: "File transfers", action: #selector(transfersAction), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Properties…", action: #selector(propertiesAction), keyEquivalent: "").target = self
        menu.addItem(withTitle: "File Explorer Options…", action: #selector(optionsAction), keyEquivalent: "").target = self
        popUp(menu, at: "View")
    }
    private func popUp(_ menu: NSMenu, at title: String) {
        guard let button = buttons[title] else { return }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.minY - 4), in: button)
    }
    @objc private func sortAction(_ sender: NSMenuItem) { activePane.setSort(key: sender.representedObject as? String ?? "name", ascending: activePane.currentSortAscending) }
    @objc private func sortDirectionAction(_ sender: NSMenuItem) { activePane.setSort(key: activePane.currentSortKey, ascending: sender.representedObject as? Bool ?? true) }
    @objc private func viewAction(_ sender: NSMenuItem) { activePane.setViewMode(sender.representedObject as? String ?? "details") }
    @objc private func groupAction(_ sender: NSMenuItem) { activePane.setGroupBy(sender.representedObject as? String ?? "none") }
    @objc private func hiddenAction() { var preferences = settings.explorer; preferences.showHiddenFiles.toggle(); applyExplorerPreferences(preferences) }
    @objc private func compactAction() { var preferences = settings.explorer; preferences.compactView.toggle(); applyExplorerPreferences(preferences) }
    @objc private func extensionsAction() { var preferences = settings.explorer; preferences.showFileExtensions.toggle(); applyExplorerPreferences(preferences) }
    @objc private func optionsAction() { showOptions() }
    @objc private func columnsAction() { if let anchor = buttons["View"] { activePane.showColumnMenu(relativeTo: anchor) } }
    @objc private func thisMacAction() { activePane.showThisMac() }
    @objc private func desktopAliasAction() { sendToDesktopAlias() }
    @objc private func sendToChooseAction() { chooseSendToFolder() }
    @objc private func sendToCopyAction(_ sender: NSMenuItem) {
        guard let destination = sender.representedObject as? URL, !activePane.selectedURLs.isEmpty else { return }
        startTransfer(kind: .copy, sources: activePane.selectedURLs, destination: destination)
    }
    @objc private func newFolderAction() { createItem(folder: true) }
    @objc private func newFileAction() { createItem(folder: false) }
    @objc private func cutAction() { putClipboard(cut: true) }
    @objc private func copyAction() { putClipboard(cut: false) }
    @objc private func pasteAction() { paste() }
    @objc private func pasteShortcutAction() { pasteShortcut() }
    @objc private func renameAction() { rename() }
    @objc private func propertiesAction() { showProperties() }
    @objc private func trashAction() { trash() }
    @objc private func transfersAction() { toggleTransfers() }
    @objc private func splitAction() { toggleSplit() }
    @objc private func previewAction() { togglePreview() }
    @objc private func undoAction() {
        if let editor = NSApp.keyWindow?.firstResponder as? NSTextView { editor.undoManager?.undo() }
        else if NSApp.keyWindow === window { fileUndo.undo() }
    }
    @objc private func redoAction() {
        if let editor = NSApp.keyWindow?.firstResponder as? NSTextView { editor.undoManager?.redo() }
        else if NSApp.keyWindow === window { fileUndo.redo() }
    }
    @objc private func newTabAction() { activePane.addTab() }
    @objc private func newWindowAction() { onOpenNewWindow?(isVirtualLocation ? nil : activePane.currentURL) }
    @objc private func closeTabAction() { activePane.closeCurrentTab() }
    @objc private func refreshAction() {
        for pane in [left, right] where pane.currentURL.isFileURL {
            BrowserSearchSupport.index.invalidate(in: pane.currentURL)
        }
        refreshBrowsers()
    }
    @objc private func backAction() { activePane.goBack() }
    @objc private func forwardAction() { activePane.goForward() }
    @objc private func upAction() { activePane.goUp() }
    @objc private func addressAction() { activePane.focusAddress() }
    @objc private func searchAction() { activePane.focusSearch() }
    @objc private func chooseFolderAction() {
        guard let window else { return }
        let picker = NSOpenPanel(); picker.canChooseDirectories = true; picker.canChooseFiles = false; picker.title = "Open folder"
        picker.directoryURL = isVirtualLocation ? FileManager.default.homeDirectoryForCurrentUser : activePane.currentURL
        picker.beginSheetModal(for: window) { [weak self] response in if response == .OK, let url = picker.url { self?.activePane.navigate(to: url) } }
    }
    private func installMenus() {
        let bar = NSMenu(); NSApp.mainMenu = bar
        func submenu(_ name: String) -> NSMenu {
            let item = NSMenuItem(); item.title = name; let menu = NSMenu(title: name); item.submenu = menu; bar.addItem(item); return menu
        }
        func item(_ menu: NSMenu, _ title: String, _ action: Selector, _ key: String = "", modifiers: NSEvent.ModifierFlags = .command) {
            let entry = menu.addItem(withTitle: title, action: action, keyEquivalent: key); entry.target = self; entry.keyEquivalentModifierMask = modifiers
        }
        let app = submenu("WinExplorer for Mac")
        let about = app.addItem(withTitle: "About WinExplorer for Mac", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: ""); about.target = NSApp
        app.addItem(.separator())
        item(app, "File Explorer Options…", #selector(optionsAction), ",")
        app.addItem(.separator())
        let quit = app.addItem(withTitle: "Quit WinExplorer for Mac", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"); quit.target = NSApp
        let file = submenu("File")
        item(file, "New Window", #selector(newWindowAction), "n")
        item(file, "Open Folder…", #selector(chooseFolderAction), "o")
        item(file, "New Folder…", #selector(newFolderAction), "n", modifiers: [.command, .shift])
        item(file, "New File…", #selector(newFileAction))
        file.addItem(.separator()); item(file, "New Tab", #selector(newTabAction), "t"); item(file, "Close Tab", #selector(closeTabAction), "w")
        file.addItem(.separator()); item(file, "Rename…", #selector(renameAction)); item(file, "Move to Trash…", #selector(trashAction), "\u{8}")
        let sendTo = NSMenuItem(title: "Send to", action: nil, keyEquivalent: "")
        sendTo.submenu = makeSendToMenu(); file.addItem(sendTo)
        file.addItem(.separator()); item(file, "Properties…", #selector(propertiesAction), "i")
        let edit = submenu("Edit")
        item(edit, "Undo File Operation", #selector(undoAction), "z"); item(edit, "Redo File Operation", #selector(redoAction), "z", modifiers: [.command, .shift]); edit.addItem(.separator())
        // Standard responder selectors preserve native editing in address/search fields.
        for (title, selector, key) in [("Cut", #selector(NSText.cut(_:)), "x"), ("Copy", #selector(NSText.copy(_:)), "c"), ("Paste", #selector(NSText.paste(_:)), "v"), ("Select All", #selector(NSText.selectAll(_:)), "a")] {
            edit.addItem(withTitle: title, action: selector, keyEquivalent: key)
            if title == "Paste" { item(edit, "Paste shortcut", #selector(pasteShortcutAction)) }
        }
        let view = submenu("View")
        let layout = NSMenuItem(title: "Layout", action: nil, keyEquivalent: "")
        let layouts = NSMenu(title: "Layout"); appendLayoutItems(to: layouts); layout.submenu = layouts; view.addItem(layout)
        item(view, "Compact view", #selector(compactAction))
        let grouping = NSMenuItem(title: "Group by", action: nil, keyEquivalent: "")
        grouping.submenu = makeGroupingMenu(); view.addItem(grouping)
        item(view, "Choose columns…", #selector(columnsAction))
        view.addItem(.separator())
        item(view, "Split View", #selector(splitAction), "s", modifiers: [.command, .shift]); item(view, "Preview", #selector(previewAction), "p", modifiers: [.command, .shift])
        item(view, "File name extensions", #selector(extensionsAction))
        item(view, "Show Hidden Files", #selector(hiddenAction), ".", modifiers: [.command, .shift]); item(view, "Refresh", #selector(refreshAction), "r")
        item(view, "File Transfers", #selector(transfersAction))
        view.addItem(.separator()); item(view, "File Explorer Options…", #selector(optionsAction))
        let go = submenu("Go"); item(go, "This Mac", #selector(thisMacAction)); go.addItem(.separator())
        item(go, "Back", #selector(backAction), "["); item(go, "Forward", #selector(forwardAction), "]"); item(go, "Parent Folder", #selector(upAction), String(UnicodeScalar(NSUpArrowFunctionKey)!), modifiers: .command); item(go, "Address Bar", #selector(addressAction), "l"); item(go, "Search Folder", #selector(searchAction), "f")
        let windowMenu = submenu("Window"); NSApp.windowsMenu = windowMenu
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
    }
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(newWindowAction) { return onOpenNewWindow != nil }
        if showingConflict { return false }
        if window?.attachedSheet != nil && menuItem.action != #selector(undoAction) && menuItem.action != #selector(redoAction) { return false }
        if let keyWindow = NSApp.keyWindow, keyWindow !== window,
           menuItem.action != #selector(undoAction), menuItem.action != #selector(redoAction) { return false }
        switch menuItem.action {
        case #selector(newFolderAction), #selector(newFileAction): return !isVirtualLocation
        case #selector(undoAction):
            if let editor = NSApp.keyWindow?.firstResponder as? NSTextView { return editor.undoManager?.canUndo ?? false }
            return NSApp.keyWindow === window && fileUndo.canUndo
        case #selector(redoAction):
            if let editor = NSApp.keyWindow?.firstResponder as? NSTextView { return editor.undoManager?.canRedo ?? false }
            return NSApp.keyWindow === window && fileUndo.canRedo
        case #selector(renameAction): return activePane.selectedURLs.count == 1
        case #selector(propertiesAction): return !activePane.selectedURLs.isEmpty || (!isVirtualLocation && FileIdentity(url: activePane.currentURL) != nil)
        case #selector(trashAction), #selector(cutAction), #selector(copyAction): return !activePane.selectedURLs.isEmpty
        case #selector(desktopAliasAction): return !creatingAliases && !activePane.selectedURLs.isEmpty
        case #selector(pasteShortcutAction): return canPasteShortcut(into: activePane)
        case #selector(sendToCopyAction(_:)), #selector(sendToChooseAction): return !activePane.selectedURLs.isEmpty
        case #selector(viewAction(_:)):
            menuItem.state = (menuItem.representedObject as? String) == activePane.currentViewMode ? .on : .off
            return !activePane.isShowingThisMac
        case #selector(groupAction(_:)):
            menuItem.state = (menuItem.representedObject as? String) == activePane.currentGroupBy ? .on : .off
            return !activePane.isShowingThisMac
        case #selector(columnsAction): return !activePane.isShowingThisMac
        case #selector(compactAction): menuItem.state = settings.explorer.compactView ? .on : .off; return true
        case #selector(extensionsAction): menuItem.state = settings.explorer.showFileExtensions ? .on : .off; return true
        case #selector(hiddenAction): menuItem.state = settings.showHidden ? .on : .off; return true
        case #selector(splitAction): menuItem.state = split ? .on : .off; return true
        case #selector(previewAction): menuItem.state = previewVisible ? .on : .off; return true
        default: return true
        }
    }
    private func installKeyboardMonitor() {
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.window || event.window === self.window?.attachedSheet else { return event }
            if event.window === self.window {
                let endedLeft = self.left.endSelectionGesture(cancelled: event.keyCode == 53)
                let endedRight = self.right.endSelectionGesture(cancelled: event.keyCode == 53)
                if (endedLeft || endedRight) && event.keyCode == 53 { return nil }
            }
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let key = shortcutKey(for: event)
            let controlOnly = modifiers.contains(.control) && !modifiers.contains(.command) && !modifiers.contains(.option)
            let editor = event.window?.firstResponder as? NSTextView
            // Windows text shortcuts must edit text, including in name dialogs.
            if controlOnly, let editor {
                switch key {
                case "a": editor.selectAll(nil)
                case "c": editor.copy(nil)
                case "x": if editor.isEditable { editor.cut(nil) }
                case "v": if editor.isEditable { editor.paste(nil) }
                case "z": if editor.isEditable { modifiers.contains(.shift) ? editor.undoManager?.redo() : editor.undoManager?.undo() }
                case "y": if editor.isEditable { editor.undoManager?.redo() }
                default: break
                }
                if ["a", "c", "x", "v", "z", "y"].contains(key) { return nil }
            }
            guard self.window?.attachedSheet == nil else { return event }
            if let dialog = self.pendingDialog {
                if modifiers.contains(.command) && key == "q" { return event }
                if event.keyCode == 53 { dialog.cancel() }
                else if event.keyCode == 36 || event.keyCode == 76 { dialog.chooseDefault() }
                else if event.keyCode == 48 { dialog.moveFocus(backwards: modifiers.contains(.shift)) }
                else if event.keyCode == 49, let responder = self.window?.firstResponder as? NSView, responder === dialog || responder.isDescendant(of: dialog) { return event }
                return nil
            }
            if editor == nil, modifiers.intersection([.command, .control, .option, .shift]) == .option,
               event.keyCode == 36 || event.keyCode == 76 { self.showProperties(); return nil }
            let shortcut = !modifiers.contains(.option) && (modifiers.contains(.command) || modifiers.contains(.control))
            guard shortcut else { return event }
            // Preserve native Command-based text editing, but keep global navigation available.
            if editor != nil && ["a", "c", "x", "v", "z", "y"].contains(key) { return event }
            switch key {
            case "a": self.activePane.selectAllFiles()
            case "x": self.putClipboard(cut: true)
            case "c": self.putClipboard(cut: false)
            case "v": self.paste()
            case "l": self.activePane.focusAddress()
            case "f": self.activePane.focusSearch()
            case "i": self.showProperties()
            case ",": self.showOptions()
            case "t": self.activePane.addTab()
            case "w": self.activePane.closeCurrentTab()
            case "n" where modifiers.contains(.shift): self.createItem(folder: true)
            case "n": self.newWindowAction()
            case "r": self.refreshAction()
            case "z": modifiers.contains(.shift) ? self.fileUndo.redo() : self.fileUndo.undo()
            case "y" where controlOnly: self.fileUndo.redo()
            default: return event
            }
            return nil
        }
    }
}
