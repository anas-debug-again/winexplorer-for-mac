import AppKit
import Darwin
import UniformTypeIdentifiers
import ImageIO
import AVFoundation
import FileManagerCore

enum BrowserAction {
    case cut, copy, paste, pasteShortcut, rename, trash, newFolder, newFile, preview, copyPath, openWith, properties, sendToDesktopAlias, sendToChooseFolder
}

/// An independently navigable browser. File mutations are delegated to the window controller.
final class BrowserPaneViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate,
    NSTextFieldDelegate, NSSearchFieldDelegate, NSMenuDelegate, NSCollectionViewDataSource, NSCollectionViewDelegate {
    var onActivate: (() -> Void)?
    var onSelectionChange: (([URL]) -> Void)?
    var onDirectoryChange: ((URL) -> Void)?
    var onRequestAction: ((BrowserAction) -> Void)?
    var onOpenFolderWindow: ((URL) -> Void)?
    var onOpenError: ((String) -> Void)?
    var openFile: (URL) -> Bool = { url in
        guard NSWorkspace.shared.open(url) else { return false }
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
        return true
    }
    var canPasteShortcut: (() -> Bool)?
    var onDrop: (([URL], URL, Bool) -> Void)?
    var onStatusChange: ((String) -> Void)?
    var onPresentationChange: (() -> Void)?
    var onSendToFolder: (([URL], URL) -> Void)?
    static let thisMacURL = URL(string: "filemanager://this-mac")!
    static func normalizedLocation(_ url: URL) -> URL { url == thisMacURL ? thisMacURL : url.standardizedFileURL }
    var isShowingThisMac: Bool { !isShowingRecents && currentURL == Self.thisMacURL }
    private var isVirtualLocation: Bool { isShowingRecents || isShowingThisMac }
    var canReceiveFiles: Bool { !isVirtualLocation && loadError == nil }
    var currentGroupBy: String { tabs[selectedTab].groupBy }
    var displaySettings: [BrowserTabDisplaySettings] { tabs.map(\.display) }

    var navigationHeaderView: NSView { _ = view; return header }
    var tabsView: NSView { _ = view; return tabScroll }
    var navigationView: NSView { _ = view; return navigationRow }
    var isShowingRecents: Bool { tabs[selectedTab].isRecents }
    var selectedTabIndex: Int { selectedTab }
    var isSearching: Bool { !isShowingThisMac && !tabs[selectedTab].query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var effectiveSortKey: String { isSearching ? tabs[selectedTab].searchSortKey : tabs[selectedTab].sortKey }
    var currentSortKey: String { ["modified": "date", "kind": "type"][effectiveSortKey] ?? effectiveSortKey }
    var currentSortAscending: Bool { isSearching ? tabs[selectedTab].searchAscending : tabs[selectedTab].ascending }
    var excludesGeneratedSearchResults: Bool { tabs[selectedTab].excludeGenerated }
    private var showsSearchLocations: Bool { isSearching && (tabs[selectedTab].recursiveSearch || isShowingRecents) }
    var currentViewMode: String { tabs[selectedTab].viewMode }

    var currentURL: URL { tabs[selectedTab].url }
    var selectedURLs: [URL] {
        guard !isShowingThisMac else { return [] }
        if viewMode != "details" {
            return collection.selectionIndexPaths.sorted { ($0.section, $0.item) < ($1.section, $1.item) }.compactMap { entry(at: $0)?.url }
        }
        return table.selectedRowIndexes.compactMap { entry(atRow: $0)?.url }
    }
    var openDirectories: [URL] { tabs.map(\.url) }

    private struct Location {
        let url: URL
        let isRecents: Bool
    }

    private final class Tab {
        var history: [Location]
        var historyIndex = 0
        var query = ""
        var selection: Set<URL> = []
        var display = BrowserTabDisplaySettings()
        var sortKey: String { get { display.sortKey } set { display.sortKey = newValue } }
        var ascending: Bool { get { display.ascending } set { display.ascending = newValue } }
        var viewMode: String { get { display.viewMode } set { display.viewMode = newValue } }
        var groupBy: String { get { display.groupBy } set { display.groupBy = newValue } }
        var columnsCustomized: Bool { get { display.columnsCustomized } set { display.columnsCustomized = newValue } }
        var recursiveSearch: Bool { get { display.includesSubfolders } set { display.includesSubfolders = newValue } }
        var searchSortKey = "bestMatch"
        var searchAscending = true
        var excludeGenerated = false
        var isRecents: Bool { history[historyIndex].isRecents }
        var url: URL { history[historyIndex].url }
        init(_ url: URL) { history = [Location(url: BrowserPaneViewController.normalizedLocation(url), isRecents: false)] }
    }

    private struct Entry {
        let url: URL
        let name: String
        let isFolder: Bool
        let isPackage: Bool
        let isShortcut: Bool
        let isAppShortcut: Bool
        let size: Int64
        let modified: Date?
        let created: Date?
        let kind: String

        init(url: URL) {
            self.url = url.standardizedFileURL
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey, .isAliasFileKey, .isSymbolicLinkKey, .fileSizeKey,
                                                          .contentModificationDateKey, .creationDateKey, .localizedTypeDescriptionKey])
            name = url.lastPathComponent
            isPackage = values?.isPackage == true
            isAppShortcut = values?.isDirectory != true && values?.isAliasFile != true && values?.isSymbolicLink != true
                && url.pathExtension.caseInsensitiveCompare(AppShortcutDocument.fileExtension) == .orderedSame
            isShortcut = isAppShortcut || (values?.isAliasFile == true && values?.isSymbolicLink != true)
            isFolder = values?.isDirectory == true && !isPackage && !isShortcut
            size = Int64(values?.fileSize ?? 0)
            modified = values?.contentModificationDate
            created = values?.creationDate
            kind = isShortcut ? "Shortcut" : (isFolder ? "Folder" : (values?.localizedTypeDescription ?? "File"))
        }

        /// Sorting by name never needs a stat or an alias-resolution request.
        init(indexed item: FilenameSearchEntry) {
            url = item.url; name = item.name; isPackage = item.isPackage
            isAppShortcut = !item.isDirectory && !item.isAlias && !item.isSymbolicLink
                && item.url.pathExtension.caseInsensitiveCompare(AppShortcutDocument.fileExtension) == .orderedSame
            isShortcut = isAppShortcut || (item.isAlias && !item.isSymbolicLink)
            isFolder = item.isDirectory && !item.isPackage && !item.isSymbolicLink && !isShortcut
            size = 0; modified = nil; created = nil
            kind = isShortcut ? "Shortcut" : (isFolder ? "Folder" : "File")
        }
    }

    private var tabs: [Tab]
    private var selectedTab = 0
    private var entries: [Entry] = []
    private var visibleEntries: [Entry] = []
    private struct EntryGroup { let title: String; var entries: [Entry]; var totalCount: Int? = nil }
    private enum DisplayRow { case header(String), file(Entry) }
    private var groups: [EntryGroup] = []
    private var displayRows: [DisplayRow] = []
    private var showExtensions = true
    private var compactSpacing = false
    private var defaultViewMode = "details"
    private var adjustingColumns = false
    private var updatingSortIndicator = false
    private var searchLocationWidth: CGFloat?
    private var lastCollectionWidth: CGFloat = -1
    private var mediaCache: [String: PaneMediaMetadata] = [:]
    private var pendingMedia = Set<String>()
    private var showHidden = false
    private var viewMode: String { tabs[selectedTab].viewMode }
    private var isActivePane = false
    private var cutURLs = Set<URL>()
    private var loadID = UUID()
    private var loading = false
    private var loadError: String?
    private var searchWarningCount = 0
    private var loadCancellation: PaneSearchCancellation?
    private var searchWork: DispatchWorkItem?
    private let injectedSearchIndex: FilenameSearchIndex?
    private var searchIndex: FilenameSearchIndex { injectedSearchIndex ?? BrowserSearchSupport.index }
    private struct IndexedQuery: Equatable {
        let directory: URL
        let query: String
        let hidden: Bool
        let limit: Int
        let bestMatch: Bool
        let excludeGenerated: Bool
    }
    private struct IndexedPresentation: Equatable {
        let sortKey: String
        let ascending: Bool
        let groupBy: String
        let showExtensions: Bool
        let limit: Int
        var needsAllMetadata: Bool { !["name", "bestMatch"].contains(sortKey) || ["date", "type", "size"].contains(groupBy) }
    }
    private var indexedQuery: IndexedQuery?
    private var indexedSubscription: FilenameSearchSubscription?
    private var indexedSnapshot: FilenameSearchSnapshot?
    private var indexedPreparation: PaneSearchCancellation?
    private var indexedPreparationID = UUID()
    private var indexedPreparedOptions: IndexedPresentation?
    private var indexedRunningOptions: IndexedPresentation?
    private var indexedPreparing = false
    private var indexedNeedsPreparation = false
    private var searchPageLimit = 1000
    private var indexedTotalMatchCount = 0
    private var indexedIsComplete = false
    private var indexedQueryFinished = false
    private var indexedIsIndexing = false
    private var indexedIsUpdating = false
    private var indexedErrorMessage: String?
    private let traceSearchTimings = ProcessInfo.processInfo.environment["FILE_MANAGER_SEARCH_TRACE"] == "1"
    private var searchTraceStart = ProcessInfo.processInfo.systemUptime
    private var searchTraceID = 0
    private let searchIconCache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>(); cache.countLimit = 384; return cache
    }()
    private var pendingSearchIcons = Set<String>()
    private var restoringSelection = false
    private var focusingAddress = false
    private var directoryWatcher: DispatchSourceFileSystemObject?
    private var refreshWork: DispatchWorkItem?
    private let enumerationQueue = DispatchQueue(label: "local.filemanager.browser", qos: .userInitiated, attributes: .concurrent)

    private var splitPresentation = true
    private let column = NSStackView()
    private let header = NSStackView()
    private let navigationRow = NSStackView()
    private let searchRow = NSStackView()
    private let searchBox = PaneBorderedView()
    private let scopeButton = PaneClosureButton()
    private let addressBox = PaneBorderedView()
    private let breadcrumb = PaneBreadcrumbView()
    private let addressIcon = NSImageView(image: paneFolderImage())
    private let statusView = PaneSurfaceView()
    private var headerWidthConstraint: NSLayoutConstraint?
    private var singleSearchWidth: NSLayoutConstraint?
    private var navigationHeightConstraint: NSLayoutConstraint?

    private let accent = NSView()
    private let tabStrip = NSStackView()
    private let tabScroll = NSScrollView()
    private let backButton = PaneClosureButton()
    private let forwardButton = PaneClosureButton()
    private let upButton = PaneClosureButton()
    private let addressField = NSTextField()
    private let searchField = VerticallyCenteredSearchField()
    private let table = PaneFileTableView()
    private let collection = PaneIconCollectionView()
    private let scrollView = PaneFileScrollView()
    private let messageLabel = NSTextField(wrappingLabelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let searchPagingRow = NSStackView()
    private let searchPagingLabel = NSTextField(labelWithString: "")
    private let showMoreButton = PaneClosureButton()
    private let contextMenu = NSMenu()
    private weak var bodyContainer: NSView?
    private lazy var thisMacController: ThisMacViewController = {
        let controller = ThisMacViewController()
        controller.onNavigate = { [weak self] in self?.navigate(to: $0) }
        controller.onActivate = { [weak self] in self?.activate() }
        return controller
    }()
    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM yyyy"
        return formatter
    }()

    init(url: URL, searchIndex: FilenameSearchIndex? = nil) {
        tabs = [Tab(url)]
        injectedSearchIndex = searchIndex
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("Programmatic view controller") }

    deinit {
        refreshWork?.cancel()
        searchWork?.cancel()
        loadCancellation?.cancel()
        indexedSubscription?.cancel()
        indexedPreparation?.cancel()
        directoryWatcher?.cancel()
    }

    override func loadView() {
        let container = PaneSurfaceView()
        container.fillColor = .controlBackgroundColor
        view = container

        column.orientation = .vertical
        column.spacing = 0
        column.alignment = .leading
        column.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(column)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: view.topAnchor),
            column.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            column.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            column.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        header.orientation = .vertical
        header.spacing = 0
        header.alignment = .leading
        header.detachesHiddenViews = true
        column.addArrangedSubview(header)
        headerWidthConstraint = header.widthAnchor.constraint(equalTo: column.widthAnchor)
        headerWidthConstraint?.isActive = true
        accent.wantsLayer = true
        accent.heightAnchor.constraint(equalToConstant: 2).isActive = true
        header.addArrangedSubview(accent)

        tabStrip.orientation = .horizontal
        tabStrip.alignment = .centerY
        tabStrip.spacing = 3
        tabStrip.edgeInsets = NSEdgeInsets(top: 2, left: 5, bottom: 0, right: 8)
        tabScroll.drawsBackground = false
        tabScroll.hasHorizontalScroller = true
        tabScroll.horizontalScroller?.controlSize = .mini
        tabScroll.autohidesScrollers = true
        tabScroll.documentView = tabStrip
        tabStrip.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            tabStrip.leadingAnchor.constraint(equalTo: tabScroll.contentView.leadingAnchor),
            tabStrip.topAnchor.constraint(equalTo: tabScroll.contentView.topAnchor),
            tabStrip.heightAnchor.constraint(equalTo: tabScroll.heightAnchor)
        ])
        tabScroll.heightAnchor.constraint(equalToConstant: 44).isActive = true
        header.addArrangedSubview(tabScroll)

        let navigation = navigationRow
        navigation.orientation = .horizontal
        navigation.spacing = 8
        navigation.edgeInsets = NSEdgeInsets(top: 7, left: 11, bottom: 7, right: 11)
        configureNavigationButton(backButton, symbol: "arrow.left", label: "Back", action: #selector(back))
        configureNavigationButton(forwardButton, symbol: "arrow.right", label: "Forward", action: #selector(forward))
        configureNavigationButton(upButton, symbol: "arrow.up", label: "Up one folder", action: #selector(up))
        navigation.addArrangedSubview(backButton)
        navigation.addArrangedSubview(forwardButton)
        navigation.addArrangedSubview(upButton)
        addressField.font = .systemFont(ofSize: 17)
        addressField.isEditable = true
        addressField.isSelectable = true
        addressField.isBezeled = false
        addressField.isBordered = false
        addressField.drawsBackground = false
        addressField.focusRingType = .none
        addressField.usesSingleLineMode = true
        addressField.cell?.isScrollable = true
        addressField.cell?.wraps = false
        addressField.lineBreakMode = .byClipping
        addressField.target = self
        addressField.action = #selector(addressSubmitted)
        addressField.delegate = self
        addressField.identifier = NSUserInterfaceItemIdentifier("browser.address")
        addressField.setAccessibilityIdentifier("browser.address")
        addressField.setAccessibilityLabel("Folder address")
        addressField.setAccessibilityHelp("Type or paste a folder path, then press Return. Command-L or Control-L.")
        addressField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addressField.isHidden = true
        addressIcon.isHidden = true
        addressBox.clipsToBounds = true
        addressBox.onPress = { [weak self] in
            guard let self, self.addressField.isHidden else { return }
            self.focusAddress()
        }
        addressBox.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for child in [breadcrumb, addressIcon, addressField] {
            child.translatesAutoresizingMaskIntoConstraints = false
            addressBox.addSubview(child)
        }
        NSLayoutConstraint.activate([
            breadcrumb.leadingAnchor.constraint(equalTo: addressBox.leadingAnchor),
            breadcrumb.trailingAnchor.constraint(equalTo: addressBox.trailingAnchor),
            breadcrumb.topAnchor.constraint(equalTo: addressBox.topAnchor),
            breadcrumb.bottomAnchor.constraint(equalTo: addressBox.bottomAnchor),
            addressIcon.leadingAnchor.constraint(equalTo: addressBox.leadingAnchor, constant: 12),
            addressIcon.centerYAnchor.constraint(equalTo: addressBox.centerYAnchor),
            addressIcon.widthAnchor.constraint(equalToConstant: 23),
            addressIcon.heightAnchor.constraint(equalToConstant: 23),
            addressField.leadingAnchor.constraint(equalTo: addressIcon.trailingAnchor, constant: 8),
            addressField.trailingAnchor.constraint(equalTo: addressBox.trailingAnchor, constant: -10),
            addressField.centerYAnchor.constraint(equalTo: addressBox.centerYAnchor),
            addressField.heightAnchor.constraint(equalToConstant: 22)
        ])
        breadcrumb.onEdit = { [weak self] in self?.focusAddress() }
        breadcrumb.onNavigate = { [weak self] url in self?.navigate(to: url) }
        addressBox.heightAnchor.constraint(equalToConstant: 36).isActive = true
        addressBox.widthAnchor.constraint(greaterThanOrEqualToConstant: 110).isActive = true
        navigation.addArrangedSubview(addressBox)
        navigationHeightConstraint = navigation.heightAnchor.constraint(equalToConstant: 50)
        navigationHeightConstraint?.isActive = true
        header.addArrangedSubview(navigation)

        searchRow.orientation = .horizontal
        searchRow.edgeInsets = NSEdgeInsets(top: 3, left: 11, bottom: 8, right: 11)
        searchField.font = .systemFont(ofSize: 17)
        searchField.isBezeled = false
        searchField.drawsBackground = false
        searchField.focusRingType = .none
        (searchField.cell as? NSSearchFieldCell)?.searchButtonCell = nil
        searchField.delegate = self
        searchField.sendsSearchStringImmediately = true
        searchField.sendsWholeSearchString = false
        searchField.target = self
        searchField.action = #selector(searchChanged)
        searchField.identifier = NSUserInterfaceItemIdentifier("browser.search")
        searchField.setAccessibilityIdentifier("browser.search")
        searchField.setAccessibilityLabel("Search filenames")
        searchField.heightAnchor.constraint(equalToConstant: 27).isActive = true
        let searchContents = NSStackView()
        searchContents.orientation = .horizontal
        searchContents.spacing = 9
        searchContents.edgeInsets = NSEdgeInsets(top: 3, left: 10, bottom: 3, right: 6)
        let magnifier = NSImageView(image: NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)!)
        magnifier.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 18, weight: .regular)
        magnifier.contentTintColor = .black
        magnifier.widthAnchor.constraint(equalToConstant: 22).isActive = true
        searchContents.addArrangedSubview(magnifier)
        searchField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        searchContents.addArrangedSubview(searchField)
        scopeButton.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: "Search scope")
        scopeButton.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        scopeButton.isBordered = false
        scopeButton.contentTintColor = .black
        scopeButton.target = self
        scopeButton.action = #selector(searchScopePressed)
        scopeButton.toolTip = "Choose where to search"
        scopeButton.widthAnchor.constraint(equalToConstant: 26).isActive = true
        searchContents.addArrangedSubview(scopeButton)
        searchContents.translatesAutoresizingMaskIntoConstraints = false
        searchBox.addSubview(searchContents)
        NSLayoutConstraint.activate([
            searchContents.leadingAnchor.constraint(equalTo: searchBox.leadingAnchor),
            searchContents.trailingAnchor.constraint(equalTo: searchBox.trailingAnchor),
            searchContents.topAnchor.constraint(equalTo: searchBox.topAnchor),
            searchContents.bottomAnchor.constraint(equalTo: searchBox.bottomAnchor),
            searchBox.heightAnchor.constraint(equalToConstant: 36)
        ])
        searchRow.addArrangedSubview(searchBox)
        searchRow.heightAnchor.constraint(equalToConstant: 47).isActive = true
        header.addArrangedSubview(searchRow)
        for child in header.arrangedSubviews { child.widthAnchor.constraint(equalTo: header.widthAnchor).isActive = true }

        configureTable()
        configureCollection()
        scrollView.contentView = PaneFileClipView()
        scrollView.documentView = table
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor
        scrollView.onViewportWidthChange = { [weak self] in
            self?.applyColumnConfiguration()
            self?.fitTableColumns()
            self?.configureCollectionLayout()
        }

        let tableContainer = NSView()
        bodyContainer = tableContainer
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        tableContainer.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: tableContainer.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: tableContainer.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: tableContainer.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: tableContainer.bottomAnchor)
        ])
        messageLabel.font = .systemFont(ofSize: 17)
        messageLabel.textColor = .secondaryLabelColor
        messageLabel.alignment = .center
        messageLabel.isSelectable = true
        messageLabel.translatesAutoresizingMaskIntoConstraints = false
        tableContainer.addSubview(messageLabel)
        NSLayoutConstraint.activate([
            messageLabel.centerYAnchor.constraint(equalTo: tableContainer.centerYAnchor),
            messageLabel.leadingAnchor.constraint(equalTo: tableContainer.leadingAnchor, constant: 24),
            messageLabel.trailingAnchor.constraint(equalTo: tableContainer.trailingAnchor, constant: -24)
        ])
        tableContainer.heightAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true
        column.addArrangedSubview(tableContainer)

        searchPagingRow.orientation = .horizontal
        searchPagingRow.alignment = .centerY
        searchPagingRow.spacing = 12
        searchPagingRow.edgeInsets = NSEdgeInsets(top: 4, left: 12, bottom: 4, right: 12)
        searchPagingLabel.font = .systemFont(ofSize: 14)
        searchPagingLabel.textColor = .secondaryLabelColor
        searchPagingLabel.lineBreakMode = .byTruncatingTail
        searchPagingLabel.identifier = NSUserInterfaceItemIdentifier("browser.search.scope")
        searchPagingLabel.setAccessibilityIdentifier("browser.search.scope")
        searchPagingLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        searchPagingRow.addArrangedSubview(searchPagingLabel)
        let pagingSpacer = NSView()
        pagingSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        searchPagingRow.addArrangedSubview(pagingSpacer)
        showMoreButton.title = "Show More"
        showMoreButton.target = self
        showMoreButton.action = #selector(showMoreSearchResults)
        showMoreButton.identifier = NSUserInterfaceItemIdentifier("browser.search.showMore")
        showMoreButton.setAccessibilityIdentifier("browser.search.showMore")
        showMoreButton.toolTip = "Show the next 1,000 matching files"
        searchPagingRow.addArrangedSubview(showMoreButton)
        searchPagingRow.heightAnchor.constraint(equalToConstant: 36).isActive = true
        searchPagingRow.isHidden = true
        column.addArrangedSubview(searchPagingRow)

        let status = statusView
        status.fillColor = .windowBackgroundColor
        status.heightAnchor.constraint(equalToConstant: 36).isActive = true
        statusLabel.font = .systemFont(ofSize: 17)
        statusLabel.textColor = .labelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        status.addSubview(statusLabel)
        NSLayoutConstraint.activate([
            statusLabel.leadingAnchor.constraint(equalTo: status.leadingAnchor, constant: 11),
            statusLabel.trailingAnchor.constraint(equalTo: status.trailingAnchor, constant: -8),
            statusLabel.centerYAnchor.constraint(equalTo: status.centerYAnchor)
        ])
        column.addArrangedSubview(status)
        for child in column.arrangedSubviews {
            if child !== header { child.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true }
        }
        refreshChrome()
        updateDocumentView()
        reload()
    }

    /// In single-pane mode the window controller places this same header above its toolbar.
    /// Call this first, then reparent navigationHeaderView when split is false.
    func setPresentationMode(split: Bool) {
        _ = view
        splitPresentation = split
        navigationHeightConstraint?.constant = split ? 50 : 56
        singleSearchWidth?.isActive = false
        if let stack = searchBox.superview as? NSStackView { stack.removeArrangedSubview(searchBox) }
        searchBox.removeFromSuperview()
        if split {
            searchRow.addArrangedSubview(searchBox)
            searchRow.isHidden = false
            if header.superview !== column {
                header.removeFromSuperview()
                column.insertArrangedSubview(header, at: 0)
            }
            headerWidthConstraint?.isActive = true
        } else {
            navigationRow.addArrangedSubview(searchBox)
            singleSearchWidth = searchBox.widthAnchor.constraint(equalTo: header.widthAnchor, multiplier: 0.245)
            singleSearchWidth?.isActive = true
            searchRow.isHidden = true
            headerWidthConstraint?.isActive = false
            if column.arrangedSubviews.contains(where: { $0 === header }) { column.removeArrangedSubview(header) }
            header.removeFromSuperview()
        }
        statusView.isHidden = !split
        accent.isHidden = !split
        breadcrumb.abbreviatesPath = split
        refreshChrome()
        applyColumnConfiguration()
        view.needsLayout = true
    }

    func selectFiles(_ urls: [URL]) {
        _ = view
        tabs[selectedTab].selection = Set(urls.map(\.standardizedFileURL))
        reloadPresentations(retaining: tabs[selectedTab].selection)
        updateStatus()
        onSelectionChange?(selectedURLs)
    }

    func showThisMac() { navigate(to: Self.thisMacURL) }

    func showRecents() {
        _ = view
        activate()
        let tab = tabs[selectedTab]
        if !tab.isRecents {
            tab.history = Array(tab.history.prefix(tab.historyIndex + 1))
            tab.history.append(Location(url: currentURL, isRecents: true))
            tab.historyIndex = tab.history.count - 1
        }
        tabs[selectedTab].selection = []
        tabs[selectedTab].query = ""
        directoryChanged()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        applyColumnConfiguration()
        fitTableColumns()
        configureCollectionLayout()
    }

    private var fileViewportWidth: CGFloat {
        // The pane can shrink before NSScrollView has tiled its clip view. Never
        // choose columns using a stale viewport wider than the actual pane.
        [view.bounds.width, scrollView.bounds.width, scrollView.contentView.bounds.width].filter { $0 > 0 }.min() ?? 0
    }

    private func fitTableColumns() {
        guard let nameColumn = table.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier("name")) else { return }
        guard !adjustingColumns else { return }
        adjustingColumns = true
        defer { adjustingColumns = false }
        // The clip-view bounds are authoritative after a preview/split resize; contentSize
        // can still reflect an earlier tile while the enclosing stack is laying out.
        let viewportWidth = fileViewportWidth
        guard viewportWidth > 0 else { return }
        // Column widths omit intercell spacing. These main-mode content widths render
        // as 180 / 190 / 110 point columns including the 12 point column gutters.
        var fixedWidths: [String: CGFloat] = splitPresentation
            ? ["modified": 170, "kind": 145, "size": 96, "created": 168, "dimensions": 125, "duration": 100]
            : ["modified": 168, "kind": 178, "size": 98, "created": 168, "dimensions": 125, "duration": 100]
        if showsSearchLocations {
            fixedWidths["location"] = min(searchLocationWidth ?? min(260, max(180, viewportWidth * 0.36)), max(150, viewportWidth - 210))
            fixedWidths["modified"] = 150; fixedWidths["size"] = 86
        }
        for column in table.tableColumns {
            let key = column.identifier.rawValue
            let chosenWidth = showsSearchLocations ? fixedWidths[key] : tabs[selectedTab].display.columnWidths[key].map({ CGFloat($0) }) ?? fixedWidths[key]
            if let width = chosenWidth, abs(column.width - width) > 0.5 {
                column.minWidth = 0
                column.maxWidth = 1200
                column.minWidth = 65
                column.width = width
            }
        }
        let visible = table.tableColumns.filter { !$0.isHidden }
        let fixedWidth = visible.filter { $0 !== nameColumn }.reduce(CGFloat.zero) { $0 + $1.width }
        let spacing = CGFloat(visible.count) * table.intercellSpacing.width
        // NSTableView's first-column autoresizing can collapse Name when Type is hidden.
        // Allocate the viewport explicitly, keeping metadata columns at their chosen widths.
        let desiredNameWidth = showsSearchLocations ? max(180, viewportWidth - fixedWidth - spacing)
            : tabs[selectedTab].display.columnWidths["name"].map({ CGFloat($0) }) ?? max(180, viewportWidth - fixedWidth - spacing)
        if abs(nameColumn.width - desiredNameWidth) > 0.5 { nameColumn.width = desiredNameWidth }
        let desiredTableWidth = max(viewportWidth, desiredNameWidth + fixedWidth + spacing)
        if abs(table.frame.width - desiredTableWidth) > 0.5 {
            table.setFrameSize(NSSize(width: desiredTableWidth, height: table.frame.height))
        }
    }

    private func configureNavigationButton(_ button: NSButton, symbol: String, label: String, action: Selector) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        button.imagePosition = .imageOnly
        button.bezelStyle = .accessoryBarAction
        button.isBordered = false
        button.contentTintColor = .black
        button.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 18, weight: .regular)
        button.toolTip = label
        button.setAccessibilityLabel(label)
        button.target = self
        button.action = action
        button.widthAnchor.constraint(equalToConstant: 36).isActive = true
        button.heightAnchor.constraint(equalToConstant: 34).isActive = true
    }

    private func configureTable() {
        table.delegate = self
        table.dataSource = self
        table.headerView = PaneTableHeaderView(frame: NSRect(x: 0, y: 0, width: 500, height: 42))
        table.rowHeight = 40
        table.intercellSpacing = NSSize(width: 12, height: 1)
        table.usesAlternatingRowBackgroundColors = false
        table.gridStyleMask = [.solidHorizontalGridLineMask]
        table.gridColor = NSColor(calibratedWhite: 0.88, alpha: 1)
        table.style = .plain
        table.selectionHighlightStyle = .regular
        table.allowsMultipleSelection = true
        table.allowsEmptySelection = true
        table.allowsColumnReordering = true
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.target = self
        table.doubleAction = #selector(doubleClicked)
        table.identifier = NSUserInterfaceItemIdentifier("browser.files")
        table.setAccessibilityIdentifier("browser.files")
        table.activate = { [weak self] in self?.activate() }
        table.keyHandler = { [weak self] event in self?.handleKey(event) ?? false }
        table.actionRequested = { [weak self] action in self?.request(action) }
        table.menu = contextMenu
        table.selectAllRequested = { [weak self] in self?.selectAllFiles() }
        (table.headerView as? PaneTableHeaderView)?.columnMenu = { [weak self] in self?.makeColumnMenu() ?? NSMenu() }
        contextMenu.delegate = self
        let definitions: [(String, String, CGFloat, CGFloat)] = [
            ("name", "Name", 285, 180), ("location", "Location", 220, 150), ("modified", "Date modified", 170, 150),
            ("kind", "Type", 145, 110), ("size", "Size", 96, 80),
            ("created", "Date created", 168, 100), ("dimensions", "Dimensions", 125, 80), ("duration", "Duration", 100, 70)
        ]
        for (key, title, width, minimum) in definitions {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(key))
            column.title = title
            column.headerCell = PaneTableHeaderCell(textCell: title)
            column.width = width
            column.minWidth = key == "name" ? minimum : width
            column.maxWidth = 1200
            column.resizingMask = .userResizingMask
            column.isHidden = !["name", "modified", "kind", "size"].contains(key)
            if !["location", "dimensions", "duration"].contains(key) { column.sortDescriptorPrototype = NSSortDescriptor(key: key, ascending: true) }
            if key == "size" { column.headerCell.alignment = .right }
            table.addTableColumn(column)
        }
        table.sortDescriptors = [NSSortDescriptor(key: "name", ascending: true)]
        table.registerForDraggedTypes([.fileURL])
        table.setDraggingSourceOperationMask([.copy, .move], forLocal: true)
        table.setDraggingSourceOperationMask(.copy, forLocal: false)
    }

    private func configureCollection() {
        let layout = NSCollectionViewFlowLayout()
        layout.itemSize = NSSize(width: 116, height: 112)
        layout.minimumInteritemSpacing = 8
        layout.minimumLineSpacing = 12
        layout.sectionInset = NSEdgeInsets(top: 16, left: 12, bottom: 16, right: 12)
        collection.collectionViewLayout = layout
        collection.dataSource = self
        collection.delegate = self
        collection.isSelectable = true
        collection.allowsMultipleSelection = true
        collection.backgroundColors = [.textBackgroundColor]
        collection.register(PaneIconItem.self, forItemWithIdentifier: NSUserInterfaceItemIdentifier("fileIcon"))
        collection.register(PaneGroupHeaderView.self, forSupplementaryViewOfKind: NSCollectionView.elementKindSectionHeader, withIdentifier: NSUserInterfaceItemIdentifier("groupHeader"))
        collection.setAccessibilityIdentifier("browser.icons")
        collection.setAccessibilityLabel("Files as icons")
        collection.activate = { [weak self] in self?.activate() }
        collection.openRequested = { [weak self] in self?.openSelection() }
        collection.keyHandler = { [weak self] event in self?.handleKey(event) ?? false }
        collection.actionRequested = { [weak self] action in self?.request(action) }
        collection.menu = contextMenu
        collection.registerForDraggedTypes([.fileURL])
        collection.setDraggingSourceOperationMask([.copy, .move], forLocal: true)
        collection.setDraggingSourceOperationMask(.copy, forLocal: false)
    }

    func setSort(key: String, ascending: Bool) {
        _ = view
        let mapped = ["date": "modified", "type": "kind"][key] ?? key
        guard ["name", "modified", "kind", "size", "created"].contains(mapped) || (isSearching && mapped == "bestMatch") else { return }
        if isSearching {
            tabs[selectedTab].searchSortKey = mapped
            tabs[selectedTab].searchAscending = mapped == "bestMatch" ? true : ascending
        } else {
            tabs[selectedTab].sortKey = mapped
            tabs[selectedTab].ascending = ascending
        }
        updateSortIndicator()
        applyFilterAndSort()
        onPresentationChange?()
    }

    private func updateSortIndicator() {
        let key = effectiveSortKey
        let descriptors = key == "bestMatch" ? [] : [NSSortDescriptor(key: key, ascending: currentSortAscending)]
        guard table.sortDescriptors != descriptors else { return }
        updatingSortIndicator = true
        table.sortDescriptors = descriptors
        updatingSortIndicator = false
    }

    func setExcludeGeneratedSearchResults(_ excluded: Bool) {
        guard tabs[selectedTab].excludeGenerated != excluded else { return }
        tabs[selectedTab].excludeGenerated = excluded
        guard isViewLoaded else { return }
        tabs[selectedTab].selection.formUnion(selectedURLs)
        stopIndexedSearch(resetPage: true)
        if isIndexedSearch { reload() } else { applyFilterAndSort() }
        updateSearchPresentation()
    }

    private static func canonicalMode(_ mode: String) -> String? {
        if mode == "icons" { return "mediumIcons" }
        return ["details", "list", "smallIcons", "mediumIcons", "largeIcons", "tiles"].contains(mode) ? mode : nil
    }

    func setViewMode(_ mode: String) {
        guard let mode = Self.canonicalMode(mode) else { return }
        _ = view
        rememberSelection()
        tabs[selectedTab].viewMode = mode
        updateDocumentView()
        applyFilterAndSort()
        onPresentationChange?()
    }

    func setGroupBy(_ key: String) {
        guard ["none", "name", "date", "type", "size"].contains(key) else { return }
        _ = view
        rememberSelection()
        tabs[selectedTab].groupBy = key
        applyFilterAndSort()
        onPresentationChange?()
    }

    func setDisplayPreferences(showExtensions: Bool, compact: Bool, defaultViewMode: String) {
        if isViewLoaded { tabs[selectedTab].selection.formUnion(selectedURLs) }
        self.showExtensions = showExtensions
        compactSpacing = compact
        if let mode = Self.canonicalMode(defaultViewMode), mode != self.defaultViewMode {
            self.defaultViewMode = mode
            for tab in tabs { tab.viewMode = mode }
        }
        guard isViewLoaded else { return }
        table.rowHeight = compact ? 28 : 40
        table.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<displayRows.count))
        updateDocumentView()
        applyFilterAndSort()
    }

    func restoreDisplaySettings(_ settings: [BrowserTabDisplaySettings]) {
        for (tab, saved) in zip(tabs, settings) {
            tab.display = saved
            tab.display.visibleColumns = Self.columnDefinitions.map(\.0).filter { $0 == "name" || saved.visibleColumns.contains($0) }
            tab.display.columnWidths = saved.columnWidths.filter { $0.value.isFinite && $0.value >= 65 && $0.value <= 1200 }
            tab.display.columnOrder = Array(NSOrderedSet(array: saved.columnOrder).array.compactMap { $0 as? String }).filter { key in Self.columnDefinitions.contains { $0.0 == key } }
            tab.viewMode = Self.canonicalMode(saved.viewMode) ?? defaultViewMode
            if !["name", "modified", "kind", "size", "created"].contains(tab.sortKey) { tab.sortKey = "name" }
            if !["none", "name", "date", "type", "size"].contains(tab.groupBy) { tab.groupBy = "none" }
            tab.columnsCustomized = saved.columnsCustomized
        }
        if isViewLoaded { refreshChrome(); applyColumnConfiguration(); updateDocumentView(); applyFilterAndSort() }
    }

    private func updateDocumentView() {
        table.selectionMarquee.finish()
        collection.selectionMarquee.finish()
        if isShowingThisMac {
            if thisMacController.parent == nil { addChild(thisMacController) }
            if let bodyContainer, thisMacController.view.superview == nil {
                bodyContainer.addSubview(thisMacController.view)
                edgePin(thisMacController.view, to: bodyContainer)
            }
            thisMacController.view.isHidden = false
            scrollView.isHidden = true
            messageLabel.isHidden = true
            return
        }
        if children.contains(where: { $0 === thisMacController }) { thisMacController.view.isHidden = true }
        scrollView.isHidden = false
        if viewMode != "details" {
            collection.frame = NSRect(origin: .zero, size: scrollView.contentSize)
            collection.autoresizingMask = [.width]
            scrollView.documentView = collection
            scrollView.hasHorizontalScroller = false
            configureCollectionLayout(force: true)
        } else {
            scrollView.documentView = table
            scrollView.hasHorizontalScroller = true
            applyColumnConfiguration()
        }
    }

    private func configureCollectionLayout(force: Bool = false) {
        guard viewMode != "details", let layout = collection.collectionViewLayout as? NSCollectionViewFlowLayout else { return }
        let width = fileViewportWidth
        if !force && abs(lastCollectionWidth - width) < 0.5 { return }
        lastCollectionWidth = width
        let compact = compactSpacing
        switch viewMode {
        case "list": layout.itemSize = NSSize(width: max(180, width - 24), height: compact ? 27 : 34)
        case "smallIcons": layout.itemSize = NSSize(width: 190, height: compact ? 29 : 38)
        case "largeIcons": layout.itemSize = NSSize(width: 164, height: compact ? 163 : 179)
        case "tiles":
            // Flow layout centers a lone fixed-width item in a wider slot. Fill
            // each available column so narrow panes retain the same left inset.
            let gap: CGFloat = compact ? 5 : 8
            let available = max(1, width - 24)
            let columns = max(1, floor((available + gap) / (284 + gap)))
            let itemWidth = (available - gap * (columns - 1)) / columns
            layout.itemSize = NSSize(width: itemWidth, height: compact ? 72 : 84)
        default: layout.itemSize = NSSize(width: 116, height: compact ? 103 : 116)
        }
        if showsSearchLocations && viewMode != "tiles" { layout.itemSize.height += 20 }
        layout.minimumInteritemSpacing = compact ? 5 : 8
        layout.minimumLineSpacing = compact ? 4 : 12
        layout.sectionInset = NSEdgeInsets(top: compact ? 8 : 14, left: 12, bottom: compact ? 8 : 14, right: 12)
        layout.headerReferenceSize = NSSize(width: width, height: currentGroupBy == "none" ? 0 : (compact ? 30 : 36))
        layout.invalidateLayout()
    }

    // MARK: Navigation and tabs

    func navigate(to url: URL) {
        _ = view
        activate()
        rememberSelection()
        let destination = Self.normalizedLocation(url)
        if destination != currentURL || isShowingRecents {
            let tab = tabs[selectedTab]
            tab.history = Array(tab.history.prefix(tab.historyIndex + 1))
            tab.history.append(Location(url: destination, isRecents: false))
            tab.historyIndex = tab.history.count - 1
            tab.query = ""
            tab.selection = []
        }
        directoryChanged()
    }

    func goBack() {
        guard tabs[selectedTab].historyIndex > 0 else { return }
        activate()
        tabs[selectedTab].historyIndex -= 1
        tabs[selectedTab].selection = []
        tabs[selectedTab].query = ""
        directoryChanged()
    }

    func goForward() {
        let tab = tabs[selectedTab]
        guard tab.historyIndex + 1 < tab.history.count else { return }
        activate()
        tab.historyIndex += 1
        tab.selection = []
        tab.query = ""
        directoryChanged()
    }

    func goUp() {
        guard !isShowingThisMac else { return }
        let parent = currentURL.deletingLastPathComponent()
        if parent != currentURL { navigate(to: parent) }
    }

    func addTab(url: URL? = nil) {
        _ = view
        rememberSelection()
        let tab = Tab(url ?? currentURL)
        tab.recursiveSearch = tabs[selectedTab].recursiveSearch
        tab.viewMode = defaultViewMode
        tabs.append(tab)
        selectedTab = tabs.count - 1
        activate()
        directoryChanged()
    }

    func closeCurrentTab() {
        guard tabs.count > 1 else { view.window?.performClose(nil); return }
        closeTab(at: selectedTab)
    }

    func restoreTabs(_ urls: [URL], selectedIndex: Int = 0) {
        guard !urls.isEmpty else { return }
        tabs = urls.prefix(20).map { let tab = Tab($0); tab.viewMode = defaultViewMode; return tab }
        selectedTab = min(max(0, selectedIndex), tabs.count - 1)
        if isViewLoaded { directoryChanged() }
    }

    /// Follow a completed move without adding history or changing a tab's options.
    /// Comparing path components prevents renaming "Work" from relocating "Work-old".
    func relocateAfterMove(from source: URL, to destination: URL) {
        let source = source.standardizedFileURL
        let destination = destination.standardizedFileURL
        guard source.isFileURL, destination.isFileURL, source.path != destination.path else { return }
        let sourceComponents = source.pathComponents
        func relocated(_ url: URL) -> URL {
            let normalized = url.standardizedFileURL
            let components = normalized.pathComponents
            guard normalized.isFileURL, components.count >= sourceComponents.count,
                  Array(components.prefix(sourceComponents.count)) == sourceComponents else { return url }
            let newURL = components.dropFirst(sourceComponents.count).reduce(destination) { $0.appendingPathComponent($1) }
            return URL(fileURLWithPath: newURL.path, isDirectory: url.hasDirectoryPath).standardizedFileURL
        }

        let previousCurrentURL = currentURL
        if isViewLoaded { tabs[selectedTab].selection.formUnion(selectedURLs) }
        let previousSelection = tabs[selectedTab].selection
        var changed = false
        for tab in tabs {
            tab.history = tab.history.map { location in
                let movedURL = relocated(location.url)
                if movedURL != location.url { changed = true }
                return Location(url: movedURL, isRecents: location.isRecents)
            }
            let movedSelection = Set(tab.selection.map(relocated))
            if movedSelection != tab.selection { changed = true }
            tab.selection = movedSelection
        }
        guard isViewLoaded else { return }
        let contentsAffected = currentURL != previousCurrentURL || previousSelection != tabs[selectedTab].selection
            || entries.contains { relocated($0.url) != $0.url }
            || source.deletingLastPathComponent().path == previousCurrentURL.path
            || destination.deletingLastPathComponent().path == currentURL.path
            || (tabs[selectedTab].recursiveSearch && source.pathComponents.starts(with: previousCurrentURL.pathComponents))
        if contentsAffected {
            directoryChanged()
        } else if changed {
            refreshChrome()
            onDirectoryChange?(currentURL)
        }
    }

    @discardableResult
    func endSelectionGesture(cancelled: Bool = false) -> Bool {
        let active = table.selectionMarquee.isActive || collection.selectionMarquee.isActive
        table.selectionMarquee.finish(cancelled: cancelled)
        collection.selectionMarquee.finish(cancelled: cancelled)
        return active
    }

    func focusAddress() {
        _ = view
        table.selectionMarquee.finish(); collection.selectionMarquee.finish()
        activate()
        focusingAddress = true
        defer { focusingAddress = false }
        addressField.stringValue = isShowingThisMac ? "This Mac" : currentURL.path
        setAddressEditing(true)
        addressBox.layoutSubtreeIfNeeded()
        view.window?.makeFirstResponder(addressField)
        if let editor = addressField.currentEditor() {
            editor.selectedRange = NSRange(location: 0, length: (editor.string as NSString).length)
        }
    }

    private func setAddressEditing(_ editing: Bool) {
        addressField.isHidden = !editing
        addressIcon.isHidden = !editing
        breadcrumb.isHidden = editing
        addressBox.focusHighlighted = editing
    }

    func focusSearch() {
        _ = view
        table.selectionMarquee.finish(); collection.selectionMarquee.finish()
        activate()
        view.window?.makeFirstResponder(searchField)
        if let editor = searchField.currentEditor() {
            editor.selectedRange = NSRange(location: 0, length: (editor.string as NSString).length)
        }
    }

    func focusFiles() {
        _ = view
        activate()
        if isShowingThisMac { thisMacController.focusContents(); return }
        view.window?.makeFirstResponder(viewMode != "details" ? collection : table)
    }

    func selectAllFiles() {
        focusFiles()
        guard !isShowingThisMac else { return }
        if viewMode != "details" {
            collection.selectionIndexPaths = Set(groups.enumerated().flatMap { section, group in group.entries.indices.map { IndexPath(item: $0, section: section) } })
            collectionSelectionChanged()
        } else {
            table.selectRowIndexes(IndexSet(displayRows.indices.filter { entry(atRow: $0) != nil }), byExtendingSelection: false)
        }
    }

    func setActive(_ active: Bool) {
        let changed = isActivePane != active
        isActivePane = active
        if isViewLoaded {
            refreshActiveAppearance()
            if changed { rebuildTabs() }
            if active { onStatusChange?(statusLabel.stringValue) }
        }
    }

    func setHiddenFiles(_ show: Bool) {
        guard showHidden != show else { return }
        showHidden = show
        if isViewLoaded { reload() }
    }

    func setCutURLs(_ urls: Set<URL>) {
        cutURLs = Set(urls.map(\.standardizedFileURL))
        guard isViewLoaded else { return }
        let retainedSelection = tabs[selectedTab].selection.union(selectedURLs)
        tabs[selectedTab].selection = retainedSelection
        reloadPresentations(retaining: retainedSelection)
        updateStatus()
        onSelectionChange?(selectedURLs)
    }

    func openSelection() {
        activate()
        let selected = selectedURLs
        guard !selected.isEmpty else { return }
        for url in selected { openURL(url, folderInNewWindow: selected.count > 1) }
    }

    func openURL(_ url: URL) { openURL(url, folderInNewWindow: false) }

    private func openURL(_ url: URL, folderInNewWindow: Bool) {
        activate()
        do {
            let shortcut = ShortcutSupport.isShortcut(url)
            let target = try ShortcutSupport.resolve(url)
            if ShortcutSupport.isBrowsableFolder(target) {
                if shortcut || folderInNewWindow {
                    guard let onOpenFolderWindow else {
                        reportOpenError("A new WinExplorer for Mac window could not be opened for “\(target.lastPathComponent)”.")
                        return
                    }
                    onOpenFolderWindow(target)
                } else { navigate(to: target) }
            } else if !openFile(target) {
                reportOpenError("“\(target.lastPathComponent)” could not be opened with its default application.")
            }
        } catch { reportOpenError(error.localizedDescription) }
    }

    private func reportOpenError(_ message: String) {
        if let onOpenError { onOpenError(message); return }
        let alert = NSAlert()
        alert.messageText = "The item could not be opened"
        alert.informativeText = message
        if let window = view.window, window.attachedSheet == nil { alert.beginSheetModal(for: window) }
    }

    private var canOpenSelectionInNewWindow: Bool {
        !selectedURLs.isEmpty && selectedURLs.allSatisfy { url in
            guard let target = try? ShortcutSupport.resolve(url) else { return false }
            return ShortcutSupport.isBrowsableFolder(target)
        }
    }

    private func directoryChanged() {
        searchWork?.cancel()
        loadCancellation?.cancel()
        stopIndexedSearch(resetPage: true)
        loadID = UUID()
        entries = []
        visibleEntries = []
        displayRows = []; groups = []
        restoringSelection = true
        table.reloadData()
        collection.reloadData()
        restoringSelection = false
        onSelectionChange?([])
        refreshChrome()
        updateDocumentView()
        onDirectoryChange?(currentURL)
        installDirectoryWatcher()
        reload()
    }

    private func activate() { onActivate?() }

    private func rememberSelection() {
        if isViewLoaded { tabs[selectedTab].selection = Set(selectedURLs) }
    }

    private func closeTab(at index: Int) {
        guard tabs.indices.contains(index) else { return }
        if tabs.count == 1 { view.window?.performClose(nil); return }
        rememberSelection()
        let closedActive = index == selectedTab
        tabs.remove(at: index)
        if index < selectedTab { selectedTab -= 1 }
        else if selectedTab >= tabs.count { selectedTab = tabs.count - 1 }
        activate()
        if closedActive {
            directoryChanged()
        } else {
            rebuildTabs()
            onDirectoryChange?(currentURL)
        }
    }

    private func refreshChrome() {
        addressField.stringValue = isShowingThisMac ? "This Mac" : currentURL.path
        setAddressEditing(false)
        breadcrumb.url = currentURL
        breadcrumb.virtualTitle = isShowingThisMac ? "This Mac" : (isShowingRecents ? "Recents" : nil)
        searchField.stringValue = tabs[selectedTab].query
        let folderName = isShowingThisMac ? "This Mac" : (isShowingRecents ? "Recents" : (currentURL.lastPathComponent.isEmpty ? "Macintosh HD" : currentURL.lastPathComponent))
        searchField.isEnabled = !isShowingThisMac
        searchField.placeholderString = "Search \(folderName)"
        updateSearchToolTip()
        scopeButton.isEnabled = !isShowingThisMac
        backButton.isEnabled = tabs[selectedTab].historyIndex > 0
        forwardButton.isEnabled = tabs[selectedTab].historyIndex + 1 < tabs[selectedTab].history.count
        upButton.isEnabled = !isShowingThisMac && currentURL.path != "/"
        for button in [backButton, forwardButton, upButton] {
            button.contentTintColor = button.isEnabled ? .black : .disabledControlTextColor
        }
        table.setAccessibilityLabel("Files in \(currentURL.lastPathComponent)")
        updateSortIndicator()
        rebuildTabs()
        refreshActiveAppearance()
    }

    private func rebuildTabs() {
        for child in tabStrip.arrangedSubviews { tabStrip.removeArrangedSubview(child); child.removeFromSuperview() }
        for (index, tab) in tabs.enumerated() {
            let name = tab.isRecents ? "Recents" : (tab.url == Self.thisMacURL ? "This Mac" : (tab.url.lastPathComponent.isEmpty ? "Macintosh HD" : tab.url.lastPathComponent))
            let activeBadge = splitPresentation && isActivePane && index == selectedTab
            let group = PaneTabView(title: name, current: index == selectedTab, activeBadge: activeBadge)
            group.onSelect = { [weak self] in
                guard let self, self.tabs.indices.contains(index) else { return }
                guard self.selectedTab != index else { self.focusFiles(); return }
                self.rememberSelection()
                self.selectedTab = index
                self.activate()
                self.directoryChanged()
            }
            group.onClose = { [weak self] in self?.closeTab(at: index) }
            group.toolTip = tab.isRecents ? "Recently opened files" : tab.url.path
            let titleWidth = ceil((name as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 17)]).width)
            let requiredWidth = titleWidth + (activeBadge ? 147 : 91)
            let baselineWidth: CGFloat = splitPresentation ? (activeBadge ? 220 : 190) : 210
            group.widthAnchor.constraint(equalToConstant: min(300, max(baselineWidth, requiredWidth))).isActive = true
            group.heightAnchor.constraint(equalToConstant: 42).isActive = true
            tabStrip.addArrangedSubview(group)
        }
        let add = PaneClosureButton(image: NSImage(systemSymbolName: "plus", accessibilityDescription: "New tab")!)
        add.target = self
        add.action = #selector(newTabPressed)
        add.bezelStyle = .inline
        add.isBordered = false
        add.contentTintColor = .black
        add.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 22, weight: .regular)
        add.toolTip = "New tab (Command-T or Control-T)"
        add.widthAnchor.constraint(equalToConstant: 42).isActive = true
        tabStrip.addArrangedSubview(add)
    }

    private func refreshActiveAppearance() {
        accent.layer?.backgroundColor = (isActivePane ? NSColor.controlAccentColor : NSColor.separatorColor.withAlphaComponent(0.4)).cgColor
    }

    @objc private func tabPressed(_ sender: NSButton) {
        guard tabs.indices.contains(sender.tag) else { return }
        rememberSelection()
        selectedTab = sender.tag
        activate()
        directoryChanged()
    }
    @objc private func closeTabPressed(_ sender: NSButton) { closeTab(at: sender.tag) }
    @objc private func newTabPressed() { addTab() }
    @objc private func back() { goBack() }
    @objc private func forward() { goForward() }
    @objc private func up() { goUp() }
    @objc private func doubleClicked() { if entry(atRow: table.clickedRow) != nil { openSelection() } }

    @objc private func addressSubmitted() {
        let text = addressField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { addressField.stringValue = currentURL.path; return }
        if text.caseInsensitiveCompare("This Mac") == .orderedSame || text == Self.thisMacURL.absoluteString {
            showThisMac()
            focusFiles()
            return
        }
        let destination: URL
        if text.hasPrefix("file://"), let url = URL(string: text), url.isFileURL {
            destination = url
        } else {
            let expanded = (text as NSString).expandingTildeInPath
            destination = expanded.hasPrefix("/") ? URL(fileURLWithPath: expanded) : currentURL.appendingPathComponent(expanded)
        }
        navigate(to: destination)
        focusFiles()
    }

    @objc private func searchChanged() {
        searchTraceID &+= 1
        searchTraceStart = ProcessInfo.processInfo.systemUptime
        traceSearch("input")
        tabs[selectedTab].query = searchField.stringValue
        searchWork?.cancel()
        updateSearchPresentation()
        if tabs[selectedTab].recursiveSearch && !isVirtualLocation {
            loadCancellation?.cancel()
            loadID = UUID()
            stopIndexedSearch(resetPage: true)
            entries = []; visibleEntries = []; groups = []; displayRows = []
            reloadPresentations(retaining: tabs[selectedTab].selection)
            onSelectionChange?([])
            loading = true; loadError = nil
            updateStatus()
            traceSearch("cleared")
            let work = DispatchWorkItem { [weak self] in self?.searchWork = nil; self?.reload() }
            searchWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.075, execute: work)
        } else {
            applyFilterAndSort()
        }
    }

    /// The same entry point used by the search field, also useful for focused UI fixtures.
    func searchFiles(_ query: String, recursively: Bool) {
        _ = view
        searchWork?.cancel(); searchWork = nil
        tabs[selectedTab].recursiveSearch = recursively
        searchField.stringValue = query
        if !recursively {
            stopIndexedSearch(resetPage: true)
            tabs[selectedTab].query = query
            updateSearchPresentation()
            reload()
        } else { searchChanged() }
    }

    @objc private func searchScopePressed() {
        activate()
        let menu = NSMenu(); menu.autoenablesItems = false
        if isShowingRecents {
            let recent = NSMenuItem(title: "Recently opened files", action: nil, keyEquivalent: "")
            recent.state = .on; recent.isEnabled = false
            menu.addItem(recent)
        }
        for (index, title) in ["This folder", "Include subfolders"].enumerated() {
            if isShowingRecents { break }
            let item = NSMenuItem(title: title, action: #selector(searchScopeSelected(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            item.state = tabs[selectedTab].recursiveSearch == (index == 1) ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let filter = NSMenuItem(title: "Exclude caches and generated folders", action: #selector(toggleGeneratedSearchResults), keyEquivalent: "")
        filter.target = self
        filter.state = excludesGeneratedSearchResults ? .on : .off
        filter.toolTip = "Hide common cache, dependency, and build folders below the search location. Turn this off to include them. Searching one of these folders directly still works."
        menu.addItem(filter)
        let best = NSMenuItem(title: "Best match", action: #selector(selectBestMatch), keyEquivalent: "")
        best.target = self; best.isEnabled = isSearching
        best.state = effectiveSortKey == "bestMatch" ? .on : .off
        menu.addItem(best)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: scopeButton.bounds.minY), in: scopeButton)
    }

    @objc private func searchScopeSelected(_ sender: NSMenuItem) {
        searchWork?.cancel()
        searchWork = nil
        stopIndexedSearch(resetPage: true)
        tabs[selectedTab].recursiveSearch = sender.tag == 1
        updateSearchPresentation()
        reload()
        onPresentationChange?()
    }

    @objc private func toggleGeneratedSearchResults() { setExcludeGeneratedSearchResults(!excludesGeneratedSearchResults) }
    @objc private func selectBestMatch() { setSort(key: "bestMatch", ascending: true) }

    private func updateSearchPresentation() {
        updateSortIndicator()
        applyColumnConfiguration(); fitTableColumns()
        configureCollectionLayout(force: true)
        updateSearchToolTip()
        updateStatus()
    }

    private func updateSearchToolTip() {
        let scope = isShowingRecents ? "Search recently opened filenames"
            : (tabs[selectedTab].recursiveSearch ? "Search filenames in this folder and subfolders" : "Search filenames in this folder")
        searchField.toolTip = scope + (excludesGeneratedSearchResults ? ". Caches and generated folders excluded." : "")
    }

    func controlTextDidBeginEditing(_ obj: Notification) { activate() }

    func controlTextDidEndEditing(_ obj: Notification) {
        if let field = obj.object as? NSTextField, field === addressField, !focusingAddress {
            setAddressEditing(false)
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if control === addressField && commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            addressField.stringValue = isShowingThisMac ? "This Mac" : currentURL.path
            setAddressEditing(false)
            focusFiles()
            return true
        }
        return false
    }

    func controlTextDidChange(_ obj: Notification) {
        if let control = obj.object as? NSSearchField, control === searchField { searchChanged() }
    }

    // MARK: Loading and watching

    func reload() {
        guard isViewLoaded else { return }
        table.selectionMarquee.finish(); collection.selectionMarquee.finish()
        if isIndexedSearch {
            startIndexedSearchIfNeeded()
            return
        }
        stopIndexedSearch(resetPage: false)
        if isShowingThisMac {
            loading = false; loadError = nil
            entries = []; visibleEntries = []; groups = []; displayRows = []
            thisMacController.refresh()
            updateStatus()
            return
        }
        loadCancellation?.cancel()
        let cancellation = PaneSearchCancellation()
        loadCancellation = cancellation
        let token = UUID()
        loadID = token
        let directory = currentURL
        let hidden = showHidden
        let recentURLs: [URL]? = isShowingRecents ? NSDocumentController.shared.recentDocumentURLs : nil
        loading = true
        loadError = nil
        searchWarningCount = 0
        updateStatus()
        enumerationQueue.async { [weak self] in
            let result: Result<([Entry], Int), Error> = Result {
                let manager = FileManager.default
                let options: FileManager.DirectoryEnumerationOptions = hidden ? [] : [.skipsHiddenFiles]
                let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .isAliasFileKey, .isSymbolicLinkKey, .fileSizeKey,
                                             .contentModificationDateKey, .creationDateKey, .localizedTypeDescriptionKey]
                if let recentURLs {
                    var seen = Set<URL>()
                    let recent = recentURLs.filter { seen.insert($0.standardizedFileURL).inserted && manager.fileExists(atPath: $0.path) }
                    return (recent.map(Entry.init), 0)
                }
                let directURLs = try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys, options: options)
                var result: [Entry] = []
                for url in directURLs {
                    if cancellation.isCancelled { throw CocoaError(.userCancelled) }
                    result.append(Entry(url: url))
                }
                return (result, 0)
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.loadID == token, self.currentURL == directory else { return }
                self.loading = false
                switch result {
                case .success(let payload):
                    let (items, warnings) = payload
                    // A selection may have changed while enumeration ran. Preserve the latest
                    // selection, not the snapshot from the start of an asynchronous reload.
                    let retainedSelection = self.tabs[self.selectedTab].selection.union(self.selectedURLs)
                    self.entries = items
                    self.tabs[self.selectedTab].selection = retainedSelection.intersection(Set(items.map(\.url)))
                    self.loadError = nil
                    self.searchWarningCount = warnings
                case .failure(let error):
                    self.entries = []
                    self.tabs[self.selectedTab].selection = []
                    self.loadError = "Couldn’t open \(directory.lastPathComponent.isEmpty ? "/" : directory.lastPathComponent).\n\(error.localizedDescription)\nCheck that the folder exists and that WinExplorer for Mac has access."
                }
                self.applyFilterAndSort()
                if self.directoryWatcher == nil { self.installDirectoryWatcher() }
            }
        }
    }

    private var isIndexedSearch: Bool {
        !isVirtualLocation && tabs[selectedTab].recursiveSearch
            && !tabs[selectedTab].query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func traceSearch(_ stage: String) {
        guard traceSearchTimings else { return }
        let milliseconds = (ProcessInfo.processInfo.systemUptime - searchTraceStart) * 1000
        let message = String(format: "SEARCH[%d] %.2f ms %@\n", searchTraceID, milliseconds, stage)
        FileHandle.standardError.write(Data(message.utf8))
    }

    private var indexedPresentationOptions: IndexedPresentation {
        let tab = tabs[selectedTab]
        return IndexedPresentation(sortKey: effectiveSortKey, ascending: currentSortAscending, groupBy: tab.groupBy,
                                   showExtensions: showExtensions, limit: searchPageLimit)
    }

    private func stopIndexedSearch(resetPage: Bool) {
        indexedSubscription?.cancel(); indexedSubscription = nil
        indexedPreparation?.cancel(); indexedPreparation = nil
        indexedPreparationID = UUID()
        indexedQuery = nil; indexedSnapshot = nil
        indexedPreparedOptions = nil; indexedRunningOptions = nil
        indexedPreparing = false; indexedNeedsPreparation = false
        indexedIsComplete = false
        indexedQueryFinished = false; indexedIsIndexing = false; indexedIsUpdating = false
        indexedErrorMessage = nil
        if resetPage { searchPageLimit = 1000; indexedTotalMatchCount = 0 }
        searchPagingRow.isHidden = true
    }

    /// Ordinary reloads reuse the subscription. Only an explicit refresh requests reconciliation.
    func refreshSearchIndex() {
        if !isVirtualLocation { searchIndex.invalidate(in: currentURL) }
        reload()
    }

    private func startIndexedSearchIfNeeded() {
        guard isIndexedSearch else { return }
        let options = indexedPresentationOptions
        let canUsePage = options.sortKey == "bestMatch" || (options.sortKey == "name" && options.ascending)
        let requestedLimit = canUsePage && options.groupBy == "none" ? searchPageLimit : 0
        let request = IndexedQuery(directory: currentURL,
                                   query: tabs[selectedTab].query.trimmingCharacters(in: .whitespacesAndNewlines),
                                   hidden: showHidden, limit: requestedLimit, bestMatch: options.sortKey == "bestMatch",
                                   excludeGenerated: excludesGeneratedSearchResults)
        guard request != indexedQuery || indexedSubscription == nil else { return }
        stopIndexedSearch(resetPage: false)
        loadCancellation?.cancel()
        let generation = UUID()
        loadID = generation
        indexedQuery = request
        loading = true; loadError = nil; searchWarningCount = 0
        updateStatus()
        traceSearch("subscribe")
        indexedSubscription = searchIndex.search(in: request.directory, query: request.query,
                                                includeHidden: request.hidden, limit: request.limit,
                                                order: request.bestMatch ? .bestMatch : .name,
                                                excludeGenerated: request.excludeGenerated) { [weak self] snapshot in
            guard let self, self.loadID == generation, self.indexedQuery == request, self.isIndexedSearch else { return }
            self.traceSearch("snapshot \(snapshot.entries.count) complete=\(snapshot.isComplete)")
            // Counting a broad match may leave the first page unchanged for many updates.
            // Keep those updates cheap, and avoid an unbounded comparison on the main
            // thread for the all-candidate metadata-sort path. Each completed query
            // rehydrates, even if background maintenance continues, so attribute
            // changes remain visible while the catalog is being updated.
            let unchangedPartial = !snapshot.queryFinished && snapshot.entries.count <= self.searchPageLimit
                && self.indexedSnapshot?.entries == snapshot.entries
            self.indexedSnapshot = snapshot
            self.indexedTotalMatchCount = snapshot.totalMatchCount
            self.indexedIsComplete = snapshot.isComplete
            self.indexedQueryFinished = snapshot.queryFinished
            self.indexedIsIndexing = snapshot.isIndexing
            self.indexedIsUpdating = snapshot.isUpdating
            self.searchWarningCount = snapshot.warningCount
            self.indexedErrorMessage = snapshot.errorMessage
            if unchangedPartial {
                self.loading = true
                self.updateStatus()
                return
            }
            self.indexedNeedsPreparation = true
            self.loading = true
            self.prepareIndexedResultsIfNeeded()
        }
    }

    @objc private func showMoreSearchResults() {
        guard isIndexedSearch, indexedTotalMatchCount > visibleEntries.count else { return }
        tabs[selectedTab].selection.formUnion(selectedURLs)
        searchPageLimit = min(Int.max - 1000, searchPageLimit) + 1000
        startIndexedSearchIfNeeded()
        prepareIndexedResultsIfNeeded()
    }

    /// Only this bounded, fully prepared page is ever handed to AppKit. A newer catalog
    /// snapshot queues behind a running preparation, rather than perpetually cancelling it.
    private func prepareIndexedResultsIfNeeded() {
        guard isIndexedSearch, let snapshot = indexedSnapshot else { return }
        let options = indexedPresentationOptions
        if indexedPreparing {
            if indexedRunningOptions == options { return }
            indexedPreparation?.cancel()
            indexedPreparationID = UUID()
            indexedPreparing = false
        }
        guard indexedNeedsPreparation || indexedPreparedOptions != options else {
            configureCollectionLayout(force: true)
            reloadPresentations(retaining: tabs[selectedTab].selection)
            updateStatus()
            return
        }
        let cancellation = PaneSearchCancellation()
        indexedPreparation = cancellation
        let preparationID = UUID(), generation = loadID
        indexedPreparationID = preparationID
        indexedRunningOptions = options
        indexedPreparing = true
        indexedNeedsPreparation = false
        loading = true
        updateStatus()
        traceSearch("prepare \(snapshot.entries.count)")
        enumerationQueue.async { [weak self] in
            var candidates: [Entry] = []
            candidates.reserveCapacity(snapshot.entries.count)
            for item in snapshot.entries {
                if cancellation.isCancelled { return }
                candidates.append(options.needsAllMetadata ? Entry(url: item.url) : Entry(indexed: item))
            }
            if options.sortKey != "bestMatch" { Self.sortEntries(&candidates, key: options.sortKey, ascending: options.ascending) }
            if cancellation.isCancelled { return }
            let allGroups = Self.groupEntries(candidates, by: options.groupBy, showExtensions: options.showExtensions)
            var remaining = options.limit
            var pageGroups: [EntryGroup] = []
            for group in allGroups where remaining > 0 {
                var page: [Entry] = []
                for item in group.entries.prefix(remaining) {
                    if cancellation.isCancelled { return }
                    page.append(options.needsAllMetadata ? item : Entry(url: item.url))
                }
                remaining -= page.count
                pageGroups.append(EntryGroup(title: group.title, entries: page, totalCount: group.entries.count))
            }
            let page = pageGroups.flatMap(\.entries)
            let rows = Self.rows(for: pageGroups)
            if cancellation.isCancelled { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.loadID == generation, self.indexedPreparationID == preparationID,
                      self.isIndexedSearch, !cancellation.isCancelled else { return }
                self.traceSearch("metadata ready \(page.count)")
                self.indexedPreparing = false
                self.indexedPreparedOptions = options
                self.table.selectionMarquee.finish()
                self.collection.selectionMarquee.finish()
                let retainedSelection = self.tabs[self.selectedTab].selection.union(self.selectedURLs)
                self.tabs[self.selectedTab].selection = retainedSelection
                self.entries = page; self.visibleEntries = page
                self.groups = pageGroups; self.displayRows = rows
                self.loading = !snapshot.isComplete || self.indexedNeedsPreparation
                self.configureCollectionLayout(force: true)
                self.reloadPresentations(retaining: retainedSelection)
                self.updateStatus()
                self.traceSearch("published \(page.count)")
                self.onSelectionChange?(self.selectedURLs)
                if self.indexedNeedsPreparation { self.prepareIndexedResultsIfNeeded() }
            }
        }
    }

    private func displayName(_ entry: Entry) -> String {
        Self.displayName(entry, showExtensions: showExtensions)
    }

    private func resultLocation(_ entry: Entry) -> String {
        let parent = entry.url.deletingLastPathComponent().standardizedFileURL
        let root = currentURL.standardizedFileURL
        if !isShowingRecents && parent == root { return "This folder" }
        let rootParts = root.pathComponents, parentParts = parent.pathComponents
        if !isShowingRecents && parentParts.starts(with: rootParts) {
            return parentParts.dropFirst(rootParts.count).joined(separator: " / ")
        }
        return (parent.path as NSString).abbreviatingWithTildeInPath
    }

    private static func displayName(_ entry: Entry, showExtensions: Bool) -> String {
        if entry.isAppShortcut { return entry.url.deletingPathExtension().lastPathComponent }
        guard !showExtensions, !entry.isFolder, !entry.name.hasPrefix("."), !entry.url.pathExtension.isEmpty else { return entry.name }
        return (entry.name as NSString).deletingPathExtension
    }

    private func entry(atRow row: Int) -> Entry? {
        guard displayRows.indices.contains(row), case .file(let entry) = displayRows[row] else { return nil }
        return entry
    }

    private func entry(at indexPath: IndexPath) -> Entry? {
        guard groups.indices.contains(indexPath.section), groups[indexPath.section].entries.indices.contains(indexPath.item) else { return nil }
        return groups[indexPath.section].entries[indexPath.item]
    }

    private func rebuildGroups() {
        groups = Self.groupEntries(visibleEntries, by: currentGroupBy, showExtensions: showExtensions)
        displayRows = Self.rows(for: groups)
        configureCollectionLayout(force: true)
    }

    private static func rows(for groups: [EntryGroup]) -> [DisplayRow] {
        groups.flatMap { group in
            (group.title.isEmpty ? [] : [.header("\(group.title) (\(group.totalCount ?? group.entries.count))")])
                + group.entries.map(DisplayRow.file)
        }
    }

    private static func groupEntries(_ entries: [Entry], by groupBy: String, showExtensions: Bool) -> [EntryGroup] {
        guard groupBy != "none" else { return [EntryGroup(title: "", entries: entries)] }
        let calendar = Calendar.current
        let now = Date()
        func bucket(_ entry: Entry) -> (Int, String) {
            switch groupBy {
            case "name":
                let initial = String(displayName(entry, showExtensions: showExtensions).prefix(1)).uppercased()
                return (initial.unicodeScalars.allSatisfy { CharacterSet.letters.contains($0) } ? 1 : 0, initial.unicodeScalars.allSatisfy { CharacterSet.letters.contains($0) } ? initial : "#")
            case "type": return (entry.isFolder ? 0 : 1, entry.isFolder ? "Folders" : entry.kind)
            case "size":
                if entry.isFolder { return (0, "Folders") }
                if entry.size == 0 { return (1, "Empty (0 bytes)") }
                if entry.size < 1_048_576 { return (2, "Small (under 1 MB)") }
                if entry.size < 104_857_600 { return (3, "Medium (1–100 MB)") }
                return (4, "Large (100 MB or more)")
            default:
                guard let date = entry.modified else { return (6, "Unknown date") }
                if calendar.isDateInToday(date) { return (0, "Today") }
                if calendar.isDateInYesterday(date) { return (1, "Yesterday") }
                if let interval = calendar.dateInterval(of: .weekOfYear, for: now), interval.contains(date) { return (2, "This week") }
                if let interval = calendar.dateInterval(of: .month, for: now), interval.contains(date) { return (3, "This month") }
                return date > now ? (4, "Later") : (5, "Earlier")
            }
        }
        var indexed: [String: EntryGroup] = [:]
        var ranks: [String: Int] = [:]
        for entry in entries {
            let (rank, title) = bucket(entry)
            indexed[title, default: EntryGroup(title: title, entries: [])].entries.append(entry)
            ranks[title] = rank
        }
        return indexed.values.sorted {
            if ranks[$0.title] != ranks[$1.title] { return ranks[$0.title, default: 0] < ranks[$1.title, default: 0] }
            return $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
    }

    private static let columnDefinitions: [(String, String)] = [("name", "Name"), ("modified", "Date modified"), ("kind", "Type"), ("size", "Size"), ("created", "Date created"), ("dimensions", "Dimensions"), ("duration", "Duration")]

    func showColumnMenu(relativeTo view: NSView) {
        makeColumnMenu().popUp(positioning: nil, at: NSPoint(x: 0, y: view.bounds.maxY), in: view)
    }

    private func makeColumnMenu() -> NSMenu {
        let menu = NSMenu(); menu.autoenablesItems = false
        if showsSearchLocations {
            let location = NSMenuItem(title: "Location (search results)", action: nil, keyEquivalent: "")
            location.state = .on; location.isEnabled = false
            menu.addItem(location)
            menu.addItem(.separator())
        }
        for (key, title) in Self.columnDefinitions {
            let item = NSMenuItem(title: title, action: #selector(toggleColumn(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = key
            item.state = table.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier(key))?.isHidden == false ? .on : .off
            item.isEnabled = key != "name"
            menu.addItem(item)
        }
        return menu
    }

    @objc private func toggleColumn(_ item: NSMenuItem) {
        guard let key = item.representedObject as? String, key != "name" else { return }
        let tab = tabs[selectedTab]
        var shown = Set(table.tableColumns.filter { !$0.isHidden }.map { $0.identifier.rawValue })
        if shown.contains(key) { shown.remove(key) } else { shown.insert(key) }
        shown.insert("name")
        tab.display.visibleColumns = Self.columnDefinitions.map(\.0).filter { shown.contains($0) }
        tab.columnsCustomized = true
        applyColumnConfiguration(); fitTableColumns()
        reloadPresentations(retaining: tabs[selectedTab].selection)
        onPresentationChange?()
    }

    private func applyColumnConfiguration() {
        guard !adjustingColumns else { return }
        adjustingColumns = true
        defer { adjustingColumns = false }
        let tab = tabs[selectedTab]
        var visible = Set(tab.columnsCustomized ? tab.display.visibleColumns : ["name", "modified", "kind", "size"])
        visible.insert("name")
        if showsSearchLocations {
            visible.insert("location")
            if !tab.columnsCustomized {
                visible = ["name", "location", "size"]
                if fileViewportWidth >= 760 { visible.insert("modified") }
                if fileViewportWidth >= 1000 { visible.insert("kind") }
            }
        } else if !tab.columnsCustomized && (splitPresentation || view.bounds.width < 670) { visible.remove("kind") }
        for column in table.tableColumns { column.isHidden = !visible.contains(column.identifier.rawValue) }
        let canonicalOrder = Self.columnDefinitions.map(\.0)
        let savedOrder = tab.display.columnOrder.filter { canonicalOrder.contains($0) }
        let normalOrder = savedOrder + canonicalOrder.filter { !savedOrder.contains($0) }
        let displayedOrder = showsSearchLocations
            ? ["name", "location"] + normalOrder.filter { $0 != "name" }
            : normalOrder + ["location"]
        for (index, key) in displayedOrder.enumerated() where index < table.tableColumns.count {
            if let current = table.tableColumns.firstIndex(where: { $0.identifier.rawValue == key }), current != index { table.moveColumn(current, toColumn: index) }
        }
    }

    func tableViewColumnDidResize(_ notification: Notification) {
        guard !adjustingColumns else { return }
        if showsSearchLocations {
            searchLocationWidth = table.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier("location"))?.width
            return
        }
        tabs[selectedTab].display.columnWidths = Dictionary(uniqueKeysWithValues: table.tableColumns.filter { $0.identifier.rawValue != "location" }.map { ($0.identifier.rawValue, Double($0.width)) })
        onPresentationChange?()
    }

    func tableViewColumnDidMove(_ notification: Notification) {
        guard !adjustingColumns, !showsSearchLocations else { return }
        tabs[selectedTab].display.columnOrder = table.tableColumns.map { $0.identifier.rawValue }.filter { $0 != "location" }
        onPresentationChange?()
    }

    private func mediaMetadata(for entry: Entry) -> PaneMediaMetadata? {
        let key = "\(entry.url.path)|\(entry.size)|\(entry.modified?.timeIntervalSince1970 ?? 0)"
        if let metadata = mediaCache[key] { return metadata }
        let type = UTType(filenameExtension: entry.url.pathExtension)
        guard !entry.isFolder, type?.conforms(to: .image) == true || type?.conforms(to: .audiovisualContent) == true else { return .empty }
        guard pendingMedia.insert(key).inserted else { return nil }
        let url = entry.url
        Task.detached(priority: .utility) { [weak self] in
            let metadata = await PaneMediaMetadata.read(url: url, image: type?.conforms(to: .image) == true)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.pendingMedia.remove(key)
                if self.mediaCache.count > 512 { self.mediaCache.removeAll(keepingCapacity: true) }
                self.mediaCache[key] = metadata
                let rows = IndexSet(self.displayRows.indices.filter { self.entry(atRow: $0)?.url == url })
                let columns = IndexSet(self.table.tableColumns.indices.filter { ["dimensions", "duration"].contains(self.table.tableColumns[$0].identifier.rawValue) })
                if !rows.isEmpty { self.table.reloadData(forRowIndexes: rows, columnIndexes: columns) }
            }
        }
        return nil
    }

    private func icon(for entry: Entry, size: CGFloat) -> NSImage {
        guard isIndexedSearch else { return ShortcutSupport.icon(for: entry.url, size: size) }
        if entry.isFolder { return ShortcutSupport.folderIcon(size: NSSize(width: size, height: size)) }
        let key = "\(entry.url.path)|\(entry.size)|\(entry.modified?.timeIntervalSinceReferenceDate ?? 0)|\(size)"
        if let cached = searchIconCache.object(forKey: key as NSString) { return cached }
        if pendingSearchIcons.insert(key).inserted {
            enumerationQueue.async { [weak self] in
                let icon = ShortcutSupport.icon(for: entry.url, size: size)
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.pendingSearchIcons.remove(key)
                    self.searchIconCache.setObject(icon, forKey: key as NSString)
                    // An icon request can outlive a query. Its metadata-specific cache key
                    // remains valid, and a newer query may be waiting on this same request.
                    guard self.isIndexedSearch else { return }
                    if self.viewMode == "details" {
                        let rows = IndexSet(self.displayRows.indices.filter { self.entry(atRow: $0)?.url == entry.url })
                        if let column = self.table.tableColumns.firstIndex(where: { $0.identifier.rawValue == "name" }), !rows.isEmpty {
                            self.table.reloadData(forRowIndexes: rows, columnIndexes: IndexSet(integer: column))
                        }
                    } else {
                        let paths = Set(self.collection.indexPathsForVisibleItems().filter { self.entry(at: $0)?.url == entry.url })
                        if !paths.isEmpty { self.collection.reloadItems(at: paths) }
                    }
                }
            }
        }
        let image = NSWorkspace.shared.icon(for: UTType(filenameExtension: entry.url.pathExtension) ?? .data).copy() as! NSImage
        image.size = NSSize(width: size, height: size)
        return image
    }

    private func applyFilterAndSort() {
        if isIndexedSearch {
            startIndexedSearchIfNeeded()
            prepareIndexedResultsIfNeeded()
            return
        }
        let tab = tabs[selectedTab]
        let query = tab.query.trimmingCharacters(in: .whitespacesAndNewlines)
        let filterRoot = isShowingRecents ? URL(fileURLWithPath: "/", isDirectory: true) : currentURL
        visibleEntries = entries.filter {
            (query.isEmpty || $0.name.localizedStandardContains(query))
                && (!isSearching || FilenameSearchFilter.includes(url: $0.url, in: filterRoot, excludeGenerated: tab.excludeGenerated))
        }
        if isSearching && effectiveSortKey == "bestMatch" {
            let root = currentURL.path
            // Precompute relevance once per result, matching the indexed comparator.
            let ranked = visibleEntries.map { entry in
                (entry, FilenameSearchRanking.rank(name: entry.name, query: query) ?? 2,
                 FilenameSearchRanking.depth(path: entry.url.path, root: root))
            }
            visibleEntries = ranked.sorted {
                if $0.1 != $1.1 { return $0.1 < $1.1 }
                if $0.2 != $1.2 { return $0.2 < $1.2 }
                if $0.0.isFolder != $1.0.isFolder { return $0.0.isFolder }
                let order = $0.0.name.localizedStandardCompare($1.0.name)
                return order == .orderedSame ? $0.0.url.path < $1.0.url.path : order == .orderedAscending
            }.map(\.0)
        } else { Self.sortEntries(&visibleEntries, key: effectiveSortKey, ascending: currentSortAscending) }
        rebuildGroups()
        reloadPresentations(retaining: tab.selection)
        updateStatus()
        onSelectionChange?(selectedURLs)
    }

    private static func sortEntries(_ entries: inout [Entry], key: String, ascending: Bool) {
        entries.sort { lhs, rhs in
            if lhs.isFolder != rhs.isFolder { return lhs.isFolder }
            let ordering: ComparisonResult
            switch key {
            case "size": ordering = lhs.size == rhs.size ? .orderedSame : (lhs.size < rhs.size ? .orderedAscending : .orderedDescending)
            case "modified": ordering = (lhs.modified ?? .distantPast).compare(rhs.modified ?? .distantPast)
            case "created": ordering = (lhs.created ?? .distantPast).compare(rhs.created ?? .distantPast)
            case "kind": ordering = lhs.kind.localizedStandardCompare(rhs.kind)
            default: ordering = lhs.name.localizedStandardCompare(rhs.name)
            }
            if ordering == .orderedSame {
                let nameOrder = lhs.name.localizedStandardCompare(rhs.name)
                if nameOrder == .orderedSame { return lhs.url.path < rhs.url.path }
                return nameOrder == .orderedAscending
            }
            return ascending ? ordering == .orderedAscending : ordering == .orderedDescending
        }
    }

    private func reloadPresentations(retaining selection: Set<URL>) {
        restoringSelection = true
        defer { restoringSelection = false }
        table.reloadData()
        collection.reloadData()
        let indexes = IndexSet(displayRows.indices.filter { entry(atRow: $0).map { selection.contains($0.url) } ?? false })
        table.selectRowIndexes(indexes, byExtendingSelection: false)
        collection.selectionIndexPaths = Set(groups.enumerated().flatMap { section, group in group.entries.enumerated().compactMap { selection.contains($0.element.url) ? IndexPath(item: $0.offset, section: section) : nil } })
    }

    private func updateStatus() {
        defer { onStatusChange?(statusLabel.stringValue) }
        let selected = selectedURLs
        let indexed = isIndexedSearch
        let query = tabs[selectedTab].query.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasMore = indexed && indexedTotalMatchCount > visibleEntries.count
        searchPagingRow.isHidden = !isSearching
        let location = isShowingRecents ? "Recents" : (currentURL.path == "/" ? "/" : currentURL.lastPathComponent)
        let scopeDescription = isShowingRecents ? "Recent files" : (tabs[selectedTab].recursiveSearch ? "Subfolders included" : "This folder")
        searchPagingLabel.stringValue = "In \(location) · \(scopeDescription)"
            + (excludesGeneratedSearchResults ? " · Caches excluded" : "")
        searchPagingLabel.toolTip = (isShowingRecents ? "Search recently opened files.\n" : "Search location: \(currentURL.path)\n")
            + (excludesGeneratedSearchResults ? "Common cache, dependency, and build folders below this location are excluded." : "Caches and generated folders are included unless hidden-file filtering excludes them.")
        showMoreButton.isHidden = !hasMore
        showMoreButton.isEnabled = hasMore && !indexedPreparing
        if isShowingThisMac { statusLabel.stringValue = "This Mac"; messageLabel.isHidden = true; return }
        if loading && entries.isEmpty {
            let phase = indexedIsIndexing ? "Indexing folders…" : (indexedIsUpdating ? "Updating results…" : "Searching…")
            statusLabel.stringValue = indexed ? phase : "Loading…"
            messageLabel.stringValue = indexed ? phase : "Loading folder…"
            messageLabel.isHidden = false
            return
        }
        messageLabel.isHidden = !visibleEntries.isEmpty
        if let error = indexed ? indexedErrorMessage : loadError {
            messageLabel.stringValue = error
            statusLabel.stringValue = visibleEntries.isEmpty ? (indexed ? "Search unavailable" : "Folder unavailable") : "\(visibleEntries.count.formatted()) matches · \(error)"
            return
        }
        messageLabel.stringValue = isShowingRecents && entries.isEmpty ? "Recently opened files appear here." : (entries.isEmpty && query.isEmpty ? "This folder is empty." : "No filenames match your search.")
        let recursiveResults = indexed
        let unfinished = indexed && (!indexedQueryFinished || indexedIsIndexing || indexedIsUpdating || !indexedIsComplete)
        let recursiveCount = unfinished
            ? "\(indexedTotalMatchCount.formatted()) matches found so far" + (hasMore ? " · Showing \(visibleEntries.count.formatted())" : "")
            : (hasMore ? "Showing \(visibleEntries.count.formatted()) of \(indexedTotalMatchCount.formatted()) matches" : "\(visibleEntries.count.formatted()) matching item\(visibleEntries.count == 1 ? "" : "s")")
        let countText = query.isEmpty ? "\(entries.count) item\(entries.count == 1 ? "" : "s")" : (recursiveResults ? recursiveCount : "\(visibleEntries.count) of \(entries.count) items")
        var value = countText
        if !selected.isEmpty {
            value += " · \(selected.count) selected"
            let selectedEntries = visibleEntries.filter { selected.contains($0.url) }
            if !selectedEntries.contains(where: \.isFolder) {
                value += " · " + ByteCountFormatter.string(fromByteCount: selectedEntries.reduce(0) { $0 + $1.size }, countStyle: .file)
            }
        }
        if indexedIsIndexing && indexed { value += " · Indexing folders…" }
        else if indexedIsUpdating && indexed { value += " · Updating results…" }
        else if loading { value += " · Searching…" }
        if searchWarningCount > 0 { value += " · Some folders unavailable" }
        statusLabel.stringValue = value
    }

    private func installDirectoryWatcher() {
        directoryWatcher?.cancel()
        directoryWatcher = nil
        refreshWork?.cancel()
        guard !isVirtualLocation else { return }
        let fd = open(currentURL.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .delete, .rename, .attrib], queue: .main)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            // The shared catalog has its own recursive change stream. Reopening this
            // subscription on every root write would discard progressive results.
            guard !self.isIndexedSearch else { return }
            self.refreshWork?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.reload() }
            self.refreshWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
        }
        source.setCancelHandler { close(fd) }
        directoryWatcher = source
        source.resume()
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { displayRows.count }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool { entry(atRow: row) == nil }
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { entry(atRow: row) != nil }
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { entry(atRow: row) == nil ? (compactSpacing ? 30 : 36) : (compactSpacing ? 28 : 40) }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { entry(atRow: row) == nil ? NSTableRowView() : PaneSelectionRow() }

    func tableView(_ tableView: NSTableView, didRemove rowView: NSTableRowView, forRow row: Int) {
        (rowView as? PaneSelectionRow)?.resetHover()
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard displayRows.indices.contains(row) else { return nil }
        if case .header(let title) = displayRows[row] {
            let identifier = NSUserInterfaceItemIdentifier("groupRow")
            let header = (tableView.makeView(withIdentifier: identifier, owner: self) as? PaneGroupHeaderView) ?? PaneGroupHeaderView()
            header.identifier = identifier; header.title = title
            return header
        }
        guard let entry = entry(atRow: row), let column = tableColumn else { return nil }
        let key = column.identifier.rawValue
        if key == "name" {
            let identifier = NSUserInterfaceItemIdentifier("fileNameCell")
            let cell = (tableView.makeView(withIdentifier: identifier, owner: self) as? PaneNameCell) ?? PaneNameCell()
            cell.identifier = identifier
            cell.label.stringValue = displayName(entry)
            cell.label.font = .systemFont(ofSize: compactSpacing ? 15 : 18)
            cell.label.toolTip = entry.url.path
            cell.icon.image = icon(for: entry, size: 24)
            cell.alphaValue = cutURLs.contains(entry.url) ? 0.45 : 1
            cell.setAccessibilityLabel(displayName(entry) + (entry.isShortcut ? ", shortcut" : "")
                + (showsSearchLocations ? ", in \(resultLocation(entry))" : ""))
            return cell
        }
        let identifier = NSUserInterfaceItemIdentifier("text-\(key)")
        let cell = (tableView.makeView(withIdentifier: identifier, owner: self) as? PaneTextCell) ?? PaneTextCell()
        cell.identifier = identifier
        let field = cell.label
        field.font = .systemFont(ofSize: compactSpacing ? 15 : 18)
        field.lineBreakMode = .byTruncatingTail
        field.textColor = .black
        field.clipsToBounds = true
        field.alignment = key == "size" ? .right : .left
        cell.alphaValue = cutURLs.contains(entry.url) ? 0.45 : 1
        switch key {
        case "location":
            field.stringValue = resultLocation(entry)
            field.textColor = .secondaryLabelColor
            field.lineBreakMode = .byTruncatingMiddle
        case "modified": field.stringValue = entry.modified.map(dateFormatter.string) ?? "—"
        case "created": field.stringValue = entry.created.map(dateFormatter.string) ?? "—"
        case "dimensions": field.stringValue = mediaMetadata(for: entry)?.dimensions ?? "…"
        case "duration": field.stringValue = mediaMetadata(for: entry)?.duration ?? "…"
        case "kind": field.stringValue = entry.kind
        case "size": field.stringValue = entry.isFolder ? "—" : ByteCountFormatter.string(fromByteCount: entry.size, countStyle: .file)
        default: field.stringValue = ""
        }
        field.toolTip = key == "location" ? entry.url.deletingLastPathComponent().path : field.stringValue
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !restoringSelection else { return }
        tabs[selectedTab].selection = Set(selectedURLs)
        updateStatus()
        onSelectionChange?(selectedURLs)
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard !updatingSortIndicator, let descriptor = tableView.sortDescriptors.first else { return }
        if isSearching {
            tabs[selectedTab].searchSortKey = descriptor.key ?? "name"
            tabs[selectedTab].searchAscending = descriptor.ascending
        } else {
            tabs[selectedTab].sortKey = descriptor.key ?? "name"
            tabs[selectedTab].ascending = descriptor.ascending
        }
        applyFilterAndSort()
        onPresentationChange?()
    }

    func tableView(_ tableView: NSTableView, didClick tableColumn: NSTableColumn) { activate() }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        entry(atRow: row)?.url as NSURL?
    }

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int,
                   proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        guard !isVirtualLocation, loadError == nil else { return [] }
        guard info.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) else { return [] }
        if let target = entry(atRow: row), dropOperation == .on, target.isFolder {
            tableView.setDropRow(row, dropOperation: .on)
        } else {
            tableView.setDropRow(-1, dropOperation: .on)
        }
        // Default to copy. Moving requires an explicit Shift gesture and is advertised by the drag cursor.
        return NSEvent.modifierFlags.contains(.shift) && !NSEvent.modifierFlags.contains(.option) ? .move : .copy
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int,
                   dropOperation: NSTableView.DropOperation) -> Bool {
        guard !isVirtualLocation, loadError == nil else { return false }
        guard let values = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !values.isEmpty else { return false }
        let target = entry(atRow: row)
        let destination = dropOperation == .on && target?.isFolder == true ? target!.url : currentURL
        activate()
        let move = NSEvent.modifierFlags.contains(.shift) && !NSEvent.modifierFlags.contains(.option)
        onDrop?(values, destination, move)
        return onDrop != nil
    }

    // MARK: Icon view

    func numberOfSections(in collectionView: NSCollectionView) -> Int { groups.count }

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int { groups.indices.contains(section) ? groups[section].entries.count : 0 }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: NSUserInterfaceItemIdentifier("fileIcon"), for: indexPath)
        guard let item = item as? PaneIconItem, let entry = entry(at: indexPath) else { return item }
        item.configure(mode: viewMode, compact: compactSpacing, name: displayName(entry), detail: entry.isFolder ? "Folder" : "\(entry.kind) · \(ByteCountFormatter.string(fromByteCount: entry.size, countStyle: .file))",
                       location: showsSearchLocations ? resultLocation(entry) : nil)
        let iconSize: CGFloat = ["list": 22, "smallIcons": 18, "mediumIcons": 58, "largeIcons": 102, "tiles": 48][viewMode] ?? 58
        item.iconView.image = icon(for: entry, size: iconSize)
        item.view.toolTip = entry.url.path
        item.view.alphaValue = cutURLs.contains(entry.url) ? 0.45 : 1
        item.view.setAccessibilityLabel(displayName(entry) + (entry.isShortcut ? ", shortcut" : "")
            + (showsSearchLocations ? ", in \(resultLocation(entry))" : ""))
        return item
    }

    func collectionView(_ collectionView: NSCollectionView, viewForSupplementaryElementOfKind kind: NSCollectionView.SupplementaryElementKind, at indexPath: IndexPath) -> NSView {
        let header = collectionView.makeSupplementaryView(ofKind: kind, withIdentifier: NSUserInterfaceItemIdentifier("groupHeader"), for: indexPath)
        if let header = header as? PaneGroupHeaderView, groups.indices.contains(indexPath.section) {
            let group = groups[indexPath.section]; header.title = "\(group.title) (\(group.totalCount ?? group.entries.count))"
        }
        return header
    }

    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) { collectionSelectionChanged() }
    func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) { collectionSelectionChanged() }

    private func collectionSelectionChanged() {
        guard !restoringSelection, viewMode != "details" else { return }
        tabs[selectedTab].selection = Set(selectedURLs)
        updateStatus()
        onSelectionChange?(selectedURLs)
    }

    func collectionView(_ collectionView: NSCollectionView, pasteboardWriterForItemAt indexPath: IndexPath) -> NSPasteboardWriting? {
        entry(at: indexPath)?.url as NSURL?
    }

    func collectionView(_ collectionView: NSCollectionView, validateDrop draggingInfo: NSDraggingInfo,
                        proposedIndexPath proposedDropIndexPath: AutoreleasingUnsafeMutablePointer<NSIndexPath>,
                        dropOperation proposedDropOperation: UnsafeMutablePointer<NSCollectionView.DropOperation>) -> NSDragOperation {
        guard !isVirtualLocation, loadError == nil else { return [] }
        guard draggingInfo.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) else { return [] }
        let target = entry(at: proposedDropIndexPath.pointee as IndexPath)
        if !(proposedDropOperation.pointee == .on && target?.isFolder == true) {
            proposedDropOperation.pointee = .before
        }
        return NSEvent.modifierFlags.contains(.shift) && !NSEvent.modifierFlags.contains(.option) ? .move : .copy
    }

    func collectionView(_ collectionView: NSCollectionView, acceptDrop draggingInfo: NSDraggingInfo,
                        indexPath: IndexPath, dropOperation: NSCollectionView.DropOperation) -> Bool {
        guard !isVirtualLocation, loadError == nil else { return false }
        guard let urls = draggingInfo.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty else { return false }
        let target = entry(at: indexPath)
        let destination = dropOperation == .on && target?.isFolder == true ? target!.url : currentURL
        activate()
        let move = NSEvent.modifierFlags.contains(.shift) && !NSEvent.modifierFlags.contains(.option)
        onDrop?(urls, destination, move)
        return onDrop != nil
    }

    // MARK: Actions and keyboard

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        addContextItem("Open", action: #selector(contextOpen), enabled: !selectedURLs.isEmpty)
        addContextItem("Open in New Window", action: #selector(contextOpenInNewWindow), enabled: canOpenSelectionInNewWindow)
        addContextItem("Open With…", action: #selector(contextOpenWith), enabled: selectedURLs.count == 1)
        addContextItem("Quick Look", action: #selector(contextPreview), enabled: !selectedURLs.isEmpty)
        menu.addItem(.separator())
        addContextItem("Cut", action: #selector(contextCut), enabled: !selectedURLs.isEmpty)
        addContextItem("Copy", action: #selector(contextCopy), enabled: !selectedURLs.isEmpty)
        addContextItem("Paste", action: #selector(contextPaste), enabled: !isVirtualLocation && loadError == nil && NSPasteboard.general.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]))
        addContextItem("Paste shortcut", action: #selector(contextPasteShortcut), enabled: canReceiveFiles && (canPasteShortcut?() ?? false))
        addContextItem("Rename…", action: #selector(contextRename), enabled: selectedURLs.count == 1)
        addContextItem("Copy Path", action: #selector(contextCopyPath), enabled: !selectedURLs.isEmpty)
        let sendTo = NSMenuItem(title: "Send to", action: nil, keyEquivalent: "")
        let destinations = NSMenu(); destinations.autoenablesItems = false
        for (title, action, folder) in [("Desktop (create shortcut)", #selector(contextSendAlias), Optional<FileManager.SearchPathDirectory>.none), ("Documents", #selector(contextSendFolder(_:)), .documentDirectory), ("Downloads", #selector(contextSendFolder(_:)), .downloadsDirectory), ("Choose folder…", #selector(contextSendChoose), nil)] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self; item.isEnabled = !selectedURLs.isEmpty
            if let folder { item.representedObject = FileManager.default.urls(for: folder, in: .userDomainMask).first }
            destinations.addItem(item)
        }
        sendTo.submenu = destinations; sendTo.isEnabled = !selectedURLs.isEmpty
        menu.addItem(sendTo)
        menu.addItem(.separator())
        addContextItem("New Folder…", action: #selector(contextNewFolder), enabled: loadError == nil && !isVirtualLocation)
        addContextItem("New File…", action: #selector(contextNewFile), enabled: loadError == nil && !isVirtualLocation)
        menu.addItem(.separator())
        addContextItem("Move to Trash", action: #selector(contextTrash), enabled: !selectedURLs.isEmpty)
        menu.addItem(.separator())
        addContextItem("Properties…", action: #selector(contextProperties), enabled: canShowProperties)
    }

    private func addContextItem(_ title: String, action: Selector, enabled: Bool) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.isEnabled = enabled
        contextMenu.autoenablesItems = false
        contextMenu.addItem(item)
    }

    private func request(_ action: BrowserAction) {
        if isVirtualLocation {
            switch action { case .newFolder, .newFile, .paste, .pasteShortcut: return; default: break }
        }
        activate(); onRequestAction?(action)
    }
    @objc private func contextSendAlias() { if !selectedURLs.isEmpty { request(.sendToDesktopAlias) } }
    @objc private func contextSendChoose() { if !selectedURLs.isEmpty { request(.sendToChooseFolder) } }
    @objc private func contextSendFolder(_ item: NSMenuItem) {
        guard !selectedURLs.isEmpty, let destination = item.representedObject as? URL else { return }
        activate(); onSendToFolder?(selectedURLs, destination)
    }
    @objc private func contextOpen() { openSelection() }
    @objc private func contextOpenInNewWindow() {
        guard canOpenSelectionInNewWindow else { return }
        for url in selectedURLs { openURL(url, folderInNewWindow: true) }
    }
    @objc private func contextOpenWith() { request(.openWith) }
    @objc private func contextPreview() { request(.preview) }
    @objc private func contextCut() { request(.cut) }
    @objc private func contextCopy() { request(.copy) }
    @objc private func contextPaste() { request(.paste) }
    @objc private func contextPasteShortcut() {
        guard canReceiveFiles, canPasteShortcut?() == true else { return }
        request(.pasteShortcut)
    }
    @objc private func contextRename() { request(.rename) }
    @objc private func contextCopyPath() { request(.copyPath) }
    @objc private func contextNewFolder() { request(.newFolder) }
    @objc private func contextNewFile() { request(.newFile) }
    @objc private func contextTrash() { request(.trash) }
    private var canShowProperties: Bool {
        if !selectedURLs.isEmpty { return true }
        guard !isVirtualLocation, loadError == nil else { return false }
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: currentURL.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
    @objc private func contextProperties() {
        guard canShowProperties else { return }
        request(.properties)
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let shortcut = flags.contains(.command) || flags.contains(.control)
        let key = shortcutKey(for: event)
        if shortcut {
            switch key {
            case "x": request(.cut)
            case "c": request(.copy)
            case "v": request(.paste)
            case "a":
                selectAllFiles()
            case "t": addTab()
            case "w": closeCurrentTab()
            case "l": focusAddress()
            case "f": focusSearch()
            case "r": refreshSearchIndex()
            case "i": contextProperties()
            case "n" where flags.contains(.shift): request(.newFolder)
            case "." where flags.contains(.shift): setHiddenFiles(!showHidden)
            default:
                if event.keyCode == 51 { request(.trash) } else { return false }
            }
            return true
        }
        if flags.contains(.option) {
            switch event.keyCode {
            case 123: goBack()
            case 124: goForward()
            case 126: goUp()
            case 36, 76: contextProperties()
            default: return false
            }
            return true
        }
        switch event.keyCode {
        case 36, 76: openSelection(); return true
        case 120: request(.rename); return true // F2
        case 49: request(.preview); return true
        case 51: goBack(); return true
        case 117: request(.trash); return true // Forward Delete
        default: return false
        }
    }
}

final class PaneFileTableView: NSTableView {
    var activate: (() -> Void)?
    var keyHandler: ((NSEvent) -> Bool)?
    var actionRequested: ((BrowserAction) -> Void)?
    var selectAllRequested: (() -> Void)?
    private var selectionAnchor: Int?
    private var preservingSelectionAnchor = false
    lazy var selectionMarquee = PaneSelectionMarquee(owner: self,
        selection: { [weak self] in Set(self?.selectedRowIndexes.map { IndexPath(item: $0, section: 0) } ?? []) },
        applySelection: { [weak self] paths in
            guard let self else { return }
            let rows = IndexSet(paths.map(\.item).filter { $0 < self.numberOfRows && self.delegate?.tableView?(self, shouldSelectRow: $0) != false })
            if rows != self.selectedRowIndexes { self.selectRowIndexes(rows, byExtendingSelection: false) }
        }, itemsIntersecting: { [weak self] rect in
            guard let self else { return [] }
            let range = self.rows(in: rect)
            guard range.location != NSNotFound, range.length > 0 else { return [] }
            return Set((range.location..<NSMaxRange(range)).filter {
                self.delegate?.tableView?(self, shouldSelectRow: $0) != false && self.rect(ofRow: $0).intersects(rect)
            }.map { IndexPath(item: $0, section: 0) })
        })
    override func selectAll(_ sender: Any?) { selectAllRequested?() }

    override func selectRowIndexes(_ indexes: IndexSet, byExtendingSelection extend: Bool) {
        super.selectRowIndexes(indexes, byExtendingSelection: extend)
        if !preservingSelectionAnchor && !selectionMarquee.isActive {
            selectionAnchor = selectedRow >= 0 ? selectedRow : nil
        }
    }

    override func mouseDown(with event: NSEvent) {
        activate?()
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        let row = row(at: point)
        let selectable = row >= 0 && delegate?.tableView?(self, shouldSelectRow: row) != false
        let previousAnchor = selectionAnchor
        let anchor = selectionAnchor ?? (selectedRow >= 0 ? selectedRow : row)
        if !event.modifierFlags.contains(.shift), !event.modifierFlags.contains(.control) {
            selectionAnchor = selectable ? row : nil
        }
        let wasPreservingAnchor = preservingSelectionAnchor
        preservingSelectionAnchor = true
        defer { preservingSelectionAnchor = wasPreservingAnchor }
        if event.clickCount < 2, !event.modifierFlags.contains(.control), canStartMarquee(at: point) {
            var clickSelection: Set<IndexPath>?
            if selectable {
                var rows = IndexSet(integer: row)
                if event.modifierFlags.contains(.shift), anchor >= 0, anchor < numberOfRows {
                    rows = IndexSet(integersIn: min(anchor, row)...max(anchor, row))
                    if event.modifierFlags.contains(.command) { rows.formUnion(selectedRowIndexes) }
                } else if event.modifierFlags.contains(.command) {
                    rows = selectedRowIndexes.symmetricDifference(rows)
                }
                clickSelection = Set(rows.filter { delegate?.tableView?(self, shouldSelectRow: $0) != false }
                    .map { IndexPath(item: $0, section: 0) })
            }
            // Whitespace is still part of its row when clicked. Only a real drag
            // changes it into a rectangle, using the selection from before the click.
            selectionMarquee.begin(with: event, clickSelection: clickSelection) { [weak self] cancelled in
                if cancelled { self?.selectionAnchor = previousAnchor }
            }
            return
        }
        super.mouseDown(with: event)
    }
    func canStartMarquee(at point: NSPoint) -> Bool {
        let row = row(at: point)
        if row < 0 || delegate?.tableView?(self, shouldSelectRow: row) == false { return true }
        if selectedRowIndexes.contains(row) { return false }
        let column = column(at: point)
        guard tableColumns.indices.contains(column), tableColumns[column].identifier.rawValue == "name",
              let cell = view(atColumn: column, row: row, makeIfNecessary: true) as? PaneNameCell else { return false }
        let labelRect = cell.label.convert(cell.label.bounds, to: self)
        let textWidth = min(labelRect.width, cell.label.attributedStringValue.size().width)
        return point.x > labelRect.minX + textWidth + 8
    }
    override func mouseDragged(with event: NSEvent) {
        if selectionMarquee.isActive { selectionMarquee.update(with: event) } else { super.mouseDragged(with: event) }
    }
    override func mouseUp(with event: NSEvent) {
        if selectionMarquee.isActive { selectionMarquee.update(with: event); selectionMarquee.finish() } else { super.mouseUp(with: event) }
    }
    override func reloadData() { selectionMarquee.finish(); selectionAnchor = nil; super.reloadData() }
    override func viewWillMove(toSuperview newSuperview: NSView?) {
        if newSuperview == nil { selectionMarquee.finish() }
        super.viewWillMove(toSuperview: newSuperview)
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        activate?()
        window?.makeFirstResponder(self)
        let clicked = row(at: convert(event.locationInWindow, from: nil))
        if clicked < 0 || delegate?.tableView?(self, shouldSelectRow: clicked) == false {
            deselectAll(nil)
        } else if !selectedRowIndexes.contains(clicked) {
            selectRowIndexes(IndexSet(integer: clicked), byExtendingSelection: false)
        }
        return super.menu(for: event)
    }
    override func becomeFirstResponder() -> Bool { activate?(); return super.becomeFirstResponder() }
    override func keyDown(with event: NSEvent) {
        if selectionMarquee.isActive {
            selectionMarquee.finish(cancelled: event.keyCode == 53)
            if event.keyCode == 53 { return }
        }
        if keyHandler?(event) == true { return }
        let wasPreservingAnchor = preservingSelectionAnchor
        preservingSelectionAnchor = event.modifierFlags.contains(.shift)
        defer { preservingSelectionAnchor = wasPreservingAnchor }
        super.keyDown(with: event)
        if !event.modifierFlags.contains(.shift) { selectionAnchor = selectedRow >= 0 ? selectedRow : nil }
    }
    @objc func cut(_ sender: Any?) { activate?(); actionRequested?(.cut) }
    @objc func copy(_ sender: Any?) { activate?(); actionRequested?(.copy) }
    @objc func paste(_ sender: Any?) { activate?(); actionRequested?(.paste) }
}

/// One gesture shared by Details and icon/list layouts. It keeps the anchor in
/// document coordinates, so scrolling extends the rectangle instead of moving it.
final class PaneSelectionMarquee {
    private weak var owner: NSView?
    private weak var gestureWindow: NSWindow?
    private let selection: () -> Set<IndexPath>
    private let applySelection: (Set<IndexPath>) -> Void
    private let itemsIntersecting: (NSRect) -> Set<IndexPath>
    private var original: Set<IndexPath> = []
    private var modifiers: NSEvent.ModifierFlags = []
    private var anchor = NSPoint.zero
    private var downPoint = NSPoint.zero
    private var lastPoint = NSPoint.zero
    private var monitor: Any?
    private var observers: [NSObjectProtocol] = []
    private var timer: Timer?
    private var didFinish: ((Bool) -> Void)?
    private let overlay = PaneSelectionRectangleView()
    private(set) var isActive = false
    private(set) var rectangle: NSRect?

    init(owner: NSView, selection: @escaping () -> Set<IndexPath>,
         applySelection: @escaping (Set<IndexPath>) -> Void,
         itemsIntersecting: @escaping (NSRect) -> Set<IndexPath>) {
        self.owner = owner; self.selection = selection
        self.applySelection = applySelection; self.itemsIntersecting = itemsIntersecting
    }
    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
        timer?.invalidate()
        observers.forEach(NotificationCenter.default.removeObserver)
        overlay.removeFromSuperview()
        if let window = gestureWindow { PointerHoverCoordinator.shared.selectionDrag(in: window, active: false, at: lastPoint) }
    }
    func begin(with event: NSEvent, clickSelection: Set<IndexPath>? = nil, didFinish: ((Bool) -> Void)? = nil) {
        finish()
        guard let owner, let window = owner.window, owner.enclosingScrollView != nil else { return }
        gestureWindow = window; isActive = true
        original = selection(); modifiers = event.modifierFlags
        self.didFinish = didFinish
        downPoint = event.locationInWindow; lastPoint = downPoint
        anchor = owner.convert(downPoint, from: nil)
        PointerHoverCoordinator.shared.selectionDrag(in: window, active: true, at: downPoint)
        if let clickSelection { applySelection(clickSelection) }
        else if modifiers.intersection([.command, .shift]).isEmpty { applySelection([]) }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDragged, .leftMouseUp, .keyDown, .leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, self.isActive else { return event }
            switch event.type {
            case .leftMouseDragged:
                self.update(with: event); return nil
            case .leftMouseUp:
                self.update(with: event); self.finish(); return nil
            case .keyDown:
                self.finish(cancelled: event.keyCode == 53)
                return event.keyCode == 53 ? nil : event
            default: self.finish(); return event
            }
        }
        for name in [NSWindow.didResignKeyNotification, NSWindow.willCloseNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in self?.finish(cancelled: true) })
        }
        if let clip = owner.enclosingScrollView?.contentView {
            clip.postsBoundsChangedNotifications = true
            observers.append(NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) { [weak self] _ in self?.refresh() })
        }
        let timer = Timer(timeInterval: 1 / 30, repeats: true) { [weak self] _ in self?.autoscrollTick() }
        self.timer = timer; RunLoop.main.add(timer, forMode: .common)
    }
    func update(with event: NSEvent) {
        guard isActive, let window = gestureWindow else { return }
        if let eventWindow = event.window, eventWindow !== window { finish(cancelled: true); return }
        lastPoint = event.locationInWindow
        refresh()
    }
    private func refresh() {
        guard isActive, let owner, let window = gestureWindow,
              owner.window === window, !owner.isHiddenOrHasHiddenAncestor,
              let scroll = owner.enclosingScrollView else { finish(); return }
        guard rectangle != nil || hypot(lastPoint.x - downPoint.x, lastPoint.y - downPoint.y) >= 3 else { return }
        let point = owner.convert(lastPoint, from: nil)
        let rect = NSRect(x: min(anchor.x, point.x), y: min(anchor.y, point.y),
                          width: max(1, abs(anchor.x - point.x)), height: max(1, abs(anchor.y - point.y)))
        rectangle = rect
        overlay.frame = scroll.convert(scroll.contentView.bounds, from: scroll.contentView)
        if overlay.superview !== scroll { scroll.addSubview(overlay, positioned: .above, relativeTo: scroll.contentView) }
        overlay.selectionRect = overlay.convert(rect, from: owner)
        let hits = itemsIntersecting(rect)
        let next: Set<IndexPath>
        if modifiers.contains(.command) { next = original.symmetricDifference(hits) }
        else if modifiers.contains(.shift) { next = original.union(hits) }
        else { next = hits }
        if next != selection() { applySelection(next) }
    }
    func autoscrollTick() {
        guard isActive, rectangle != nil, let owner, let scroll = owner.enclosingScrollView else { return }
        let clip = scroll.contentView
        let point = clip.convert(lastPoint, from: nil)
        let bounds = clip.bounds
        func speed(_ value: CGFloat, _ lower: CGFloat, _ upper: CGFloat) -> CGFloat {
            if value < lower + 18 { return -min(22, max(3, (lower + 18 - value) / 2)) }
            if value > upper - 18 { return min(22, max(3, (value - upper + 18) / 2)) }
            return 0
        }
        var proposed = bounds
        proposed.origin.x += speed(point.x, bounds.minX, bounds.maxX)
        proposed.origin.y += speed(point.y, bounds.minY, bounds.maxY)
        proposed = clip.constrainBoundsRect(proposed)
        if proposed.origin != bounds.origin {
            clip.scroll(to: proposed.origin); scroll.reflectScrolledClipView(clip)
            refresh()
        }
    }
    func finish(cancelled: Bool = false) {
        guard isActive else { return }
        isActive = false; rectangle = nil
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        timer?.invalidate(); timer = nil
        observers.forEach(NotificationCenter.default.removeObserver); observers.removeAll()
        overlay.removeFromSuperview()
        if let window = gestureWindow { PointerHoverCoordinator.shared.selectionDrag(in: window, active: false, at: lastPoint) }
        gestureWindow = nil
        if cancelled { applySelection(original) }
        original.removeAll()
        let completion = didFinish; didFinish = nil
        completion?(cancelled)
    }
}

private final class PaneSelectionRectangleView: NSView {
    var selectionRect = NSRect.zero { didSet { needsDisplay = true } }
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = NSUserInterfaceItemIdentifier("browser.selectionRectangle")
        wantsLayer = true; clipsToBounds = true
        layer?.zPosition = 100
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError("Programmatic selection rectangle") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        let rect = NSRect(origin: selectionRect.origin, size: NSSize(width: max(1, selectionRect.width), height: max(1, selectionRect.height)))
        NSColor.systemBlue.withAlphaComponent(0.14).setFill()
        rect.fill()
        NSColor.systemBlue.withAlphaComponent(0.9).setStroke()
        let outline = NSBezierPath(rect: rect.insetBy(dx: 0.5, dy: 0.5))
        outline.lineWidth = 1; outline.stroke()
    }
}

/// Short directories can leave blank clip-view space below the document view.
/// Forward only that background to the file view, never header/scroller clicks.
private final class PaneFileClipView: NSClipView {
    override func menu(for event: NSEvent) -> NSMenu? {
        if let table = documentView as? PaneFileTableView { return table.menu(for: event) }
        if let collection = documentView as? PaneIconCollectionView { return collection.menu(for: event) }
        return super.menu(for: event)
    }
    override func mouseDown(with event: NSEvent) {
        if let table = documentView as? PaneFileTableView { table.mouseDown(with: event) }
        else if let collection = documentView as? PaneIconCollectionView { collection.mouseDown(with: event) }
        else { super.mouseDown(with: event) }
    }
}

private final class PaneNameCell: NSTableCellView {
    let icon = NSImageView()
    let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        clipsToBounds = true
        icon.imageScaling = .scaleProportionallyDown
        label.font = .systemFont(ofSize: 18)
        label.textColor = .black
        label.lineBreakMode = .byTruncatingTail
        label.clipsToBounds = true
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for child in [icon, label] { child.translatesAutoresizingMaskIntoConstraints = false; addSubview(child) }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 24),
            icon.heightAnchor.constraint(equalToConstant: 24),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 12),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -3),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        textField = label
        imageView = icon
    }

    required init?(coder: NSCoder) { fatalError("Programmatic cell") }
}

private final class PaneTextCell: NSTableCellView {
    let label = NSTextField(labelWithString: "")
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        clipsToBounds = true
        label.font = .systemFont(ofSize: 18)
        label.textColor = .black
        label.lineBreakMode = .byTruncatingTail
        label.clipsToBounds = true
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        textField = label
    }
    required init?(coder: NSCoder) { fatalError("Programmatic cell") }
}

private final class PaneFileScrollView: NSScrollView {
    var onViewportWidthChange: (() -> Void)?
    private var lastViewportWidth: CGFloat = -1
    private var fitting = false
    override func tile() {
        super.tile()
        let width = contentView.bounds.width
        guard abs(lastViewportWidth - width) > 0.5 else { return }
        lastViewportWidth = width
        guard !fitting else { return }
        fitting = true
        defer { fitting = false }
        onViewportWidthChange?()
    }
}

private final class PaneSurfaceView: NSView {
    var fillColor = NSColor.windowBackgroundColor
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        clipsToBounds = true
    }
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        clipsToBounds = true
    }
    override var isOpaque: Bool { true }
    override func draw(_ dirtyRect: NSRect) { fillColor.setFill(); bounds.fill() }
}

private final class PaneBorderedView: NSView {
    var onPress: (() -> Void)?
    var focusHighlighted = false {
        didSet {
            layer?.borderColor = (focusHighlighted
                ? NSColor(calibratedRed: 0.18, green: 0.45, blue: 0.84, alpha: 1)
                : NSColor(calibratedWhite: 0.78, alpha: 1)).cgColor
        }
    }
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        clipsToBounds = true
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.borderWidth = 1
        layer?.borderColor = NSColor(calibratedWhite: 0.78, alpha: 1).cgColor
        layer?.backgroundColor = NSColor.white.cgColor
    }
    required init?(coder: NSCoder) { fatalError("Programmatic view") }
    override func mouseDown(with event: NSEvent) {
        if let onPress { onPress() } else { super.mouseDown(with: event) }
    }
}

private final class PaneSelectionRow: NSTableRowView {
    private lazy var hoverState = PointerHoverState(view: self) { [weak self] _ in self?.needsDisplay = true }
    private var hovered: Bool { hoverState.isHovered }
    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }
    override var isSelected: Bool { didSet { needsDisplay = true } }
    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect.intersection(bounds))
        if hovered && !isSelected {
            NSColor(calibratedWhite: 0.95, alpha: 1).setFill()
            bounds.fill()
        }
    }
    override func drawSelection(in dirtyRect: NSRect) {
        NSColor(calibratedRed: 0.79, green: 0.88, blue: 1, alpha: 1).setFill()
        bounds.fill()
    }
    override init(frame frameRect: NSRect) { super.init(frame: frameRect); clipsToBounds = true }
    required init?(coder: NSCoder) { fatalError("Programmatic row") }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        hoverState.updateTrackingAreas()
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { resetHover() }
    }
    func resetHover() { hoverState.reset() }
}

private final class PaneTableHeaderView: NSTableHeaderView {
    var columnMenu: (() -> NSMenu)?
    override func menu(for event: NSEvent) -> NSMenu? { columnMenu?() ?? super.menu(for: event) }
    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedWhite: 0.995, alpha: 1).setFill()
        bounds.fill()
        super.draw(dirtyRect.intersection(bounds))
    }
    override init(frame frameRect: NSRect) { super.init(frame: frameRect); clipsToBounds = true }
    required init?(coder: NSCoder) { fatalError("Programmatic header") }
}

private final class PaneTableHeaderCell: NSTableHeaderCell {
    override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {
        NSColor(calibratedWhite: 0.995, alpha: 1).setFill()
        cellFrame.fill()
        let style = NSMutableParagraphStyle()
        style.alignment = alignment
        var title = stringValue
        if let header = controlView as? NSTableHeaderView, let table = header.tableView,
           let descriptor = table.sortDescriptors.first {
            let index = table.column(at: NSPoint(x: cellFrame.midX, y: 0))
            if table.tableColumns.indices.contains(index), table.tableColumns[index].identifier.rawValue == descriptor.key {
                title += descriptor.ascending ? " ↑" : " ↓"
            }
        }
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 17), .foregroundColor: NSColor.black, .paragraphStyle: style]
        let textRect = NSRect(x: cellFrame.minX + 6, y: cellFrame.midY - 11, width: cellFrame.width - 12, height: 24)
        (title as NSString).draw(in: textRect, withAttributes: attributes)
        NSColor(calibratedWhite: 0.87, alpha: 1).setFill()
        NSRect(x: cellFrame.minX, y: cellFrame.maxY - 1, width: cellFrame.width, height: 1).fill()
    }
    override func drawSortIndicator(withFrame cellFrame: NSRect, in controlView: NSView, ascending: Bool, priority: Int) {}
}

private func paneFolderImage() -> NSImage {
    ShortcutSupport.folderIcon()
}

private final class PaneClosureButton: NSButton {
    var onPress: (() -> Void)?
    private lazy var hoverState = PointerHoverState(view: self) { [weak self] _ in self?.needsDisplay = true }
    private var hovered: Bool { hoverState.isHovered }
    override var acceptsFirstResponder: Bool { isEnabled }
    override var isEnabled: Bool { didSet { if oldValue != isEnabled { hoverState.reset() }; updateInk(); needsDisplay = true } }
    override var isHighlighted: Bool { didSet { needsDisplay = true } }
    init(title: String = "", image: NSImage? = nil, onPress: (() -> Void)? = nil) {
        super.init(frame: .zero)
        self.title = title
        self.image = image
        self.onPress = onPress
        isBordered = false
        bezelStyle = .inline
        target = self
        action = #selector(pressed)
        font = .systemFont(ofSize: 17)
        focusRingType = .none
        refusesFirstResponder = false
        clipsToBounds = true
        updateInk()
    }
    required init?(coder: NSCoder) { fatalError("Programmatic button") }
    @objc private func pressed() { onPress?() }
    private func updateInk() {
        let color = isEnabled ? NSColor.black : NSColor.disabledControlTextColor
        contentTintColor = color
        attributedTitle = NSAttributedString(string: title, attributes: [.font: NSFont.systemFont(ofSize: 17), .foregroundColor: color])
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        hoverState.updateTrackingAreas()
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { hoverState.reset() }
    }
    override func becomeFirstResponder() -> Bool { let result = super.becomeFirstResponder(); needsDisplay = true; return result }
    override func resignFirstResponder() -> Bool { let result = super.resignFirstResponder(); needsDisplay = true; return result }
    override func draw(_ dirtyRect: NSRect) {
        if isEnabled && (hovered || isHighlighted) {
            NSColor(calibratedWhite: isHighlighted ? 0.82 : 0.91, alpha: 0.9).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 5, yRadius: 5).fill()
        }
        super.draw(dirtyRect)
        if isEnabled && window?.firstResponder === self {
            NSColor.keyboardFocusIndicatorColor.setStroke()
            let focus = NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 5, yRadius: 5)
            focus.lineWidth = 2
            focus.stroke()
        }
    }
}

private final class PaneTabView: NSView {
    var onSelect: (() -> Void)?
    var onClose: (() -> Void)?
    private let current: Bool
    private lazy var hoverState = PointerHoverState(view: self) { [weak self] _ in self?.needsDisplay = true }
    private var hovered: Bool { hoverState.isHovered }
    override var isFlipped: Bool { true }

    init(title: String, current: Bool, activeBadge: Bool) {
        self.current = current
        super.init(frame: .zero)
        clipsToBounds = true
        let row = NSStackView()
        row.orientation = .horizontal
        row.distribution = .fill
        row.spacing = 7
        let icon = NSImageView(image: paneFolderImage())
        icon.widthAnchor.constraint(equalToConstant: 23).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 23).isActive = true
        row.addArrangedSubview(icon)
        let titleButton = PaneClosureButton(title: title)
        titleButton.onPress = { [weak self] in self?.onSelect?() }
        titleButton.alignment = .left
        titleButton.lineBreakMode = .byTruncatingTail
        titleButton.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleButton.setContentHuggingPriority(.defaultLow, for: .horizontal)
        titleButton.setAccessibilityLabel("Tab \(title)")
        row.addArrangedSubview(titleButton)
        if activeBadge {
            let badge = NSTextField(labelWithString: "Active")
            badge.font = .systemFont(ofSize: 14)
            badge.alignment = .center
            badge.textColor = NSColor(calibratedRed: 0, green: 0.36, blue: 0.92, alpha: 1)
            badge.wantsLayer = true
            badge.layer?.backgroundColor = NSColor(calibratedRed: 0.80, green: 0.89, blue: 1, alpha: 1).cgColor
            badge.layer?.cornerRadius = 10
            badge.widthAnchor.constraint(equalToConstant: 49).isActive = true
            badge.heightAnchor.constraint(equalToConstant: 23).isActive = true
            row.addArrangedSubview(badge)
        }
        let close = PaneClosureButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close tab"))
        close.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        close.onPress = { [weak self] in self?.onClose?() }
        close.toolTip = "Close \(title) tab"
        close.translatesAutoresizingMaskIntoConstraints = false
        addSubview(close)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            close.widthAnchor.constraint(equalToConstant: 22),
            close.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -11),
            close.centerYAnchor.constraint(equalTo: centerYAnchor, constant: 1),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 13),
            row.trailingAnchor.constraint(equalTo: close.leadingAnchor, constant: -7),
            row.centerYAnchor.constraint(equalTo: centerYAnchor, constant: 1)
        ])
    }
    required init?(coder: NSCoder) { fatalError("Programmatic tab") }
    override func mouseDown(with event: NSEvent) { onSelect?() }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        hoverState.updateTrackingAreas()
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { hoverState.reset() }
    }
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath()
        path.move(to: NSPoint(x: 0.5, y: bounds.maxY))
        path.line(to: NSPoint(x: 4, y: 9))
        path.curve(to: NSPoint(x: 12, y: 1), controlPoint1: NSPoint(x: 4.5, y: 3), controlPoint2: NSPoint(x: 6, y: 1))
        path.line(to: NSPoint(x: bounds.maxX - 12, y: 1))
        path.curve(to: NSPoint(x: bounds.maxX - 4, y: 9), controlPoint1: NSPoint(x: bounds.maxX - 6, y: 1), controlPoint2: NSPoint(x: bounds.maxX - 4.5, y: 3))
        path.line(to: NSPoint(x: bounds.maxX - 0.5, y: bounds.maxY))
        path.close()
        let fill: NSColor = current
            ? (hovered ? NSColor(calibratedWhite: 0.96, alpha: 1) : .white)
            : (hovered ? NSColor(calibratedWhite: 0.89, alpha: 1) : NSColor(calibratedRed: 0.929, green: 0.933, blue: 0.941, alpha: 1))
        fill.setFill()
        path.fill()
        NSColor(calibratedWhite: 0.76, alpha: 1).setStroke()
        path.lineWidth = 1
        path.stroke()
    }
}

private final class PaneBreadcrumbView: NSView {
    var onNavigate: ((URL) -> Void)?
    var onEdit: (() -> Void)?
    var url = FileManager.default.homeDirectoryForCurrentUser { didSet { lastWidth = -1; needsLayout = true } }
    var virtualTitle: String? { didSet { lastWidth = -1; needsLayout = true } }
    var abbreviatesPath = true { didSet { lastWidth = -1; needsLayout = true } }
    private let row = NSStackView()
    private var lastWidth: CGFloat = -1

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        clipsToBounds = true
        row.orientation = .horizontal
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
            row.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10)
        ])
        setAccessibilityLabel("Folder path. Click a folder to navigate, or press Command-L to edit.")
    }
    required init?(coder: NSCoder) { fatalError("Programmatic breadcrumbs") }
    override func mouseDown(with event: NSEvent) { onEdit?() }
    override func layout() {
        super.layout()
        guard abs(lastWidth - bounds.width) > 0.5 else { return }
        lastWidth = bounds.width
        rebuild()
    }
    private func rebuild() {
        for child in row.arrangedSubviews { row.removeArrangedSubview(child); child.removeFromSuperview() }
        let icon = NSImageView(image: paneFolderImage())
        icon.widthAnchor.constraint(equalToConstant: 23).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 23).isActive = true
        row.addArrangedSubview(icon)
        if let virtualTitle {
            let label = NSTextField(labelWithString: virtualTitle)
            label.font = .systemFont(ofSize: 17)
            row.addArrangedSubview(label)
            return
        }
        var components: [(String, URL)] = [("Macintosh HD", URL(fileURLWithPath: "/", isDirectory: true))]
        var cursor = URL(fileURLWithPath: "/", isDirectory: true)
        for component in url.pathComponents.dropFirst() {
            cursor.appendPathComponent(component)
            components.append((component, cursor))
        }
        let allComponents = components
        func width(_ value: (String, URL)) -> CGFloat { (value.0 as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 17)]).width + 26 }
        let available = max(90, bounds.width - 60)
        var elided = false
        while components.count > 2 && (components.reduce(0) { $0 + width($1) } > available || (abbreviatesPath && components.count > 2)) {
            components.removeFirst()
            elided = true
        }
        if elided {
            let ellipsis = PaneClosureButton(title: "…")
            ellipsis.onPress = { [weak self, weak ellipsis] in
                guard let self, let ellipsis else { return }
                let menu = NSMenu()
                for (name, destination) in allComponents.dropLast(components.count) {
                    let item = NSMenuItem(title: name, action: #selector(self.ancestorSelected(_:)), keyEquivalent: "")
                    item.target = self
                    item.representedObject = destination
                    menu.addItem(item)
                }
                menu.popUp(positioning: nil, at: .zero, in: ellipsis)
            }
            row.addArrangedSubview(ellipsis)
            addChevron()
        }
        for (index, component) in components.enumerated() {
            let button = PaneClosureButton(title: component.0)
            button.onPress = { [weak self] in self?.onNavigate?(component.1) }
            button.toolTip = component.1.path
            button.lineBreakMode = .byTruncatingMiddle
            button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            row.addArrangedSubview(button)
            if index < components.count - 1 { addChevron() }
        }
    }
    private func addChevron() {
        let chevron = NSImageView(image: NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)!)
        chevron.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
        chevron.contentTintColor = .black
        chevron.widthAnchor.constraint(equalToConstant: 9).isActive = true
        row.addArrangedSubview(chevron)
    }
    @objc private func ancestorSelected(_ sender: NSMenuItem) {
        if let destination = sender.representedObject as? URL { onNavigate?(destination) }
    }
}

private final class PaneSearchCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
}

final class PaneIconCollectionView: NSCollectionView {
    var activate: (() -> Void)?
    var openRequested: (() -> Void)?
    var keyHandler: ((NSEvent) -> Bool)?
    var actionRequested: ((BrowserAction) -> Void)?
    lazy var selectionMarquee = PaneSelectionMarquee(owner: self,
        selection: { [weak self] in self?.selectionIndexPaths ?? [] },
        applySelection: { [weak self] paths in
            guard let self else { return }
            let previous = self.selectionIndexPaths
            self.selectionIndexPaths = paths
            let removed = previous.subtracting(paths), added = paths.subtracting(previous)
            if !removed.isEmpty { self.delegate?.collectionView?(self, didDeselectItemsAt: removed) }
            if !added.isEmpty { self.delegate?.collectionView?(self, didSelectItemsAt: added) }
        }, itemsIntersecting: { [weak self] rect in
            guard let layout = self?.collectionViewLayout else { return [] }
            return Set(layout.layoutAttributesForElements(in: rect).filter {
                $0.representedElementCategory == .item && $0.frame.intersects(rect)
            }.compactMap(\.indexPath))
        })

    override func mouseDown(with event: NSEvent) {
        activate?()
        window?.makeFirstResponder(self)
        if !event.modifierFlags.contains(.control), indexPathForItem(at: convert(event.locationInWindow, from: nil)) == nil {
            selectionMarquee.begin(with: event)
            return
        }
        super.mouseDown(with: event)
        if event.clickCount == 2, indexPathForItem(at: convert(event.locationInWindow, from: nil)) != nil { openRequested?() }
    }
    override func mouseDragged(with event: NSEvent) {
        if selectionMarquee.isActive { selectionMarquee.update(with: event) } else { super.mouseDragged(with: event) }
    }
    override func mouseUp(with event: NSEvent) {
        if selectionMarquee.isActive { selectionMarquee.update(with: event); selectionMarquee.finish() } else { super.mouseUp(with: event) }
    }
    override func reloadData() { selectionMarquee.finish(); super.reloadData() }
    override func viewWillMove(toSuperview newSuperview: NSView?) {
        if newSuperview == nil { selectionMarquee.finish() }
        super.viewWillMove(toSuperview: newSuperview)
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        activate?()
        window?.makeFirstResponder(self)
        if let index = indexPathForItem(at: convert(event.locationInWindow, from: nil)) {
            if !selectionIndexPaths.contains(index) {
                selectionIndexPaths = [index]
                delegate?.collectionView?(self, didSelectItemsAt: [index])
            }
        } else {
            let previousSelection = selectionIndexPaths
            selectionIndexPaths = []
            if !previousSelection.isEmpty { delegate?.collectionView?(self, didDeselectItemsAt: previousSelection) }
        }
        return super.menu(for: event)
    }
    override func becomeFirstResponder() -> Bool { activate?(); return super.becomeFirstResponder() }
    override func keyDown(with event: NSEvent) {
        if selectionMarquee.isActive {
            selectionMarquee.finish(cancelled: event.keyCode == 53)
            if event.keyCode == 53 { return }
        }
        if keyHandler?(event) == true { return }
        super.keyDown(with: event)
    }
    @objc func cut(_ sender: Any?) { activate?(); actionRequested?(.cut) }
    @objc func copy(_ sender: Any?) { activate?(); actionRequested?(.copy) }
    @objc func paste(_ sender: Any?) { activate?(); actionRequested?(.paste) }
}

private final class PaneIconItem: NSCollectionViewItem {
    let iconView = NSImageView()
    let nameField = NSTextField(wrappingLabelWithString: "")
    private let detailField = NSTextField(labelWithString: "")
    private var showsLocation = false
    private var hovered = false
    private var mode = "mediumIcons"
    private var compact = false
    override var isSelected: Bool { didSet { updateSelection() } }
    override var highlightState: NSCollectionViewItem.HighlightState { didSet { updateSelection() } }

    override func loadView() {
        let tile = PaneIconTileView()
        tile.onHoverChange = { [weak self] hovered in self?.hovered = hovered; self?.updateSelection() }
        view = tile
        view.wantsLayer = true
        view.layer?.cornerRadius = 7
        iconView.imageScaling = .scaleProportionallyUpOrDown
        nameField.lineBreakMode = .byTruncatingTail
        detailField.lineBreakMode = .byTruncatingTail
        detailField.font = .systemFont(ofSize: 12)
        detailField.textColor = .secondaryLabelColor
        for child in [iconView, nameField, detailField] { view.addSubview(child); child.clipsToBounds = true }
        imageView = iconView; textField = nameField
        updateSelection()
    }

    func configure(mode: String, compact: Bool, name: String, detail: String, location: String? = nil) {
        _ = view
        self.mode = mode; self.compact = compact
        nameField.stringValue = name
        showsLocation = location != nil
        detailField.stringValue = location ?? detail
        detailField.identifier = location == nil ? nil : NSUserInterfaceItemIdentifier("browser.result.location")
        detailField.lineBreakMode = showsLocation ? .byTruncatingMiddle : .byTruncatingTail
        nameField.font = .systemFont(ofSize: compact ? 14 : 16)
        let horizontal = ["list", "smallIcons", "tiles"].contains(mode)
        nameField.alignment = horizontal ? .left : .center
        nameField.maximumNumberOfLines = ["list", "smallIcons", "tiles"].contains(mode) ? 1 : 2
        detailField.alignment = horizontal ? .left : .center
        detailField.isHidden = mode != "tiles" && !showsLocation
        view.needsLayout = true
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        let bounds = view.bounds
        if mode == "list" || mode == "smallIcons" {
            let icon: CGFloat = mode == "list" ? 22 : 18
            iconView.frame = NSRect(x: 6, y: (bounds.height - icon) / 2, width: icon, height: icon)
            nameField.frame = NSRect(x: icon + 14, y: showsLocation ? bounds.height / 2 : (bounds.height - 22) / 2, width: max(0, bounds.width - icon - 20), height: 22)
            if showsLocation { detailField.frame = NSRect(x: icon + 14, y: max(2, bounds.height / 2 - 19), width: max(0, bounds.width - icon - 20), height: 18) }
        } else if mode == "tiles" {
            iconView.frame = NSRect(x: 8, y: (bounds.height - 48) / 2, width: 48, height: 48)
            nameField.frame = NSRect(x: 66, y: bounds.height / 2 + 2, width: max(0, bounds.width - 74), height: 22)
            detailField.frame = NSRect(x: 66, y: max(5, bounds.height / 2 - 20), width: max(0, bounds.width - 74), height: 19)
        } else {
            let icon: CGFloat = mode == "largeIcons" ? 102 : 58
            iconView.frame = NSRect(x: (bounds.width - icon) / 2, y: bounds.height - icon - 7, width: icon, height: icon)
            nameField.frame = NSRect(x: 4, y: showsLocation ? 23 : 4, width: max(0, bounds.width - 8), height: max(30, bounds.height - icon - (showsLocation ? 33 : 14)))
            if showsLocation { detailField.frame = NSRect(x: 4, y: 3, width: max(0, bounds.width - 8), height: 18) }
        }
    }

    private func updateSelection() {
        guard isViewLoaded else { return }
        view.layer?.backgroundColor = (isSelected ? NSColor(calibratedRed: 0.79, green: 0.88, blue: 1, alpha: 1) : (hovered ? NSColor(calibratedWhite: 0.95, alpha: 1) : NSColor.clear)).cgColor
        nameField.textColor = .black
    }
    override func prepareForReuse() {
        super.prepareForReuse()
        hovered = false
        if isViewLoaded {
            (view as? PaneIconTileView)?.resetHover()
            view.alphaValue = 1
            updateSelection()
        }
    }
}

private final class PaneGroupHeaderView: NSView {
    private let label = NSTextField(labelWithString: "")
    var title = "" { didSet { label.stringValue = title; setAccessibilityLabel(title) } }
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        clipsToBounds = true
        label.font = .systemFont(ofSize: 15, weight: .semibold)
        label.textColor = NSColor(calibratedWhite: 0.25, alpha: 1)
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12), label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8), label.centerYAnchor.constraint(equalTo: centerYAnchor)])
    }
    required init?(coder: NSCoder) { fatalError("Programmatic group header") }
    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedWhite: 0.965, alpha: 1).setFill(); bounds.fill()
        NSColor(calibratedWhite: 0.88, alpha: 1).setFill(); NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
    }
}

private struct PaneMediaMetadata: Sendable {
    let dimensions: String
    let duration: String
    static let empty = PaneMediaMetadata(dimensions: "—", duration: "—")
    static func read(url: URL, image: Bool) async -> PaneMediaMetadata {
        if image {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
                  let height = properties[kCGImagePropertyPixelHeight] as? NSNumber else { return .empty }
            return PaneMediaMetadata(dimensions: "\(width.intValue) × \(height.intValue)", duration: "—")
        }
        let asset = AVURLAsset(url: url)
        let seconds = (try? await asset.load(.duration)).map(CMTimeGetSeconds)
        var duration = "—"
        if let seconds, seconds.isFinite, seconds >= 0, seconds < Double(Int.max) {
            let value = Int(seconds)
            duration = value >= 3600 ? String(format: "%d:%02d:%02d", value / 3600, value / 60 % 60, value % 60) : String(format: "%d:%02d", value / 60, value % 60)
        }
        var dimensions = "—"
        if let track = try? await asset.loadTracks(withMediaType: .video).first,
           let size = try? await track.load(.naturalSize), let transform = try? await track.load(.preferredTransform) {
            let size = size.applying(transform)
            dimensions = "\(Int(abs(size.width).rounded())) × \(Int(abs(size.height).rounded()))"
        }
        return PaneMediaMetadata(dimensions: dimensions, duration: duration)
    }
}

private final class PaneIconTileView: NSView {
    var onHoverChange: ((Bool) -> Void)?
    private lazy var hoverState = PointerHoverState(view: self) { [weak self] hovered in self?.onHoverChange?(hovered) }
    override init(frame frameRect: NSRect) { super.init(frame: frameRect); clipsToBounds = true }
    required init?(coder: NSCoder) { fatalError("Programmatic icon tile") }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        hoverState.updateTrackingAreas()
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { resetHover() }
    }
    func resetHover() { hoverState.reset() }
}
