import AppKit

private final class SidebarNode: NSObject {
    var title: String
    let url: URL?
    let symbol: String
    let isGroup: Bool
    let isRecents: Bool
    var canExpand: Bool
    var canEject: Bool
    var depth: Int
    var children: [SidebarNode]?
    var loading = false
    var reloadRequested = false
    var loadFailed = false
    var loadedSelection: String?
    var detail: String?
    lazy var placeholder = SidebarNode(title: "Loading…", symbol: "", canExpand: false, depth: depth + 1)
    init(title: String, url: URL? = nil, symbol: String = "folder", isGroup: Bool = false,
         isRecents: Bool = false, canExpand: Bool = true, canEject: Bool = false,
         depth: Int = 0, children: [SidebarNode]? = nil) {
        self.title = title; self.url = url; self.symbol = symbol; self.isGroup = isGroup
        self.isRecents = isRecents; self.canExpand = canExpand; self.canEject = canEject
        self.depth = depth; self.children = children
    }
}

private final class SidebarFlippedView: NSView {
    override var isFlipped: Bool { true }
}

private final class SidebarSelectionRow: NSTableRowView {
    var indent: CGFloat = 0
    private lazy var hoverState = PointerHoverState(view: self) { [weak self] _ in self?.needsDisplay = true }
    private var hovered: Bool { hoverState.isHovered }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        hoverState.updateTrackingAreas()
    }
    override func prepareForReuse() { super.prepareForReuse(); hoverState.reset() }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); hoverState.reset() }
    override func viewDidMoveToSuperview() { super.viewDidMoveToSuperview(); if superview == nil { hoverState.reset() } }
    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }
    override func drawSelection(in dirtyRect: NSRect) {
        guard isSelected else { return }
        NSColor(calibratedRed: 0.80, green: 0.88, blue: 0.985, alpha: 1).setFill()
        let rect = NSRect(x: 4 + indent, y: 1, width: max(0, bounds.width - 8 - indent), height: max(0, bounds.height - 2))
        NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7).fill()
    }
    override func drawBackground(in dirtyRect: NSRect) {
        guard hovered, !isSelected else { return }
        NSColor(calibratedWhite: 0.90, alpha: 1).setFill()
        let rect = NSRect(x: 4 + indent, y: 1, width: max(0, bounds.width - 8 - indent), height: max(0, bounds.height - 2))
        NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7).fill()
    }
}

private class SidebarHoverButton: NSButton {
    private lazy var hoverState = PointerHoverState(view: self) { [weak self] _ in self?.needsDisplay = true }
    var hovered: Bool { isEnabled && hoverState.isHovered }
    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsetsZero }
    override var acceptsFirstResponder: Bool { isEnabled }
    override var isEnabled: Bool { didSet { if oldValue != isEnabled { hoverState.reset(); needsDisplay = true } } }
    override func becomeFirstResponder() -> Bool { needsDisplay = true; return super.becomeFirstResponder() }
    override func resignFirstResponder() -> Bool { needsDisplay = true; return super.resignFirstResponder() }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        hoverState.updateTrackingAreas()
    }
    override func prepareForReuse() { super.prepareForReuse(); hoverState.reset() }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); hoverState.reset() }
    override func viewDidMoveToSuperview() { super.viewDidMoveToSuperview(); if superview == nil { hoverState.reset() } }
    func drawKeyboardFocus() {
        guard window?.firstResponder === self else { return }
        NSColor.keyboardFocusIndicatorColor.setStroke()
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 6, yRadius: 6)
        path.lineWidth = 2; path.stroke()
    }
}

private final class SidebarIconButton: SidebarHoverButton {
    var handler: (() -> Void)?
    init(symbol: String, label: String, action: @escaping () -> Void) {
        super.init(frame: .zero)
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .regular))
        isBordered = false; imagePosition = .imageOnly; contentTintColor = .black
        target = self; self.action = #selector(performAction); handler = action
        setAccessibilityLabel(label); toolTip = label
    }
    required init?(coder: NSCoder) { fatalError("Programmatic button") }
    override func draw(_ dirtyRect: NSRect) {
        if hovered || cell?.isHighlighted == true {
            NSColor(calibratedWhite: cell?.isHighlighted == true ? 0.83 : 0.89, alpha: 1).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 1), xRadius: 5, yRadius: 5).fill()
        }
        super.draw(dirtyRect); drawKeyboardFocus()
    }
    @objc private func performAction() { handler?() }
}

private final class SidebarOutline: NSOutlineView {
    var handleArrow: ((Bool) -> Bool)?
    // Keep native expand/collapse enabled while drawing our own compact chevron.
    override func frameOfOutlineCell(atRow row: Int) -> NSRect { .zero }
    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
           event.keyCode == 123 || event.keyCode == 124,
           handleArrow?(event.keyCode == 124) == true { return }
        super.keyDown(with: event)
    }
}

private final class SidebarShortcutButton: SidebarHoverButton {
    var handler: (() -> Void)?
    var chosen = false { didSet { state = chosen ? .on : .off; needsDisplay = true } }
    init(title: String, symbol: String, action: @escaping () -> Void) {
        super.init(frame: .zero)
        self.title = title; handler = action; isBordered = false; clipsToBounds = true
        font = .systemFont(ofSize: 18); target = self; self.action = #selector(invoke)
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 21, weight: .regular))
        setAccessibilityLabel(title)
    }
    required init?(coder: NSCoder) { fatalError("Programmatic button") }
    override var intrinsicContentSize: NSSize { NSSize(width: 180, height: 35) }
    override func draw(_ dirtyRect: NSRect) {
        if chosen {
            NSColor(calibratedRed: 0.80, green: 0.88, blue: 0.985, alpha: 1).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 4, dy: 1), xRadius: 7, yRadius: 7).fill()
        } else if hovered || cell?.isHighlighted == true {
            NSColor(calibratedWhite: cell?.isHighlighted == true ? 0.86 : 0.90, alpha: 1).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 4, dy: 1), xRadius: 7, yRadius: 7).fill()
        }
        image?.draw(in: NSRect(x: 16, y: (bounds.height - 23) / 2, width: 23, height: 23))
        let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byTruncatingMiddle
        let attributes: [NSAttributedString.Key: Any] = [.font: font ?? NSFont.systemFont(ofSize: 18), .foregroundColor: NSColor.black, .paragraphStyle: paragraph]
        let size = title.size(withAttributes: attributes)
        title.draw(in: NSRect(x: 49, y: (bounds.height - size.height) / 2, width: max(0, bounds.width - 57), height: size.height), withAttributes: attributes)
        drawKeyboardFocus()
    }
    @objc private func invoke() { handler?() }
}

/// Compact hierarchy matching the approved design. Hidden folders are revealed
/// only when they are on a path the user explicitly navigated to.
final class SidebarViewController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
    var onNavigate: ((URL) -> Void)?
    var onProperties: ((URL) -> Void)?
    var onRecents: (() -> Void)?
    var onThisMac: (() -> Void)?
    private let outline = SidebarOutline()
    private let scroll = NSScrollView()
    private let quickAccess = NSStackView()
    private let foldersHeader = NSView()
    private let locations = NSStackView()
    private let locationRows = NSStackView()
    private let locationScroll = NSScrollView()
    private var locationHeight: NSLayoutConstraint?
    private var quickButtons: [SidebarShortcutButton] = []
    private var locationButtons: [SidebarShortcutButton] = []
    private var thisMacButton: SidebarShortcutButton?
    private var roots: [SidebarNode] = []
    private var activeVolume: SidebarNode?
    private var treeRoots: [SidebarNode] { (roots.count > 1 ? roots[1].children ?? [] : []) + (activeVolume.map { [$0] } ?? []) }
    private var selectedURL: URL?
    private var recentsSelected = false
    private var thisMacSelected = false
    private var pendingRevealPath: String?
    private var selectingProgrammatically = false
    private var expandedPaths = Set<String>()
    private var observers: [NSObjectProtocol] = []
    private var volumeGeneration = 0
    private let loadingQueue = DispatchQueue(label: "FileManager.sidebar", qos: .userInitiated, attributes: .concurrent)

    init() { super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        view = NSView(); view.wantsLayer = true; view.clipsToBounds = true
        view.layer?.backgroundColor = NSColor(calibratedWhite: 0.953, alpha: 1).cgColor
        outline.identifier = NSUserInterfaceItemIdentifier("folderSidebar")
        outline.setAccessibilityLabel("Folders and locations")
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("folder"))
        column.title = "Folders"; column.minWidth = 180; column.width = 240
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column); outline.outlineTableColumn = column
        outline.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        outline.headerView = nil; outline.dataSource = self; outline.delegate = self
        outline.rowHeight = 35; outline.intercellSpacing = .zero
        outline.indentationPerLevel = 0; outline.style = .plain
        outline.selectionHighlightStyle = .regular
        outline.backgroundColor = .clear; outline.floatsGroupRows = false
        outline.usesAlternatingRowBackgroundColors = false; outline.allowsEmptySelection = true
        outline.focusRingType = .none; outline.target = self; outline.action = #selector(rowClicked)
        outline.handleArrow = { [weak self] expanding in self?.handleArrow(expanding: expanding) ?? false }
        let menu = NSMenu(); menu.delegate = self; outline.menu = menu
        scroll.documentView = outline; scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true; scroll.hasHorizontalScroller = false
        scroll.drawsBackground = false; scroll.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll)
        quickAccess.orientation = .vertical; quickAccess.alignment = .leading
        quickAccess.distribution = .fill; quickAccess.spacing = 0
        quickAccess.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(quickAccess)
        foldersHeader.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(foldersHeader)
        let foldersTitle = NSTextField(labelWithString: "Folders")
        foldersTitle.font = .systemFont(ofSize: 17, weight: .bold); foldersTitle.textColor = .black
        foldersTitle.translatesAutoresizingMaskIntoConstraints = false; foldersHeader.addSubview(foldersTitle)
        locations.orientation = .vertical; locations.alignment = .leading
        locations.distribution = .fill; locations.spacing = 0
        locations.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(locations)
        configureLocationScroll()
        NSLayoutConstraint.activate([
            quickAccess.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            quickAccess.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            quickAccess.topAnchor.constraint(equalTo: view.topAnchor, constant: 5),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            foldersHeader.leadingAnchor.constraint(equalTo: quickAccess.leadingAnchor),
            foldersHeader.trailingAnchor.constraint(equalTo: quickAccess.trailingAnchor),
            foldersHeader.topAnchor.constraint(equalTo: quickAccess.bottomAnchor),
            foldersHeader.heightAnchor.constraint(equalToConstant: 47),
            foldersTitle.leadingAnchor.constraint(equalTo: foldersHeader.leadingAnchor, constant: 5),
            foldersTitle.bottomAnchor.constraint(equalTo: foldersHeader.bottomAnchor, constant: -9),
            scroll.topAnchor.constraint(equalTo: foldersHeader.bottomAnchor),
            scroll.bottomAnchor.constraint(equalTo: locations.topAnchor, constant: -9),
            locations.leadingAnchor.constraint(equalTo: quickAccess.leadingAnchor),
            locations.trailingAnchor.constraint(equalTo: quickAccess.trailingAnchor),
            locations.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -20)
        ])
        createRoots()
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification] {
            observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.refreshVolumes(); self?.refresh()
            })
        }
    }
    override func viewDidLayout() {
        super.viewDidLayout()
        guard let column = outline.outlineTableColumn else { return }
        // Outline rows fill the viewport independently of their column. Keep the
        // single cell equally wide, including after a scroller changes its size.
        let width = max(column.minWidth, scroll.contentSize.width)
        if abs(column.width - width) > 0.5 { column.width = width }
    }
    deinit { for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) } }

    func select(url: URL) {
        let next = url.standardizedFileURL
        let changed = selectedURL != next || recentsSelected || thisMacSelected
        selectedURL = next; recentsSelected = false; thisMacSelected = false
        if changed { pendingRevealPath = next.path }
        guard isViewLoaded else { return }
        updateActiveVolume()
        revealSelection()
    }
    func selectRecents() {
        selectedURL = nil; recentsSelected = true; thisMacSelected = false; pendingRevealPath = nil
        guard isViewLoaded, let recent = roots.first?.children?.first(where: \.isRecents) else { return }
        updateActiveVolume()
        selectNode(recent)
    }
    func selectThisMac() {
        selectedURL = nil; recentsSelected = false; thisMacSelected = true; pendingRevealPath = nil
        guard isViewLoaded else { return }
        updateActiveVolume()
        let previous = selectingProgrammatically; selectingProgrammatically = true
        outline.deselectAll(nil); selectingProgrammatically = previous
        updateQuickSelection()
    }
    func refresh() {
        guard isViewLoaded else { return }
        var expanded: [SidebarNode] = []
        func collect(_ node: SidebarNode) {
            guard outline.isItemExpanded(node) else { return }
            expanded.append(node)
            node.children?.forEach(collect)
        }
        treeRoots.forEach(collect)
        for node in expanded { loadChildren(of: node, force: true) }
        revealSelection()
    }

    private func createRoots() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        roots = [
            SidebarNode(title: "Quick access", isGroup: true, children: [
                SidebarNode(title: "Desktop", url: home.appendingPathComponent("Desktop"), symbol: "desktopcomputer", canExpand: false),
                SidebarNode(title: "Downloads", url: home.appendingPathComponent("Downloads"), symbol: "arrow.down.to.line", canExpand: false),
                SidebarNode(title: "Recents", symbol: "clock", isRecents: true, canExpand: false)
            ]),
            SidebarNode(title: "Folders", isGroup: true, children: [SidebarNode(title: home.lastPathComponent, url: home, symbol: "house")]),
            SidebarNode(title: "Locations", isGroup: true, children: [])
        ]
        refreshVolumes()
        buildQuickAccess()
        selectingProgrammatically = true; outline.reloadData()
        selectingProgrammatically = false
        if let homeNode = roots[1].children?.first { expandedPaths.insert(home.path); outline.expandItem(homeNode) }
        revealSelection()
    }

    private func buildQuickAccess() {
        for child in quickAccess.arrangedSubviews { quickAccess.removeArrangedSubview(child); child.removeFromSuperview() }
        quickButtons.removeAll()
        let header = NSView()
        header.heightAnchor.constraint(equalToConstant: 40).isActive = true
        let title = NSTextField(labelWithString: "Quick access")
        title.font = .systemFont(ofSize: 17, weight: .bold); title.textColor = .black
        title.translatesAutoresizingMaskIntoConstraints = false; header.addSubview(title)
        NSLayoutConstraint.activate([title.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 5), title.bottomAnchor.constraint(equalTo: header.bottomAnchor, constant: -9)])
        quickAccess.addArrangedSubview(header); header.widthAnchor.constraint(equalTo: quickAccess.widthAnchor).isActive = true
        for node in roots[0].children ?? [] {
            let button = SidebarShortcutButton(title: node.title, symbol: node.symbol) { [weak self, weak node] in
                guard let self, let node else { return }; self.navigate(node); self.selectNode(node)
            }
            button.setAccessibilityIdentifier("sidebar-" + node.title.lowercased())
            quickButtons.append(button); quickAccess.addArrangedSubview(button)
            button.widthAnchor.constraint(equalTo: quickAccess.widthAnchor).isActive = true
            button.heightAnchor.constraint(equalToConstant: 35).isActive = true
        }
    }

    private func updateQuickSelection() {
        thisMacButton?.chosen = thisMacSelected
        for (index, node) in (roots.first?.children ?? []).enumerated() where index < quickButtons.count {
            quickButtons[index].chosen = node.isRecents ? recentsSelected : (!recentsSelected && node.url?.standardizedFileURL == selectedURL)
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let selectedVolume = selectedURL.flatMap { target -> SidebarNode? in
            guard !recentsSelected, !Self.contains(home, target), roots.count > 2 else { return nil }
            return roots[2].children?.filter { $0.url.map { Self.contains($0, target) } ?? false }
                .max(by: { ($0.url?.path.count ?? 0) < ($1.url?.path.count ?? 0) })
        }
        for (index, node) in (roots.count > 2 ? roots[2].children ?? [] : []).enumerated() where index < locationButtons.count {
            locationButtons[index].chosen = node === selectedVolume
        }
    }

    private func configureLocationScroll() {
        let header = NSView(); header.heightAnchor.constraint(equalToConstant: 40).isActive = true
        let title = NSTextField(labelWithString: "Locations")
        title.font = .systemFont(ofSize: 17, weight: .bold); title.textColor = .black
        title.translatesAutoresizingMaskIntoConstraints = false; header.addSubview(title)
        NSLayoutConstraint.activate([title.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 5), title.bottomAnchor.constraint(equalTo: header.bottomAnchor, constant: -9)])
        locations.addArrangedSubview(header); header.widthAnchor.constraint(equalTo: locations.widthAnchor).isActive = true
        let overview = SidebarShortcutButton(title: "This Mac", symbol: "desktopcomputer") { [weak self] in
            self?.selectThisMac(); self?.onThisMac?()
        }
        overview.setAccessibilityIdentifier("sidebar-this-mac")
        overview.toolTip = "View mounted drives and available storage"
        locations.addArrangedSubview(overview)
        overview.widthAnchor.constraint(equalTo: locations.widthAnchor).isActive = true
        overview.heightAnchor.constraint(equalToConstant: 35).isActive = true
        thisMacButton = overview
        let document = SidebarFlippedView(); document.translatesAutoresizingMaskIntoConstraints = false
        locationRows.orientation = .vertical; locationRows.alignment = .leading
        locationRows.distribution = .fill; locationRows.spacing = 0
        locationRows.translatesAutoresizingMaskIntoConstraints = false; document.addSubview(locationRows)
        locationScroll.documentView = document; locationScroll.hasVerticalScroller = true
        locationScroll.autohidesScrollers = true; locationScroll.drawsBackground = false
        locationScroll.translatesAutoresizingMaskIntoConstraints = false
        locations.addArrangedSubview(locationScroll)
        locationHeight = locationScroll.heightAnchor.constraint(equalToConstant: 35)
        locationHeight?.priority = .defaultHigh; locationHeight?.isActive = true
        NSLayoutConstraint.activate([
            locationScroll.widthAnchor.constraint(equalTo: locations.widthAnchor),
            locationScroll.heightAnchor.constraint(lessThanOrEqualTo: view.heightAnchor, multiplier: 0.22),
            document.topAnchor.constraint(equalTo: locationScroll.contentView.topAnchor),
            document.leadingAnchor.constraint(equalTo: locationScroll.contentView.leadingAnchor),
            document.widthAnchor.constraint(equalTo: locationScroll.contentView.widthAnchor),
            locationRows.topAnchor.constraint(equalTo: document.topAnchor),
            locationRows.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            locationRows.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            locationRows.trailingAnchor.constraint(equalTo: document.trailingAnchor)
        ])
    }

    private func buildLocations() {
        for child in locationRows.arrangedSubviews { locationRows.removeArrangedSubview(child); child.removeFromSuperview() }
        locationButtons.removeAll()
        for node in roots[2].children ?? [] {
            let row = NSView(); row.heightAnchor.constraint(equalToConstant: 35).isActive = true
            let button = SidebarShortcutButton(title: node.title, symbol: node.symbol) { [weak self, weak node] in
                guard let self, let node else { return }; self.navigate(node); self.revealSelection()
            }
            button.toolTip = node.url?.path; button.translatesAutoresizingMaskIntoConstraints = false
            button.setAccessibilityIdentifier("sidebar-location-" + (node.url?.path ?? node.title))
            locationButtons.append(button); row.addSubview(button)
            NSLayoutConstraint.activate([
                button.leadingAnchor.constraint(equalTo: row.leadingAnchor),
                button.topAnchor.constraint(equalTo: row.topAnchor), button.bottomAnchor.constraint(equalTo: row.bottomAnchor),
                button.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: node.canEject ? -32 : 0)
            ])
            if node.canEject {
                let eject = SidebarIconButton(symbol: "eject", label: "Eject \(node.title)") { [weak self, weak node] in
                    guard let url = node?.url else { return }; self?.eject(url)
                }
                eject.translatesAutoresizingMaskIntoConstraints = false; row.addSubview(eject)
                NSLayoutConstraint.activate([
                    eject.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -5),
                    eject.centerYAnchor.constraint(equalTo: row.centerYAnchor),
                    eject.widthAnchor.constraint(equalToConstant: 23), eject.heightAnchor.constraint(equalToConstant: 26)
                ])
            }
            locationRows.addArrangedSubview(row); row.widthAnchor.constraint(equalTo: locationRows.widthAnchor).isActive = true
        }
        locationHeight?.constant = min(CGFloat(locationButtons.count) * 35, 140)
        updateQuickSelection()
    }
    private func refreshVolumes() {
        guard roots.count == 3 else { return }
        volumeGeneration += 1
        let generation = volumeGeneration
        let keys: Set<URLResourceKey> = [.volumeNameKey, .volumeIsEjectableKey, .volumeIsRemovableKey, .volumeIsBrowsableKey]
        loadingQueue.async { [weak self] in
            let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: Array(keys), options: [.skipHiddenVolumes]) ?? [URL(fileURLWithPath: "/")]
            let incoming = urls.compactMap { url -> SidebarNode? in
                let values = try? url.resourceValues(forKeys: keys)
                guard values?.volumeIsBrowsable != false else { return nil }
                let title = values?.volumeName ?? (url.path == "/" ? "Macintosh HD" : url.lastPathComponent)
                return SidebarNode(title: title, url: url.standardizedFileURL, symbol: "externaldrive", canExpand: true,
                                   canEject: values?.volumeIsEjectable == true || values?.volumeIsRemovable == true)
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, generation == self.volumeGeneration else { return }
                let old = Dictionary(uniqueKeysWithValues: (self.roots[2].children ?? []).compactMap { node in node.url.map { ($0.path, node) } })
                self.roots[2].children = incoming.map { fresh in
                    guard let path = fresh.url?.path, let retained = old[path] else { return fresh }
                    retained.title = fresh.title; retained.canEject = fresh.canEject; return retained
                }
                self.buildLocations()
                self.updateActiveVolume()
                self.revealSelection()
            }
        }
    }

    private func updateActiveVolume() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let next = selectedURL.flatMap { target -> SidebarNode? in
            guard !recentsSelected, !Self.contains(home, target), roots.count > 2 else { return nil }
            return roots[2].children?.filter { $0.url.map { Self.contains($0, target) } ?? false }
                .max(by: { ($0.url?.path.count ?? 0) < ($1.url?.path.count ?? 0) })
        }
        guard next !== activeVolume else { return }
        withStableTreeUpdate {
            activeVolume = next
            outline.reloadData()
            for root in treeRoots {
                if let path = root.url?.path, expandedPaths.contains(path) { outline.expandItem(root); restoreExpansions(in: root) }
            }
        }
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let node = item as? SidebarNode else { return treeRoots.count }
        return node.children?.count ?? (node.canExpand ? 1 : 0)
    }
    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let node = item as? SidebarNode else { return treeRoots[index] }
        return node.children?[index] ?? node.placeholder
    }
    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let node = item as? SidebarNode else { return false }
        return node.canExpand && (node.children == nil || node.children?.isEmpty == false)
    }
    func outlineView(_ outlineView: NSOutlineView, shouldShowOutlineCellForItem item: Any) -> Bool { true }
    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool { false }
    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        guard let node = item as? SidebarNode else { return false }
        return node.url != nil || node.isRecents
    }
    func outlineView(_ outlineView: NSOutlineView, shouldExpandItem item: Any) -> Bool {
        if let node = item as? SidebarNode {
            if let url = node.url { expandedPaths.insert(url.path) }
            loadChildren(of: node, force: node.loadFailed)
        }
        return true
    }
    func outlineView(_ outlineView: NSOutlineView, shouldCollapseItem item: Any) -> Bool {
        guard let node = item as? SidebarNode, !node.isGroup else { return false }
        guard !selectingProgrammatically else { return true }
        if let url = node.url {
            expandedPaths.remove(url.path)
            if let pendingRevealPath, Self.contains(url, URL(fileURLWithPath: pendingRevealPath)) { self.pendingRevealPath = nil }
        }
        return true
    }
    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        guard let node = item as? SidebarNode else { return 35 }
        return node.isGroup ? (node === roots.first ? 40 : 47) : 35
    }
    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        let row = SidebarSelectionRow(); row.clipsToBounds = true
        row.indent = CGFloat(min((item as? SidebarNode)?.depth ?? 0, 4)) * 16
        return row
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? SidebarNode else { return nil }
        let cell = NSTableCellView(); cell.clipsToBounds = true
        let label = NSTextField(labelWithString: node.title)
        label.font = .systemFont(ofSize: node.isGroup ? 17 : 18, weight: node.isGroup ? .bold : .regular)
        label.textColor = node.url != nil || node.isGroup || node.isRecents ? .black : .secondaryLabelColor
        label.lineBreakMode = .byTruncatingMiddle; label.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(label); cell.textField = label
        if node.isGroup {
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 5),
                label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                label.bottomAnchor.constraint(equalTo: cell.bottomAnchor, constant: -9)
            ])
        } else {
            let base = CGFloat(min(node.depth, 4)) * 16
            let treeItem = node.url != nil
            if treeItem && node.canExpand && (node.children == nil || node.children?.isEmpty == false) {
                let disclosure = SidebarIconButton(symbol: outline.isItemExpanded(node) ? "chevron.down" : "chevron.right",
                    label: outline.isItemExpanded(node) ? "Collapse \(node.title)" : "Expand \(node.title)") { [weak self, weak node] in
                        guard let self, let node else { return }; self.toggle(node)
                    }
                disclosure.translatesAutoresizingMaskIntoConstraints = false; cell.addSubview(disclosure)
                NSLayoutConstraint.activate([
                    disclosure.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: base + 6),
                    disclosure.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                    disclosure.widthAnchor.constraint(equalToConstant: 17), disclosure.heightAnchor.constraint(equalToConstant: 26)
                ])
            }
            let icon = NSImageView(); icon.imageScaling = .scaleProportionallyDown
            if node.symbol == "folder" { icon.image = NSImage(named: NSImage.folderName) }
            else {
                icon.image = NSImage(systemSymbolName: node.symbol.isEmpty ? "ellipsis" : node.symbol, accessibilityDescription: nil)?
                    .withSymbolConfiguration(.init(pointSize: 21, weight: .regular))
                icon.contentTintColor = .black
            }
            icon.translatesAutoresizingMaskIntoConstraints = false; cell.addSubview(icon); cell.imageView = icon
            let leading = base + (treeItem ? 29 : 16)
            var constraints = [
                icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: leading),
                icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                icon.widthAnchor.constraint(equalToConstant: 23), icon.heightAnchor.constraint(equalToConstant: 23),
                label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ]
            if node.canEject {
                let eject = SidebarIconButton(symbol: "eject", label: "Eject \(node.title)") { [weak self, weak node] in
                    guard let url = node?.url else { return }; self?.eject(url)
                }
                eject.translatesAutoresizingMaskIntoConstraints = false; cell.addSubview(eject)
                constraints += [
                    eject.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
                    eject.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                    eject.widthAnchor.constraint(equalToConstant: 23), eject.heightAnchor.constraint(equalToConstant: 26),
                    label.trailingAnchor.constraint(equalTo: eject.leadingAnchor, constant: -5)
                ]
            } else { constraints.append(label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -7)) }
            NSLayoutConstraint.activate(constraints)
        }
        cell.toolTip = node.detail ?? node.url?.path ?? (node.isRecents ? "Recently used files" : nil)
        cell.setAccessibilityLabel(node.url.map { "\(node.title), \($0.path), level \(node.depth + 1)" } ?? node.title)
        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !selectingProgrammatically, outline.selectedRow >= 0,
              let node = outline.item(atRow: outline.selectedRow) as? SidebarNode else { return }
        navigate(node)
    }
    @objc private func rowClicked() {
        guard outline.clickedRow >= 0, let node = outline.item(atRow: outline.clickedRow) as? SidebarNode else { return }
        if node.isRecents && !recentsSelected { navigate(node) }
        else if let url = node.url, url.standardizedFileURL != selectedURL { navigate(node) }
    }
    private func navigate(_ node: SidebarNode) {
        pendingRevealPath = nil; thisMacSelected = false
        if node.isRecents { selectedURL = nil; recentsSelected = true; updateActiveVolume(); onRecents?() }
        else if let url = node.url {
            selectedURL = url.standardizedFileURL; recentsSelected = false
            if roots.count > 2, roots[2].children?.contains(where: { $0 === node }) == true { pendingRevealPath = url.path }
            updateActiveVolume()
            onNavigate?(url)
        }
        updateQuickSelection()
    }
    private func toggle(_ node: SidebarNode) {
        if outline.isItemExpanded(node) { outline.collapseItem(node) } else { outline.expandItem(node) }
        reloadNode(node, children: false)
    }
    private func handleArrow(expanding: Bool) -> Bool {
        guard outline.selectedRow >= 0, let node = outline.item(atRow: outline.selectedRow) as? SidebarNode else { return false }
        if expanding, node.canExpand { if !outline.isItemExpanded(node) { toggle(node) }; return true }
        if !expanding, outline.isItemExpanded(node), !node.isGroup { toggle(node); return true }
        if !expanding, let parent = outline.parent(forItem: node) as? SidebarNode, !parent.isGroup { selectNode(parent); navigate(parent); return true }
        return false
    }

    private func loadChildren(of node: SidebarNode, force: Bool = false) {
        guard node.canExpand, let url = node.url else { return }
        if node.loading { if force { node.reloadRequested = true }; return }
        guard force || node.children == nil else { return }
        node.loading = true
        let selected = selectedURL
        let childDepth = node.depth + 1
        loadingQueue.async { [weak self, weak node] in
            let keys: Set<URLResourceKey> = [.isDirectoryKey, .isPackageKey, .isSymbolicLinkKey, .localizedNameKey]
            let result: Result<[SidebarNode], Error> = Result {
                var urls = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles])
                if let selected, Self.contains(url, selected), url != selected {
                    let parentParts = url.standardizedFileURL.pathComponents
                    let parts = selected.standardizedFileURL.pathComponents
                    if parts.count > parentParts.count {
                        let branch = url.appendingPathComponent(parts[parentParts.count])
                        if !urls.contains(where: { $0.standardizedFileURL == branch.standardizedFileURL }) { urls.append(branch) }
                    }
                }
                return urls.compactMap { child -> SidebarNode? in
                    guard let values = try? child.resourceValues(forKeys: keys), values.isDirectory == true, values.isPackage != true else { return nil }
                    return SidebarNode(title: values.localizedName ?? child.lastPathComponent, url: child.standardizedFileURL,
                                       symbol: "folder", canExpand: values.isSymbolicLink != true, depth: childDepth)
                }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            }
            DispatchQueue.main.async { [weak self, weak node] in
                guard let self, let node else { return }; node.loading = false; node.loadedSelection = selected?.path
                guard self.isAttached(node) else { return }
                switch result {
                case .success(let incoming):
                    node.loadFailed = false
                    let existing = Dictionary(uniqueKeysWithValues: (node.children ?? []).compactMap { old in old.url.map { ($0.path, old) } })
                    node.children = incoming.map { fresh in
                        guard let path = fresh.url?.path, let retained = existing[path] else { return fresh }
                        retained.title = fresh.title; retained.depth = fresh.depth; retained.canExpand = fresh.canExpand
                        if !fresh.canExpand { retained.children = nil; self.expandedPaths.remove(path) }
                        return retained
                    }
                case .failure(let error):
                    node.loadFailed = true
                    let unavailable = SidebarNode(title: "Unable to read folder", symbol: "exclamationmark.circle", canExpand: false, depth: node.depth + 1)
                    unavailable.detail = error.localizedDescription; node.children = [unavailable]
                }
                self.withStableTreeUpdate {
                    self.outline.reloadItem(node, reloadChildren: true)
                    self.restoreExpansions(in: node)
                    self.revealSelection()
                }
                if node.reloadRequested { node.reloadRequested = false; self.loadChildren(of: node, force: true) }
                self.revealSelection()
            }
        }
    }
    private func restoreExpansions(in node: SidebarNode) {
        guard node.isGroup || outline.isItemExpanded(node) else { return }
        for child in node.children ?? [] {
            if let url = child.url, expandedPaths.contains(url.path), child.canExpand {
                outline.expandItem(child); loadChildren(of: child); restoreExpansions(in: child)
            }
        }
    }
    private func reloadNode(_ node: SidebarNode, children: Bool) {
        let previous = selectingProgrammatically; selectingProgrammatically = true
        outline.reloadItem(node, reloadChildren: children)
        selectingProgrammatically = previous
    }
    private func isAttached(_ candidate: SidebarNode) -> Bool {
        func contains(_ node: SidebarNode) -> Bool { node === candidate || node.children?.contains(where: contains) == true }
        return treeRoots.contains(where: contains)
    }
    private func withStableTreeUpdate(_ update: () -> Void) {
        let previous = selectingProgrammatically
        let preserveViewport = pendingRevealPath == nil
        let origin = scroll.contentView.bounds.origin
        let row = outline.row(at: NSPoint(x: 1, y: origin.y))
        let anchor = row >= 0 ? outline.item(atRow: row) as? SidebarNode : nil
        let offset = row >= 0 ? origin.y - outline.rect(ofRow: row).minY : 0
        selectingProgrammatically = true
        update()
        if !previous, preserveViewport, pendingRevealPath == nil {
            outline.layoutSubtreeIfNeeded()
            let newRow = anchor.map { outline.row(forItem: $0) } ?? -1
            let y = newRow >= 0 ? outline.rect(ofRow: newRow).minY + offset : origin.y
            let limit = max(0, outline.bounds.height - scroll.contentSize.height)
            scroll.contentView.scroll(to: NSPoint(x: origin.x, y: min(max(0, y), limit)))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        selectingProgrammatically = previous
    }
    private func revealSelection() {
        updateQuickSelection()
        if thisMacSelected {
            let previous = selectingProgrammatically; selectingProgrammatically = true
            outline.deselectAll(nil); selectingProgrammatically = previous
            return
        }
        if recentsSelected { if let recent = roots.first?.children?.first(where: \.isRecents) { selectNode(recent) }; return }
        guard let target = selectedURL else { return }
        if let quick = roots.first?.children?.first(where: { $0.url?.standardizedFileURL == target }) { selectNode(quick); return }
        if pendingRevealPath == nil {
            for row in 0..<outline.numberOfRows {
                if let node = outline.item(atRow: row) as? SidebarNode, node.url?.standardizedFileURL == target { selectNode(node, scroll: false); return }
            }
            return
        }
        if outline.selectedRow >= 0, let current = outline.item(atRow: outline.selectedRow) as? SidebarNode, current.url?.standardizedFileURL != target {
            let previous = selectingProgrammatically
            selectingProgrammatically = true; outline.deselectAll(nil); selectingProgrammatically = previous
        }
        let home = roots.count > 1 ? roots[1].children?.first : nil
        if let home, let url = home.url, Self.contains(url, target) { reveal(target, inside: home); return }
        if let shortcut = roots.first?.children?.first(where: { $0.url?.standardizedFileURL == target }) { selectNode(shortcut); return }
        if let activeVolume { reveal(target, inside: activeVolume) }
    }
    private func reveal(_ target: URL, inside node: SidebarNode) {
        guard let url = node.url else { return }
        if url.standardizedFileURL == target {
            if node === activeVolume, pendingRevealPath != nil, !outline.isItemExpanded(node) {
                outline.expandItem(node); reloadNode(node, children: false)
            }
            selectNode(node); return
        }
        guard node.canExpand else { return }
        if !outline.isItemExpanded(node) { outline.expandItem(node); reloadNode(node, children: false) }
        if node.children == nil { loadChildren(of: node); return }
        if let child = node.children?.first(where: { $0.url.map { Self.contains($0, target) } ?? false }) { reveal(target, inside: child) }
        else if !node.loading, node.loadedSelection != target.path { loadChildren(of: node, force: true) }
    }
    private func selectNode(_ node: SidebarNode, scroll shouldScroll: Bool = true) {
        let previous = selectingProgrammatically
        if roots.first?.children?.contains(where: { $0 === node }) == true {
            selectingProgrammatically = true; outline.deselectAll(nil); selectingProgrammatically = previous
            pendingRevealPath = nil; updateQuickSelection(); return
        }
        let row = outline.row(forItem: node); guard row >= 0 else { return }
        selectingProgrammatically = true; outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        if shouldScroll { outline.scrollRowToVisible(row) }
        selectingProgrammatically = previous
        if node.url?.standardizedFileURL == selectedURL || node.isRecents { pendingRevealPath = nil }
    }
    private static func contains(_ parent: URL, _ child: URL) -> Bool {
        let prefix = parent.standardizedFileURL.path; let path = child.standardizedFileURL.path
        return path == prefix || path.hasPrefix(prefix == "/" ? "/" : prefix + "/")
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard outline.clickedRow >= 0, let node = outline.item(atRow: outline.clickedRow) as? SidebarNode, node.url != nil else { return }
        let open = NSMenuItem(title: "Open Folder", action: #selector(openContextFolder(_:)), keyEquivalent: "")
        open.target = self; open.representedObject = node; menu.addItem(open)
        if node.canEject {
            let eject = NSMenuItem(title: "Eject \(node.title)", action: #selector(ejectContextVolume(_:)), keyEquivalent: "")
            eject.target = self; eject.representedObject = node; menu.addItem(eject)
        }
        menu.addItem(.separator())
        let properties = NSMenuItem(title: "Properties…", action: #selector(propertiesContextFolder(_:)), keyEquivalent: "")
        properties.target = self; properties.representedObject = node; menu.addItem(properties)
    }
    @objc private func propertiesContextFolder(_ sender: NSMenuItem) { if let url = (sender.representedObject as? SidebarNode)?.url { onProperties?(url) } }
    @objc private func openContextFolder(_ sender: NSMenuItem) { if let url = (sender.representedObject as? SidebarNode)?.url { onNavigate?(url) } }
    @objc private func ejectContextVolume(_ sender: NSMenuItem) { if let url = (sender.representedObject as? SidebarNode)?.url { eject(url) } }
    private func eject(_ url: URL) {
        do { try NSWorkspace.shared.unmountAndEjectDevice(at: url) }
        catch { let alert = NSAlert(error: error); if let window = view.window { alert.beginSheetModal(for: window) } else { alert.runModal() } }
    }
}
