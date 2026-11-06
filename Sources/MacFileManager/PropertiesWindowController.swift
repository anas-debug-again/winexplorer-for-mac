import AppKit
import FileManagerCore
import UniformTypeIdentifiers

private final class PropertiesDocumentView: NSView {
    override var isFlipped: Bool { true }
}

private final class PropertiesScanToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
}

private struct PropertiesResolvedItem {
    let file: FilePropertySnapshot
    let typeName: String
    let applicationName: String
    let ownerName: String
    let groupName: String
}

/// Only explicit Apply or OK requests a rename from the owning browser.
final class PropertiesWindowController: NSWindowController, NSWindowDelegate, NSTextFieldDelegate {
    var onClose: (() -> Void)?
    var onOpenLocation: ((URL) -> Void)?
    var onRename: ((URL, String, @escaping (Result<URL, Error>) -> Void) -> Void)?
    private(set) var urls: [URL]
    private let nameField = NSTextField(string: "")
    private let summaryLabel = makeLabel("", size: 13, color: .secondaryLabelColor)
    private let iconView = NSImageView()
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private let scanLabel = NSTextField(wrappingLabelWithString: "")
    private let spinner = NSProgressIndicator()
    private var scanStatusRow: NSStackView!
    private let contentHost = NSView()
    private var values: [String: NSTextField] = [:]
    private var rows: [String: NSView] = [:]
    private var tabs: [ActionButton] = []
    private var pages: [NSScrollView] = []
    private var applyButton: ActionButton!
    private var okButton: ActionButton!
    private var cancelButton: ActionButton!
    private var refreshButton: ActionButton!
    private var openLocationButton: ActionButton!
    private var copyPathButton: ActionButton!
    private var metadata: [PropertiesResolvedItem] = []
    private var scanToken: PropertiesScanToken?
    private var generation = 0
    private var isRenaming = false
    private var isClosed = false
    private var keyMonitor: Any?
    private let scanQueue = DispatchQueue(label: "FileManager.properties", qos: .userInitiated, attributes: .concurrent)
    private var originalName: String { urls.count == 1 ? Self.displayName(for: urls[0]) : "" }
    private var nameIsDirty: Bool { urls.count == 1 && nameField.stringValue != originalName }
    private static func displayName(for url: URL) -> String {
        AppShortcutDocument.isShortcut(url) ? url.deletingPathExtension().lastPathComponent : url.lastPathComponent
    }

    init(urls: [URL]) {
        var paths = Set<String>()
        self.urls = urls.map(\.standardizedFileURL).filter { paths.insert($0.path).inserted }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 660),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.contentMinSize = NSSize(width: 560, height: 560)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.identifier = NSUserInterfaceItemIdentifier("filePropertiesWindow")
        super.init(window: window)
        window.delegate = self
        buildInterface(); updateTitle(); window.center()
        installKeyboardShortcuts(); refreshMetadata()
    }
    required init?(coder: NSCoder) { fatalError("Programmatic properties window") }
    deinit { scanToken?.cancel(); if let keyMonitor { NSEvent.removeMonitor(keyMonitor) } }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(sender)
        if urls.count == 1 {
            window?.makeFirstResponder(nameField)
            if let editor = nameField.currentEditor() as? NSTextView {
                editor.allowsUndo = true
                let length = (nameField.stringValue as NSString).length
                let suffix = AppShortcutDocument.isShortcut(urls[0]) ? 0 : (urls[0].pathExtension as NSString).length
                editor.setSelectedRange(NSRange(location: 0, length: suffix > 0 ? max(0, length - suffix - 1) : length))
            }
        }
    }

    private func buildInterface() {
        guard let window else { return }
        let root = NSView(); root.wantsLayer = true
        root.layer?.backgroundColor = NSColor(calibratedWhite: 0.965, alpha: 1).cgColor
        window.contentView = root
        let header = NSView(); header.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(header)
        iconView.imageScaling = .scaleProportionallyDown
        iconView.image = NSWorkspace.shared.icon(for: urls.count > 1 ? .folder : .data)
        iconView.translatesAutoresizingMaskIntoConstraints = false; header.addSubview(iconView)
        nameField.stringValue = urls.count == 1 ? originalName : "\(urls.count) items"
        nameField.font = .systemFont(ofSize: 18, weight: .semibold)
        nameField.isEditable = urls.count == 1; nameField.isSelectable = true
        nameField.isBordered = urls.count == 1; nameField.drawsBackground = urls.count == 1
        nameField.backgroundColor = .white; nameField.focusRingType = .exterior
        nameField.delegate = self; nameField.translatesAutoresizingMaskIntoConstraints = false
        nameField.setAccessibilityLabel(urls.count == 1 ? "Name" : "Selected items")
        nameField.setAccessibilityIdentifier("propertiesName"); header.addSubview(nameField)
        summaryLabel.stringValue = urls.count == 1 ? "File properties" : "Properties for the selected items"
        summaryLabel.translatesAutoresizingMaskIntoConstraints = false; header.addSubview(summaryLabel)
        let tabBar = NSStackView(); tabBar.orientation = .horizontal; tabBar.spacing = 5; tabBar.distribution = .fill
        tabBar.alignment = .centerY; tabBar.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(tabBar)
        for (index, title) in ["General", "Details", "Permissions"].enumerated() {
            let button = ActionButton(title) { [weak self] in self?.selectTab(index) }
            button.font = .systemFont(ofSize: 15); button.setAccessibilityIdentifier("propertiesTab" + title)
            button.heightAnchor.constraint(equalToConstant: 33).isActive = true
            tabs.append(button); tabBar.addArrangedSubview(button)
        }
        tabBar.addArrangedSubview(NSView())
        refreshButton = ActionButton("Refresh", symbol: "arrow.clockwise") { [weak self] in self?.refreshMetadata() }
        refreshButton.font = .systemFont(ofSize: 14); refreshButton.heightAnchor.constraint(equalToConstant: 33).isActive = true
        refreshButton.setAccessibilityIdentifier("propertiesRefresh"); tabBar.addArrangedSubview(refreshButton)
        contentHost.translatesAutoresizingMaskIntoConstraints = false; contentHost.wantsLayer = true
        contentHost.layer?.backgroundColor = NSColor.white.cgColor
        contentHost.layer?.borderWidth = 1; contentHost.layer?.borderColor = NSColor(calibratedWhite: 0.82, alpha: 1).cgColor
        contentHost.layer?.cornerRadius = 5; contentHost.clipsToBounds = true; root.addSubview(contentHost)
        buildGeneral(makePage()); buildDetails(makePage()); buildPermissions(makePage())
        let bottom = NSStackView(); bottom.orientation = .vertical; bottom.alignment = .leading; bottom.distribution = .fill
        bottom.spacing = 10; bottom.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(bottom)
        errorLabel.font = .systemFont(ofSize: 13); errorLabel.textColor = .systemRed
        errorLabel.maximumNumberOfLines = 3; errorLabel.isSelectable = true; errorLabel.isHidden = true
        errorLabel.setAccessibilityIdentifier("propertiesError"); bottom.addArrangedSubview(errorLabel)
        errorLabel.widthAnchor.constraint(equalTo: bottom.widthAnchor).isActive = true
        let actions = NSStackView(); actions.orientation = .horizontal; actions.alignment = .centerY; actions.spacing = 8; actions.distribution = .fill
        actions.addArrangedSubview(NSView())
        okButton = ActionButton("OK") { [weak self] in self?.applyName(closeAfter: true) }
        cancelButton = ActionButton("Cancel") { [weak self] in self?.cancel() }
        applyButton = ActionButton("Apply") { [weak self] in self?.applyName(closeAfter: false) }
        for (name, button) in [("OK", okButton!), ("Cancel", cancelButton!), ("Apply", applyButton!)] {
            button.font = .systemFont(ofSize: 15)
            button.setContentHuggingPriority(.defaultLow, for: .horizontal)
            button.widthAnchor.constraint(equalToConstant: 90).isActive = true
            button.heightAnchor.constraint(equalToConstant: 34).isActive = true
            button.setAccessibilityIdentifier("properties" + name); actions.addArrangedSubview(button)
        }
        okButton.keyEquivalent = "\r"; window.defaultButtonCell = okButton.cell as? NSButtonCell
        cancelButton.keyEquivalent = "\u{1b}"
        bottom.addArrangedSubview(actions); actions.widthAnchor.constraint(equalTo: bottom.widthAnchor).isActive = true
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 22),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -22),
            header.topAnchor.constraint(equalTo: root.topAnchor, constant: 18), header.heightAnchor.constraint(equalToConstant: 64),
            iconView.leadingAnchor.constraint(equalTo: header.leadingAnchor), iconView.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 52), iconView.heightAnchor.constraint(equalToConstant: 52),
            nameField.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 16),
            nameField.trailingAnchor.constraint(equalTo: header.trailingAnchor), nameField.topAnchor.constraint(equalTo: header.topAnchor, constant: 4),
            nameField.heightAnchor.constraint(equalToConstant: 29),
            summaryLabel.leadingAnchor.constraint(equalTo: nameField.leadingAnchor), summaryLabel.trailingAnchor.constraint(equalTo: nameField.trailingAnchor),
            summaryLabel.topAnchor.constraint(equalTo: nameField.bottomAnchor, constant: 6),
            tabBar.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18), tabBar.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -18),
            tabBar.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 12), tabBar.heightAnchor.constraint(equalToConstant: 33),
            contentHost.leadingAnchor.constraint(equalTo: tabBar.leadingAnchor), contentHost.trailingAnchor.constraint(equalTo: tabBar.trailingAnchor),
            contentHost.topAnchor.constraint(equalTo: tabBar.bottomAnchor, constant: 8),
            contentHost.bottomAnchor.constraint(equalTo: bottom.topAnchor, constant: -12),
            bottom.leadingAnchor.constraint(equalTo: tabBar.leadingAnchor), bottom.trailingAnchor.constraint(equalTo: tabBar.trailingAnchor),
            bottom.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16)
        ])
        selectTab(0); updateButtons()
    }

    private func makePage() -> NSStackView {
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        scroll.drawsBackground = false; scroll.translatesAutoresizingMaskIntoConstraints = false
        let document = PropertiesDocumentView(); document.translatesAutoresizingMaskIntoConstraints = false
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading
        stack.distribution = .fill; stack.spacing = 9; stack.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack); scroll.documentView = document; contentHost.addSubview(scroll); pages.append(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: contentHost.leadingAnchor, constant: 1), scroll.trailingAnchor.constraint(equalTo: contentHost.trailingAnchor, constant: -1),
            scroll.topAnchor.constraint(equalTo: contentHost.topAnchor, constant: 1), scroll.bottomAnchor.constraint(equalTo: contentHost.bottomAnchor, constant: -1),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor), document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 17), stack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -17),
            stack.topAnchor.constraint(equalTo: document.topAnchor, constant: 16), stack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -16)
        ])
        return stack
    }
    private func addRow(_ title: String, key: String, to stack: NSStackView, lines: Int = 2) {
        let label = makeLabel(title, size: 14, color: .secondaryLabelColor)
        label.widthAnchor.constraint(equalToConstant: 132).isActive = true
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        let value = NSTextField(wrappingLabelWithString: "—")
        value.font = .systemFont(ofSize: 14); value.isSelectable = true
        let fullPath = ["path", "detailPaths", "location", "linkTarget"].contains(key)
        value.maximumNumberOfLines = fullPath ? 0 : lines
        value.lineBreakMode = fullPath ? .byCharWrapping : .byTruncatingMiddle
        value.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        value.setAccessibilityLabel(title); value.setAccessibilityIdentifier("propertiesValue-" + key)
        let row = NSStackView(views: [label, value]); row.orientation = .horizontal; row.alignment = .top
        row.distribution = .fill; row.spacing = 12
        stack.addArrangedSubview(row); row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        values[key] = value; rows[key] = row
    }
    private func addSeparator(to stack: NSStackView) {
        let line = separator(); stack.addArrangedSubview(line); line.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }
    private func addNote(_ text: String, to stack: NSStackView) {
        let note = NSTextField(wrappingLabelWithString: text); note.font = .systemFont(ofSize: 13); note.textColor = .secondaryLabelColor
        stack.addArrangedSubview(note); note.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }
    private func buildGeneral(_ stack: NSStackView) {
        addRow("Type", key: "type", to: stack); addRow("Opens with", key: "application", to: stack)
        addSeparator(to: stack)
        addRow("Location", key: "location", to: stack); addRow("Full path", key: "path", to: stack, lines: 3)
        copyPathButton = ActionButton(urls.count == 1 ? "Copy path" : "Copy paths", symbol: "doc.on.doc") { [weak self] in self?.copyPaths() }
        openLocationButton = ActionButton("Open location", symbol: "folder") { [weak self] in self?.openLocation() }
        for button in [copyPathButton!, openLocationButton!] { button.font = .systemFont(ofSize: 13); button.heightAnchor.constraint(equalToConstant: 30).isActive = true }
        copyPathButton.setAccessibilityIdentifier("propertiesCopyPath"); openLocationButton.setAccessibilityIdentifier("propertiesOpenLocation")
        let actionRow = NSStackView(views: [copyPathButton!, openLocationButton!, NSView()]); actionRow.orientation = .horizontal; actionRow.spacing = 8; actionRow.distribution = .fill
        stack.addArrangedSubview(actionRow); actionRow.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        addSeparator(to: stack)
        addRow("Size", key: "size", to: stack); addRow("Size on disk", key: "allocated", to: stack); addRow("Contains", key: "contains", to: stack)
        spinner.style = .spinning; spinner.controlSize = .small; spinner.isDisplayedWhenStopped = false
        spinner.widthAnchor.constraint(equalToConstant: 16).isActive = true; spinner.heightAnchor.constraint(equalToConstant: 16).isActive = true
        scanLabel.font = .systemFont(ofSize: 12); scanLabel.textColor = .secondaryLabelColor; scanLabel.maximumNumberOfLines = 3
        scanLabel.setAccessibilityIdentifier("propertiesScanStatus")
        let scanRow = NSStackView(views: [spinner, scanLabel]); scanRow.orientation = .horizontal; scanRow.alignment = .centerY; scanRow.spacing = 7; scanRow.distribution = .fill
        scanStatusRow = scanRow
        stack.addArrangedSubview(scanRow); scanRow.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        addSeparator(to: stack)
        addRow("Created", key: "created", to: stack); addRow("Modified", key: "modified", to: stack); addRow("Accessed", key: "accessed", to: stack)
    }
    private func buildDetails(_ stack: NSStackView) {
        addRow("Name", key: "detailName", to: stack); addRow("Extension", key: "extension", to: stack); addRow("Kind", key: "kind", to: stack)
        addSeparator(to: stack)
        addRow("Hidden", key: "hidden", to: stack); addRow("Locked", key: "locked", to: stack)
        addRow("Symbolic link", key: "link", to: stack); addRow("Link target", key: "linkTarget", to: stack, lines: 4)
        addRow("File identifier", key: "identifier", to: stack); addRow("Metadata changed", key: "metadataChanged", to: stack)
        addSeparator(to: stack); addRow("Selected paths", key: "detailPaths", to: stack, lines: 0)
        addNote("Hidden reflects dot names or the macOS hidden flag. Locked reflects the file’s immutable flag.", to: stack)
    }
    private func buildPermissions(_ stack: NSStackView) {
        addNote("Permissions (view only)", to: stack)
        addRow("Owner", key: "owner", to: stack); addRow("Group", key: "group", to: stack); addSeparator(to: stack)
        addRow("Owner access", key: "ownerAccess", to: stack); addRow("Group access", key: "groupAccess", to: stack)
        addRow("Everyone else", key: "otherAccess", to: stack); addSeparator(to: stack)
        addRow("POSIX mode", key: "mode", to: stack); addRow("Special flags", key: "special", to: stack)
        addNote("These are the file’s POSIX permission bits. macOS access control lists, privacy permissions, and volume restrictions can also affect access.", to: stack)
    }
    private func selectTab(_ index: Int) {
        for (i, tab) in tabs.enumerated() { tab.selected = i == index }
        for (i, page) in pages.enumerated() { page.isHidden = i != index }
    }
    private func set(_ key: String, _ text: String) { values[key]?.stringValue = text; values[key]?.toolTip = text }
    private func updateTitle() { window?.title = urls.count == 1 ? "\(Self.displayName(for: urls[0])) Properties" : "\(urls.count) Items Properties" }

    private func refreshMetadata() {
        guard !isRenaming, !isClosed else { return }
        scanToken?.cancel(); generation += 1
        let requestedGeneration = generation
        let token = PropertiesScanToken(); scanToken = token
        let requestedURLs = urls
        set("path", requestedURLs.map(\.path).joined(separator: "\n"))
        set("detailPaths", requestedURLs.map(\.path).joined(separator: "\n"))
        set("location", common(requestedURLs.map { $0.deletingLastPathComponent().path }, mixed: "Multiple locations"))
        set("size", "Calculating…"); set("allocated", "Calculating…"); set("contains", "Calculating…")
        scanStatusRow.isHidden = false
        spinner.startAnimation(nil); scanLabel.stringValue = "Reading file information…"; errorLabel.isHidden = true
        scanQueue.async { [weak self] in
            var items: [PropertiesResolvedItem] = []
            var errors: [String] = []
            for url in requestedURLs {
                if token.isCancelled { return }
                do {
                    let file = try FileProperties.snapshot(for: url)
                    let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
                    let type = try? url.resourceValues(forKeys: [.localizedTypeDescriptionKey])
                    let application = NSWorkspace.shared.urlForApplication(toOpen: url)
                    let isShortcut = file.kind == .regularFile && AppShortcutDocument.isShortcut(url)
                    items.append(PropertiesResolvedItem(file: file,
                        typeName: isShortcut ? "Shortcut" : (file.kind == .symbolicLink ? "Symbolic link" : (type?.localizedTypeDescription ?? Self.kindName(file.kind))),
                        applicationName: isShortcut ? "WinExplorer for Mac" : (application.map { FileManager.default.displayName(atPath: $0.path) } ?? "No default application"),
                        ownerName: (attributes?[.ownerAccountName] as? String).map { "\($0) (\(file.ownerID))" } ?? "UID \(file.ownerID)",
                        groupName: (attributes?[.groupOwnerAccountName] as? String).map { "\($0) (\(file.groupID))" } ?? "GID \(file.groupID)"))
                } catch { errors.append("\(url.lastPathComponent): \(error.localizedDescription)") }
            }
            guard !token.isCancelled else { return }
            let resolved = items, failures = errors
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.isClosed, self.generation == requestedGeneration else { return }
                self.metadata = resolved; self.renderMetadata()
                self.scanLabel.stringValue = "Calculating sizes and contents…"
                if !failures.isEmpty { self.showError(failures.joined(separator: "\n")) }
            }
            let totals = FileProperties.aggregate(urls: requestedURLs, cancellation: { token.isCancelled })
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.isClosed, self.generation == requestedGeneration, !token.isCancelled else { return }
                self.renderTotals(totals)
            }
        }
    }
    private func renderMetadata() {
        let files = metadata.map(\.file)
        guard !files.isEmpty else {
            for key in values.keys where !["path", "detailPaths", "location", "size", "allocated", "contains"].contains(key) { set(key, "Unavailable") }
            summaryLabel.stringValue = "File information unavailable"; return
        }
        set("type", common(metadata.map(\.typeName), mixed: "Multiple file types"))
        set("application", common(metadata.map(\.applicationName), mixed: "Multiple applications"))
        for (key, dates) in [("created", files.map(\.created)), ("modified", files.map(\.modified)),
                             ("accessed", files.map(\.accessed)), ("metadataChanged", files.map(\.metadataChanged))] {
            set(key, common(dates.map(formatDate), mixed: "Multiple dates"))
        }
        set("detailName", common(files.map { Self.displayName(for: $0.url) }, mixed: "\(urls.count) selected items"))
        set("extension", common(files.map { $0.pathExtension.isEmpty ? "None" : "." + $0.pathExtension }, mixed: "Multiple extensions"))
        set("kind", common(files.map { Self.kindName($0.kind) }, mixed: "Multiple kinds"))
        set("hidden", common(files.map { $0.isHidden ? "Yes" : "No" }, mixed: "Some items"))
        set("locked", common(files.map { $0.isLocked ? "Yes" : "No" }, mixed: "Some items"))
        set("link", common(files.map { $0.kind == .symbolicLink ? "Yes" : "No" }, mixed: "Some items"))
        set("linkTarget", common(files.map { $0.symbolicLinkTarget ?? "Not a symbolic link" }, mixed: "Multiple targets"))
        set("identifier", common(files.map { "\($0.device):\($0.inode)" }, mixed: "Multiple identifiers"))
        set("owner", common(metadata.map(\.ownerName), mixed: "Multiple owners"))
        set("group", common(metadata.map(\.groupName), mixed: "Multiple groups"))
        set("ownerAccess", common(files.map { accessDescription($0.mode >> 6) }, mixed: "Varies by item"))
        set("groupAccess", common(files.map { accessDescription($0.mode >> 3) }, mixed: "Varies by item"))
        set("otherAccess", common(files.map { accessDescription($0.mode) }, mixed: "Varies by item"))
        set("mode", common(files.map { String(format: "%04o", $0.mode & 0o7777) + "  " + $0.permissions }, mixed: "Multiple permission modes"))
        set("special", common(files.map { specialPermissions($0.mode) }, mixed: "Varies by item"))
        if urls.count == 1, let file = files.first {
            summaryLabel.stringValue = metadata[0].typeName
            let contentType: UTType = file.kind == .directory ? .folder : (UTType(filenameExtension: file.pathExtension) ?? .data)
            iconView.image = NSWorkspace.shared.icon(for: contentType)
            rows["contains"]?.isHidden = file.kind != .directory
        } else {
            let selectedFolders = files.filter { $0.kind == .directory }.count
            summaryLabel.stringValue = "\(urls.count) selected items" + (selectedFolders > 0 ? " (\(countLabel(selectedFolders, "folder")))" : "")
            rows["contains"]?.isHidden = false
        }
    }
    private func renderTotals(_ totals: FilePropertyTotals) {
        spinner.stopAnimation(nil)
        set("size", formatSize(totals.logicalSize)); set("allocated", formatSize(totals.allocatedSize))
        values["allocated"]?.toolTip = "Allocated storage reported by macOS. Shared APFS blocks may be counted for each file."
        var contains = "\(countLabel(totals.fileCount, "file")), \(countLabel(totals.folderCount, "subfolder"))"
        if totals.symbolicLinkCount > 0 { contains += " (\(countLabel(totals.symbolicLinkCount, "symbolic link")))" }
        set("contains", contains)
        if totals.isPartial {
            var reasons: [String] = []
            if totals.inaccessibleCount > 0 { reasons.append("\(countLabel(totals.inaccessibleCount, "item")) could not be read") }
            if totals.isTruncated { reasons.append("the scan limit was reached") }
            if totals.isCancelled { reasons.append("the scan was stopped") }
            scanLabel.stringValue = "Partial totals" + (reasons.isEmpty ? "." : ": " + reasons.joined(separator: "; ") + ".")
        } else {
            scanLabel.stringValue = urls.count == 1 && metadata.first?.file.kind != .directory ? "" : "Includes hidden files. Symbolic links are not followed."
        }
        scanStatusRow.isHidden = scanLabel.stringValue.isEmpty
    }
    private func countLabel(_ count: Int, _ singular: String) -> String {
        "\(count) \(singular)" + (count == 1 ? "" : "s")
    }
    private func common(_ strings: [String], mixed: String) -> String {
        guard let first = strings.first else { return "—" }
        return strings.allSatisfy { $0 == first } ? first : mixed
    }
    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter(); formatter.dateStyle = .medium; formatter.timeStyle = .medium
        return formatter.string(from: date)
    }
    private func formatSize(_ size: Int64) -> String {
        if size < 1_000 { return "\(size) " + (size == 1 ? "byte" : "bytes") }
        let formatter = NumberFormatter(); formatter.numberStyle = .decimal
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file) + " (" + (formatter.string(from: NSNumber(value: size)) ?? String(size)) + " bytes)"
    }
    private static func kindName(_ kind: FilePropertyKind) -> String {
        switch kind {
        case .regularFile: return "File"
        case .directory: return "Folder"
        case .symbolicLink: return "Symbolic link"
        case .socket: return "Socket"
        case .characterDevice: return "Character device"
        case .blockDevice: return "Block device"
        case .fifo: return "Named pipe"
        case .other: return "Other"
        }
    }
    private func accessDescription(_ mode: UInt32) -> String {
        let bits = mode & 7
        let access = [(UInt32(4), "Read"), (UInt32(2), "Write"), (UInt32(1), "Execute")].compactMap { bits & $0.0 != 0 ? $0.1 : nil }
        return access.isEmpty ? "No access" : access.joined(separator: ", ")
    }
    private func specialPermissions(_ mode: UInt32) -> String {
        let flags = [(UInt32(0o4000), "Set user ID"), (UInt32(0o2000), "Set group ID"), (UInt32(0o1000), "Sticky")].compactMap { mode & $0.0 != 0 ? $0.1 : nil }
        return flags.isEmpty ? "None" : flags.joined(separator: ", ")
    }
    private func updateButtons() {
        applyButton?.isEnabled = nameIsDirty && !isRenaming
        okButton?.isEnabled = !isRenaming; cancelButton?.isEnabled = !isRenaming
        refreshButton?.isEnabled = !isRenaming; nameField.isEditable = urls.count == 1 && !isRenaming
        copyPathButton?.isEnabled = !urls.isEmpty
        let locations = Set(urls.map { $0.deletingLastPathComponent().path })
        openLocationButton?.isEnabled = locations.count == 1 && !isRenaming
        openLocationButton?.toolTip = locations.count > 1 ? "Selected items are in multiple locations" : urls.first?.deletingLastPathComponent().path
    }
    func controlTextDidChange(_ obj: Notification) { errorLabel.isHidden = true; updateButtons() }
    func controlTextDidBeginEditing(_ obj: Notification) { (nameField.currentEditor() as? NSTextView)?.allowsUndo = true }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) { applyName(closeAfter: true); return true }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) { cancel(); return true }
        return false
    }
    private func showError(_ message: String) { errorLabel.stringValue = message; errorLabel.toolTip = message; errorLabel.isHidden = false }
    private func applyName(closeAfter: Bool) {
        guard !isRenaming else { return }
        window?.makeFirstResponder(nil)
        guard nameIsDirty, let url = urls.first else { if closeAfter { close() }; return }
        var newName = nameField.stringValue
        guard !newName.isEmpty, newName != ".", newName != "..", !newName.contains("/"), !newName.contains("\0") else {
            showError("Enter a file name without a slash. The name cannot be empty, “.”, or “..”.")
            window?.makeFirstResponder(nameField); return
        }
        if AppShortcutDocument.isShortcut(url),
           (newName as NSString).pathExtension.caseInsensitiveCompare(AppShortcutDocument.fileExtension) != .orderedSame {
            newName += "." + AppShortcutDocument.fileExtension
        }
        guard let onRename else { showError("Renaming is unavailable in this window."); return }
        scanToken?.cancel(); generation += 1; isRenaming = true; updateButtons()
        scanStatusRow.isHidden = false
        spinner.startAnimation(nil); scanLabel.stringValue = "Renaming…"; errorLabel.isHidden = true
        onRename(url, newName) { [weak self] result in
            DispatchQueue.main.async {
                guard let self, !self.isClosed else { return }
                self.isRenaming = false; self.spinner.stopAnimation(nil)
                switch result {
                case .success(let renamed):
                    self.urls = [renamed.standardizedFileURL]; self.nameField.stringValue = Self.displayName(for: renamed)
                    self.updateTitle(); self.updateButtons()
                    if closeAfter { self.close() } else { self.refreshMetadata() }
                case .failure(let error):
                    self.scanLabel.stringValue = "Rename was not applied."
                    self.showError(error.localizedDescription); self.updateButtons()
                    self.window?.makeFirstResponder(self.nameField)
                }
            }
        }
    }
    private func copyPaths() {
        guard !urls.isEmpty else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(urls.map(\.path).joined(separator: "\n"), forType: .string)
    }
    private func openLocation() {
        guard let first = urls.first?.deletingLastPathComponent(), urls.allSatisfy({ $0.deletingLastPathComponent() == first }) else { return }
        onOpenLocation?(first)
    }
    private func cancel() { guard !isRenaming else { return }; close() }
    func windowShouldClose(_ sender: NSWindow) -> Bool { !isRenaming }
    func windowWillClose(_ notification: Notification) {
        guard !isClosed else { return }
        isClosed = true; scanToken?.cancel(); generation += 1
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor); self.keyMonitor = nil }
        onClose?()
    }
    private func installKeyboardShortcuts() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let window = self.window, event.window === window else { return event }
            let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
            let key = shortcutKey(for: event)
            if event.keyCode == 53 || (modifiers == .command && key == "w") { self.cancel(); return nil }
            guard modifiers.contains(.control), !modifiers.contains(.command), !modifiers.contains(.option),
                  let editor = window.firstResponder as? NSTextView else { return event }
            switch key {
            case "a": editor.selectAll(nil)
            case "c": editor.copy(nil)
            case "x": guard editor.isEditable else { return event }; editor.cut(nil)
            case "v": guard editor.isEditable else { return event }; editor.paste(nil)
            case "z":
                guard editor.isEditable else { return event }
                if modifiers.contains(.shift) { editor.undoManager?.redo() } else { editor.undoManager?.undo() }
            case "y": guard editor.isEditable else { return event }; editor.undoManager?.redo()
            default: return event
            }
            return nil
        }
    }
}
