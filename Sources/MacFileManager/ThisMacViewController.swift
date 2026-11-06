import AppKit

enum ThisMacVolumeGroup: Int, CaseIterable {
    case internalStorage, removableStorage, networkStorage, otherStorage
    var title: String {
        switch self {
        case .internalStorage: return "Internal drives"
        case .removableStorage: return "Removable & external drives"
        case .networkStorage: return "Network drives"
        case .otherStorage: return "Other mounted volumes"
        }
    }
    var symbol: String {
        switch self {
        case .internalStorage: return "internaldrive"
        case .removableStorage: return "externaldrive"
        case .networkStorage: return "network"
        case .otherStorage: return "externaldrive"
        }
    }
    var emptyText: String {
        switch self {
        case .internalStorage: return "No internal drives are available."
        case .removableStorage: return "No removable or external drives are connected."
        case .networkStorage: return "No network drives are mounted."
        case .otherStorage: return "No other volumes are mounted."
        }
    }
    static func classify(url: URL, isLocal: Bool?, isInternal: Bool?, isRemovable: Bool?, isEjectable: Bool?) -> Self {
        if isLocal == false { return .networkStorage }
        if isInternal == true || url.path == "/" { return .internalStorage }
        if isInternal == false || isRemovable == true || isEjectable == true { return .removableStorage }
        return .otherStorage
    }
}

struct ThisMacVolume {
    let url: URL
    let name: String
    let group: ThisMacVolumeGroup
    let totalBytes: Int64?
    let availableBytes: Int64?
    var isReadOnly = false
    var capacityError: String? = nil
    var normalizedCapacity: (total: Int64, available: Int64)? {
        guard let totalBytes, totalBytes > 0, let availableBytes, availableBytes >= 0 else { return nil }
        return (totalBytes, min(availableBytes, totalBytes))
    }
    var usedFraction: Double? {
        normalizedCapacity.map { 1 - Double($0.available) / Double($0.total) }
    }
    var capacityText: String {
        guard let capacity = normalizedCapacity else { return "Storage information unavailable" }
        let free = ByteCountFormatter.string(fromByteCount: capacity.available, countStyle: .file)
        let total = ByteCountFormatter.string(fromByteCount: capacity.total, countStyle: .file)
        return "\(free) free of \(total)" + (isReadOnly ? " · Read only" : "")
    }
}

struct ThisMacVolumeSnapshot {
    var volumes: [ThisMacVolume]
    var warnings: [String] = []
}

enum ThisMacVolumeReader {
    static func read() throws -> ThisMacVolumeSnapshot {
        let keys: Set<URLResourceKey> = [.volumeNameKey, .volumeIsLocalKey, .volumeIsInternalKey,
            .volumeIsRemovableKey, .volumeIsEjectableKey, .volumeIsBrowsableKey, .volumeIsReadOnlyKey,
            .volumeTotalCapacityKey, .volumeAvailableCapacityKey]
        guard let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: Array(keys), options: [.skipHiddenVolumes]) else {
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileReadUnknownError,
                          userInfo: [NSLocalizedDescriptionKey: "The list of mounted drives could not be read."])
        }
        var volumes: [ThisMacVolume] = []
        var seen = Set<String>()
        for rawURL in urls {
            let url = rawURL.standardizedFileURL
            guard seen.insert(url.path).inserted else { continue }
            do {
                let values = try url.resourceValues(forKeys: keys)
                guard values.volumeIsBrowsable != false else { continue }
                var total = values.volumeTotalCapacity.map(Int64.init)
                var free = values.volumeAvailableCapacity.map(Int64.init)
                if total == nil || free == nil {
                    if let attributes = try? FileManager.default.attributesOfFileSystem(forPath: url.path) {
                        total = total ?? (attributes[.systemSize] as? NSNumber)?.int64Value
                        free = free ?? (attributes[.systemFreeSize] as? NSNumber)?.int64Value
                    }
                }
                let name = values.volumeName ?? (url.path == "/" ? "Startup disk" : url.lastPathComponent)
                let group = ThisMacVolumeGroup.classify(url: url, isLocal: values.volumeIsLocal, isInternal: values.volumeIsInternal,
                    isRemovable: values.volumeIsRemovable, isEjectable: values.volumeIsEjectable)
                volumes.append(ThisMacVolume(url: url, name: name, group: group, totalBytes: total,
                    availableBytes: free, isReadOnly: values.volumeIsReadOnly == true))
            } catch {
                volumes.append(ThisMacVolume(url: url, name: url.path == "/" ? "Startup disk" : url.lastPathComponent,
                    group: .otherStorage, totalBytes: nil, availableBytes: nil, capacityError: error.localizedDescription))
            }
        }
        return ThisMacVolumeSnapshot(volumes: volumes.sorted {
            $0.group != $1.group ? $0.group.rawValue < $1.group.rawValue : $0.name.localizedStandardCompare($1.name) == .orderedAscending
        })
    }
}

private final class ThisMacDocumentView: NSView {
    override var isFlipped: Bool { true }
}

private final class ThisMacCapacityBar: NSView {
    let fraction: Double
    init(fraction: Double, name: String) {
        self.fraction = min(1, max(0, fraction))
        super.init(frame: .zero)
        clipsToBounds = true
        setAccessibilityElement(true); setAccessibilityRole(.progressIndicator)
        setAccessibilityLabel("\(name) storage usage")
        setAccessibilityValue("\(Int((self.fraction * 100).rounded()))% used")
    }
    required init?(coder: NSCoder) { fatalError("Programmatic capacity bar") }
    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedWhite: 0.90, alpha: 1).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 3, yRadius: 3).fill()
        guard fraction > 0 else { return }
        (fraction > 0.9 ? NSColor.systemRed : NSColor.systemBlue).setFill()
        let fill = NSRect(x: bounds.minX, y: bounds.minY, width: bounds.width * fraction, height: bounds.height)
        NSBezierPath(roundedRect: fill, xRadius: 3, yRadius: 3).fill()
    }
}

private final class ThisMacVolumeCard: NSView {
    private let volume: ThisMacVolume
    private let open: () -> Void
    private let activate: () -> Void
    private lazy var hover = PointerHoverState(view: self) { [weak self] _ in self?.needsDisplay = true }
    var volumeURL: URL { volume.url }
    override var acceptsFirstResponder: Bool { true }

    init(volume: ThisMacVolume, activate: @escaping () -> Void, open: @escaping () -> Void) {
        self.volume = volume; self.activate = activate; self.open = open
        super.init(frame: .zero)
        clipsToBounds = true
        setAccessibilityElement(false)
        setAccessibilityIdentifier("thisMacVolume-" + volume.url.path)
        toolTip = volume.url.path
        let icon = NSImageView(image: NSImage(systemSymbolName: volume.group.symbol, accessibilityDescription: nil)!)
        icon.contentTintColor = NSColor(calibratedWhite: 0.32, alpha: 1)
        icon.symbolConfiguration = .init(pointSize: 36, weight: .regular)
        let title = NSTextField(wrappingLabelWithString: volume.name)
        title.font = .systemFont(ofSize: 17, weight: .semibold); title.maximumNumberOfLines = 2
        title.lineBreakMode = .byWordWrapping; title.toolTip = volume.name
        let path = makeLabel(volume.url.path, size: 13, color: .secondaryLabelColor)
        path.toolTip = volume.url.path
        let button = ActionButton("Open") { activate(); open() }
        button.font = .systemFont(ofSize: 14)
        button.setAccessibilityLabel("Open " + volume.name)
        button.setAccessibilityIdentifier("thisMacOpen-" + volume.url.path)
        let capacity = NSTextField(wrappingLabelWithString: volume.capacityText)
        capacity.font = .systemFont(ofSize: 13); capacity.textColor = .secondaryLabelColor
        capacity.maximumNumberOfLines = 2
        capacity.toolTip = volume.capacityError ?? volume.capacityText
        capacity.setAccessibilityIdentifier("thisMacCapacity-" + volume.url.path)
        let bar = ThisMacCapacityBar(fraction: volume.usedFraction ?? 0, name: volume.name)
        bar.isHidden = volume.usedFraction == nil
        for child in [icon, title, path, button, bar, capacity] {
            child.translatesAutoresizingMaskIntoConstraints = false; addSubview(child)
        }
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 145),
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16), icon.topAnchor.constraint(equalTo: topAnchor, constant: 18),
            icon.widthAnchor.constraint(equalToConstant: 40), icon.heightAnchor.constraint(equalToConstant: 40),
            button.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16), button.topAnchor.constraint(equalTo: topAnchor, constant: 18),
            button.heightAnchor.constraint(equalToConstant: 30),
            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 12), title.topAnchor.constraint(equalTo: topAnchor, constant: 17),
            title.trailingAnchor.constraint(equalTo: button.leadingAnchor, constant: -12),
            path.leadingAnchor.constraint(equalTo: title.leadingAnchor), path.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            path.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 5),
            capacity.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16), capacity.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            capacity.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14),
            bar.leadingAnchor.constraint(equalTo: capacity.leadingAnchor), bar.trailingAnchor.constraint(equalTo: capacity.trailingAnchor),
            bar.bottomAnchor.constraint(equalTo: capacity.topAnchor, constant: -8), bar.heightAnchor.constraint(equalToConstant: 7)
        ])
    }
    required init?(coder: NSCoder) { fatalError("Programmatic volume card") }
    override func updateTrackingAreas() { super.updateTrackingAreas(); hover.updateTrackingAreas() }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); if window == nil { hover.reset() } }
    override func becomeFirstResponder() -> Bool { needsDisplay = true; return super.becomeFirstResponder() }
    override func resignFirstResponder() -> Bool { needsDisplay = true; return super.resignFirstResponder() }
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        var candidate: NSView? = hit
        while let current = candidate, current !== self {
            if current is NSButton { return hit }
            candidate = current.superview
        }
        return self
    }
    override func mouseDown(with event: NSEvent) {
        activate(); window?.makeFirstResponder(self)
        if event.clickCount == 2 { open() }
    }
    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.intersection([.command, .control, .option]).isEmpty, [36, 76, 49].contains(event.keyCode) {
            activate(); open(); return
        }
        super.keyDown(with: event)
    }
    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 7, yRadius: 7)
        NSColor(calibratedWhite: hover.isHovered ? 0.975 : 1, alpha: 1).setFill(); shape.fill()
        NSColor(calibratedWhite: 0.82, alpha: 1).setStroke(); shape.lineWidth = 1; shape.stroke()
        if window?.firstResponder === self {
            NSColor.keyboardFocusIndicatorColor.setStroke()
            let ring = NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 6, yRadius: 6)
            ring.lineWidth = 2; ring.stroke()
        }
    }
}

final class ThisMacViewController: NSViewController {
    var onNavigate: ((URL) -> Void)?
    var onActivate: (() -> Void)?
    var selectedURLs: [URL] { [] }
    private let provider: () throws -> ThisMacVolumeSnapshot
    private let queue = DispatchQueue(label: "FileManager.thisMac", qos: .userInitiated, attributes: .concurrent)
    private let scroll = NSScrollView()
    private let sections = NSStackView()
    private let status = NSTextField(wrappingLabelWithString: "Reading mounted drives…")
    private let spinner = NSProgressIndicator()
    private var refreshButton: ActionButton!
    private var snapshot: ThisMacVolumeSnapshot?
    private var generation = 0
    private var columnCount = 1
    private var volumeCards: [ThisMacVolumeCard] = []
    private var observers: [NSObjectProtocol] = []

    init(provider: @escaping () throws -> ThisMacVolumeSnapshot = ThisMacVolumeReader.read) {
        self.provider = provider; super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("Programmatic This Mac overview") }
    deinit { for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) } }
    override func loadView() {
        view = NSView(); view.wantsLayer = true; view.clipsToBounds = true
        view.layer?.backgroundColor = NSColor(calibratedWhite: 0.975, alpha: 1).cgColor
        view.setAccessibilityIdentifier("thisMacOverview")
        let heading = makeLabel("This Mac", size: 25, bold: true)
        let subtitle = makeLabel("Mounted drives and available storage", size: 14, color: .secondaryLabelColor)
        refreshButton = ActionButton("Refresh", symbol: "arrow.clockwise") { [weak self] in self?.onActivate?(); self?.refresh() }
        refreshButton.font = .systemFont(ofSize: 14); refreshButton.setAccessibilityIdentifier("thisMacRefresh")
        spinner.style = .spinning; spinner.controlSize = .small; spinner.isDisplayedWhenStopped = false
        status.font = .systemFont(ofSize: 13); status.textColor = .secondaryLabelColor; status.maximumNumberOfLines = 3
        status.setAccessibilityIdentifier("thisMacStatus")
        for child in [heading, subtitle, refreshButton!, spinner, status, scroll] {
            child.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(child)
        }
        scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true; scroll.drawsBackground = false
        let document = ThisMacDocumentView(); document.translatesAutoresizingMaskIntoConstraints = false
        sections.orientation = .vertical; sections.alignment = .leading; sections.distribution = .fill
        sections.spacing = 20; sections.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(sections); scroll.documentView = document
        NSLayoutConstraint.activate([
            heading.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24), heading.topAnchor.constraint(equalTo: view.topAnchor, constant: 22),
            heading.trailingAnchor.constraint(lessThanOrEqualTo: refreshButton.leadingAnchor, constant: -12),
            refreshButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            refreshButton.centerYAnchor.constraint(equalTo: heading.centerYAnchor), refreshButton.heightAnchor.constraint(equalToConstant: 34),
            subtitle.leadingAnchor.constraint(equalTo: heading.leadingAnchor), subtitle.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            subtitle.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 5),
            spinner.leadingAnchor.constraint(equalTo: heading.leadingAnchor), spinner.topAnchor.constraint(equalTo: subtitle.bottomAnchor, constant: 13),
            spinner.widthAnchor.constraint(equalToConstant: 14), spinner.heightAnchor.constraint(equalToConstant: 14),
            status.leadingAnchor.constraint(equalTo: spinner.trailingAnchor, constant: 7), status.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            status.topAnchor.constraint(equalTo: spinner.topAnchor),
            scroll.topAnchor.constraint(equalTo: status.bottomAnchor, constant: 18), scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor), document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            sections.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 24), sections.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -24),
            sections.topAnchor.constraint(equalTo: document.topAnchor), sections.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -24)
        ])
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification] {
            observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.refresh() })
        }
        refresh()
    }
    override func viewDidLayout() {
        super.viewDidLayout()
        let desired = scroll.contentSize.width >= 740 ? 2 : 1
        if columnCount != desired { columnCount = desired; renderSections() }
    }
    func focusContents() {
        onActivate?()
        guard isViewLoaded else { return }
        view.window?.makeFirstResponder(volumeCards.first ?? refreshButton)
    }
    func refresh() {
        guard isViewLoaded else { return }
        generation += 1
        let request = generation, read = provider
        spinner.startAnimation(nil); status.stringValue = "Reading mounted drives…"; status.textColor = .secondaryLabelColor
        queue.async { [weak self] in
            let result = Result { try read() }
            DispatchQueue.main.async { [weak self] in
                guard let self, request == self.generation else { return }
                self.spinner.stopAnimation(nil)
                switch result {
                case .success(let snapshot):
                    self.snapshot = snapshot
                    let count = snapshot.volumes.count
                    let countText = "\(count) " + (count == 1 ? "drive" : "drives")
                    self.status.stringValue = snapshot.warnings.isEmpty ? countText : countText + " · " + snapshot.warnings.joined(separator: " ")
                    self.status.textColor = snapshot.warnings.isEmpty ? .secondaryLabelColor : .systemOrange
                    self.renderSections()
                case .failure(let error):
                    self.status.stringValue = "Couldn’t refresh drives. \(error.localizedDescription)" + (self.snapshot == nil ? "" : " Showing the last available information.")
                    self.status.textColor = .systemRed
                }
            }
        }
    }
    private func renderSections() {
        guard let snapshot else { return }
        let origin = scroll.contentView.bounds.origin
        let focusedURL = (view.window?.firstResponder as? ThisMacVolumeCard)?.volumeURL
        volumeCards.removeAll()
        for child in sections.arrangedSubviews { sections.removeArrangedSubview(child); child.removeFromSuperview() }
        for group in ThisMacVolumeGroup.allCases {
            let volumes = snapshot.volumes.filter { $0.group == group }
            if group == .otherStorage && volumes.isEmpty { continue }
            let section = NSStackView(); section.orientation = .vertical; section.alignment = .leading
            section.distribution = .fill; section.spacing = 10
            let title = makeLabel(group.title, size: 17, bold: true)
            title.setAccessibilityIdentifier("thisMacSection-\(group.rawValue)")
            section.addArrangedSubview(title)
            if volumes.isEmpty {
                let empty = NSTextField(wrappingLabelWithString: group.emptyText)
                empty.font = .systemFont(ofSize: 14); empty.textColor = .secondaryLabelColor
                section.addArrangedSubview(empty); empty.widthAnchor.constraint(equalTo: section.widthAnchor).isActive = true
            } else {
                for start in stride(from: 0, to: volumes.count, by: columnCount) {
                    let row = NSStackView(); row.orientation = .horizontal; row.distribution = .fillEqually; row.spacing = 12
                    for volume in volumes[start..<min(start + columnCount, volumes.count)] {
                        let card = ThisMacVolumeCard(volume: volume, activate: { [weak self] in self?.onActivate?() },
                            open: { [weak self] in self?.onNavigate?(volume.url) })
                        volumeCards.append(card)
                        row.addArrangedSubview(card)
                    }
                    if row.arrangedSubviews.count < columnCount { row.addArrangedSubview(NSView()) }
                    section.addArrangedSubview(row); row.widthAnchor.constraint(equalTo: section.widthAnchor).isActive = true
                }
            }
            sections.addArrangedSubview(section); section.widthAnchor.constraint(equalTo: sections.widthAnchor).isActive = true
        }
        sections.layoutSubtreeIfNeeded()
        let maxY = max(0, (scroll.documentView?.bounds.height ?? 0) - scroll.contentSize.height)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: min(origin.y, maxY)))
        scroll.reflectScrolledClipView(scroll.contentView)
        if let focusedURL, let replacement = volumeCards.first(where: { $0.volumeURL == focusedURL }) {
            view.window?.makeFirstResponder(replacement)
        }
    }
}
