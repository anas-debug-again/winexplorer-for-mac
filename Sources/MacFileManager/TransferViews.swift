import AppKit
import FileManagerCore

/// Deliberately drawn buttons keep the approved, rectangular appearance on every macOS version.
final class TransferActionButton: NSButton {
    var onOpenMenu: (() -> Void)?
    enum Style { case neutral, primary, destructive }
    private let actionHandler: () -> Void
    private let style: Style
    private let trailingSymbol: String?
    private lazy var hoverState = PointerHoverState(view: self) { [weak self] _ in self?.needsDisplay = true }
    private var hovering: Bool { isEnabled && hoverState.isHovered }

    init(_ title: String, style: Style = .neutral, trailingSymbol: String? = nil,
         handler: @escaping () -> Void) {
        self.style = style
        self.trailingSymbol = trailingSymbol
        actionHandler = handler
        super.init(frame: .zero)
        self.title = title
        font = .systemFont(ofSize: 16)
        isBordered = false
        setButtonType(.momentaryPushIn)
        focusRingType = .none
        target = self
        action = #selector(invoke)
        setAccessibilityLabel(title)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    override var intrinsicContentSize: NSSize {
        NSSize(width: max(76, (title as NSString).size(withAttributes: [.font: font ?? NSFont.systemFont(ofSize: 16)]).width + (trailingSymbol == nil ? 28 : 49)), height: 34)
    }
    override var isEnabled: Bool { didSet { if oldValue != isEnabled { hoverState.reset() }; needsDisplay = true } }
    override var isHighlighted: Bool { didSet { needsDisplay = true } }
    override var acceptsFirstResponder: Bool { isEnabled }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        hoverState.updateTrackingAreas()
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { hoverState.reset() }
    }
    override func mouseDown(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        if isEnabled, trailingSymbol != nil, location.x >= bounds.maxX - 24, let onOpenMenu {
            isHighlighted = true
            onOpenMenu()
            isHighlighted = false
            return
        }
        super.mouseDown(with: event)
    }
    override func keyDown(with event: NSEvent) {
        if isEnabled, event.keyCode == 125, let onOpenMenu { onOpenMenu(); return }
        super.keyDown(with: event)
    }
    override func accessibilityPerformShowMenu() -> Bool {
        guard isEnabled, let onOpenMenu else { return false }
        onOpenMenu(); return true
    }
    override func becomeFirstResponder() -> Bool { needsDisplay = true; return super.becomeFirstResponder() }
    override func resignFirstResponder() -> Bool { needsDisplay = true; return super.resignFirstResponder() }
    @objc private func invoke() { if isEnabled { actionHandler() } }

    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: bounds).addClip()
        defer { NSGraphicsContext.restoreGraphicsState() }
        let focused = window?.firstResponder === self
        let inset: CGFloat = focused ? 2 : 0.75
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: inset, dy: inset), xRadius: 6, yRadius: 6)
        let blue = NSColor(calibratedRed: 0, green: 0.43, blue: 1, alpha: 1)
        let red = NSColor(calibratedRed: 0.84, green: 0.05, blue: 0.08, alpha: 1)
        let fill: NSColor
        let border: NSColor
        let text: NSColor
        if !isEnabled {
            fill = NSColor(white: 0.97, alpha: 1)
            border = NSColor(white: 0.83, alpha: 1)
            text = .disabledControlTextColor
        } else if style == .primary {
            fill = isHighlighted ? blue.blended(withFraction: 0.15, of: .black)! : (hovering ? blue.blended(withFraction: 0.08, of: .black)! : blue)
            border = fill
            text = .white
        } else {
            fill = isHighlighted ? NSColor(white: 0.90, alpha: 1) : (hovering ? NSColor(white: 0.96, alpha: 1) : .white)
            border = style == .destructive ? red.withAlphaComponent(0.55) : NSColor(white: 0.67, alpha: 1)
            text = style == .destructive ? red : NSColor(white: 0.07, alpha: 1)
        }
        fill.setFill(); shape.fill()
        border.setStroke(); shape.lineWidth = 1; shape.stroke()
        if focused {
            blue.withAlphaComponent(0.5).setStroke()
            let focus = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.75, dy: 0.75), xRadius: 7, yRadius: 7)
            focus.lineWidth = 2; focus.stroke()
        }
        let attributes: [NSAttributedString.Key: Any] = [.font: font ?? NSFont.systemFont(ofSize: 16), .foregroundColor: text]
        let textSize = (title as NSString).size(withAttributes: attributes)
        let extra: CGFloat = trailingSymbol == nil ? 0 : 20
        let textX = (bounds.width - textSize.width - extra) / 2
        (title as NSString).draw(at: NSPoint(x: textX, y: (bounds.height - textSize.height) / 2), withAttributes: attributes)
        if let trailingSymbol, let image = NSImage(systemSymbolName: trailingSymbol, accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 11, weight: .medium)) {
            image.draw(in: NSRect(x: textX + textSize.width + 9, y: (bounds.height - 12) / 2, width: 12, height: 12), from: .zero, operation: .sourceOver, fraction: isEnabled ? 1 : 0.35, respectFlipped: true, hints: nil)
        }
    }
}

final class TransferDrawer: NSView, NSMenuItemValidation {
    var onHeightChange: ((CGFloat) -> Void)?
    private let heading = transferLabel("File transfers", size: 18, bold: true)
    private let count = transferLabel("No transfers", size: 17, color: .secondaryLabelColor)
    private let footer = transferLabel("Cancel stops remaining work. Completed transfers are kept.", size: 14, color: .secondaryLabelColor)
    private let headerBackground = NSView()
    private let scroll = NSScrollView()
    private let columns = TransferColumnsView()
    private var cards: [UUID: TransferCard] = [:]
    private var order: [UUID] = []
    private var states: [UUID: TransferPhase] = [:]
    private let onCancel: (UUID) -> Void
    private let onHide: () -> Void
    private let hideButton: TransferActionButton

    init(onCancel: @escaping (UUID) -> Void, onHide: @escaping () -> Void) {
        self.onCancel = onCancel
        self.onHide = onHide
        hideButton = TransferActionButton("Hide", trailingSymbol: "chevron.down", handler: onHide)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.white.cgColor
        setAccessibilityIdentifier("transfer-drawer")
        headerBackground.wantsLayer = true
        headerBackground.layer?.backgroundColor = NSColor(white: 0.975, alpha: 1).cgColor
        addSubview(headerBackground)
        [heading, count, hideButton, footer].forEach(addSubview)
        scroll.hasHorizontalScroller = true
        scroll.hasVerticalScroller = false
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.drawsBackground = false
        scroll.documentView = columns
        addSubview(scroll)
        hideButton.setAccessibilityIdentifier("transfer-hide")
        let menu = NSMenu()
        let hide = NSMenuItem(title: "Hide transfers", action: #selector(hideTransfers), keyEquivalent: "")
        hide.target = self
        menu.addItem(hide)
        menu.addItem(.separator())
        let clear = NSMenuItem(title: "Clear finished transfers", action: #selector(clearFinished), keyEquivalent: "")
        clear.target = self
        menu.addItem(clear)
        self.menu = menu
        hideButton.menu = menu
        hideButton.onOpenMenu = { [weak self] in self?.showDrawerMenu() }
        hideButton.setAccessibilityHelp("Hide transfers. Use the arrow or Down Arrow key to open transfer options.")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 330) }

    override func layout() {
        super.layout()
        headerBackground.frame = NSRect(x: 0, y: 0, width: bounds.width, height: 48)
        heading.frame = NSRect(x: 20, y: 13, width: 145, height: 25)
        count.frame = NSRect(x: 176, y: 14, width: max(80, bounds.width - 310), height: 24)
        hideButton.frame = NSRect(x: max(20, bounds.width - 106), y: 9, width: 86, height: 30)
        footer.frame = NSRect(x: 20, y: bounds.height - 26, width: max(0, bounds.width - 40), height: 22)
        scroll.frame = NSRect(x: 0, y: 49, width: bounds.width, height: max(0, bounds.height - 82))
        let visibleWidth = scroll.contentSize.width
        let width = visibleWidth / (order.count > 1 ? 2 : 1)
        columns.frame = NSRect(x: 0, y: 0, width: max(visibleWidth, CGFloat(order.count) * width), height: scroll.contentSize.height)
        for (index, id) in order.enumerated() {
            cards[id]?.frame = NSRect(x: CGFloat(index) * width, y: 0, width: width, height: columns.bounds.height)
            cards[id]?.showsDivider = index > 0
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: bounds).addClip()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSColor(white: 0.82, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
        NSColor(white: 0.88, alpha: 1).setFill()
        NSRect(x: 0, y: 48, width: bounds.width, height: 1).fill()
        NSRect(x: 20, y: bounds.height - 33, width: max(0, bounds.width - 40), height: 1).fill()
    }

    func update(_ progress: TransferProgress) {
        if cards[progress.id] == nil {
            let id = progress.id
            let card = TransferCard(onCancel: { [weak self] in self?.onCancel(id) })
            cards[id] = card
            order.append(id)
            columns.addSubview(card)
            needsLayout = true
        }
        states[progress.id] = progress.phase
        cards[progress.id]?.update(progress)
        updateCount()
    }

    private func updateCount() {
        let active = states.values.filter { $0 == .preparing || $0 == .transferring || $0 == .waiting }.count
        if active > 0 { count.stringValue = "\(active) active" }
        else if cards.isEmpty { count.stringValue = "No transfers" }
        else { count.stringValue = "\(cards.count) \(cards.count == 1 ? "transfer" : "transfers")" }
    }

    @objc private func hideTransfers() { onHide() }
    private func showDrawerMenu() {
        hideButton.menu?.popUp(positioning: nil, at: NSPoint(x: 0, y: hideButton.bounds.maxY + 3), in: hideButton)
    }
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(clearFinished) {
            return states.values.contains { $0 == .completed || $0 == .cancelled || $0 == .failed }
        }
        return true
    }

    @objc private func clearFinished() {
        let finished = order.filter { states[$0] == .completed || states[$0] == .cancelled || states[$0] == .failed }
        for id in finished {
            cards.removeValue(forKey: id)?.removeFromSuperview()
            states.removeValue(forKey: id)
        }
        order.removeAll { finished.contains($0) }
        updateCount()
        scroll.contentView.scroll(to: .zero)
        needsLayout = true
    }
}

private final class TransferColumnsView: NSView {
    override var isFlipped: Bool { true }
}

private final class TransferProgressBar: NSView {
    var fraction: Double = 0 { didSet { needsDisplay = true } }
    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: bounds).addClip()
        defer { NSGraphicsContext.restoreGraphicsState() }
        let track = NSBezierPath(roundedRect: bounds, xRadius: 5, yRadius: 5)
        NSColor(calibratedRed: 0.85, green: 0.86, blue: 0.89, alpha: 1).setFill()
        track.fill()
        guard fraction > 0 else { return }
        NSGraphicsContext.saveGraphicsState()
        track.addClip()
        NSColor(calibratedRed: 0, green: 0.46, blue: 1, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: bounds.width * min(1, max(0, fraction)), height: bounds.height), xRadius: 5, yRadius: 5).fill()
        NSGraphicsContext.restoreGraphicsState()
    }
}

private final class TransferCard: NSView {
    var showsDivider = false { didSet { needsDisplay = true } }
    private let icon = NSImageView()
    private let heading = transferLabel("Preparing…", size: 20, bold: true)
    private let fromLabel = transferLabel("From", size: 16)
    private let toLabel = transferLabel("To", size: 16)
    private let source = transferLabel("", size: 16)
    private let destination = transferLabel("", size: 16)
    private let current = transferLabel("", size: 16)
    private let progress = TransferProgressBar()
    private let percent = transferLabel("0%", size: 16)
    private let detail = transferLabel("", size: 16)
    private let speed = transferLabel("", size: 16)
    private let cancelButton: TransferActionButton
    private var sourceIsDirectory: Bool?

    init(onCancel: @escaping () -> Void) {
        cancelButton = TransferActionButton("Cancel copy", handler: onCancel)
        super.init(frame: .zero)
        [icon, heading, fromLabel, toLabel, source, destination, current, progress, percent, detail, speed, cancelButton].forEach(addSubview)
        icon.contentTintColor = NSColor(white: 0.06, alpha: 1)
        percent.alignment = .right
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    override var isFlipped: Bool { true }
    override func layout() {
        super.layout()
        let inset: CGFloat = 26
        let width = max(0, bounds.width - 2 * inset)
        icon.frame = NSRect(x: inset, y: 13, width: 26, height: 26)
        heading.frame = NSRect(x: inset + 44, y: 12, width: max(0, width - 44), height: 28)
        fromLabel.frame = NSRect(x: inset, y: 49, width: 76, height: 21)
        toLabel.frame = NSRect(x: inset, y: 74, width: 76, height: 21)
        source.frame = NSRect(x: inset + 87, y: 49, width: max(0, width - 87), height: 21)
        destination.frame = NSRect(x: inset + 87, y: 74, width: max(0, width - 87), height: 21)
        current.frame = NSRect(x: inset, y: 103, width: width, height: 21)
        progress.frame = NSRect(x: inset, y: 136, width: max(0, width - 52), height: 10)
        percent.frame = NSRect(x: inset + max(0, width - 47), y: 130, width: 47, height: 22)
        detail.frame = NSRect(x: inset, y: 157, width: width, height: 21)
        speed.frame = NSRect(x: inset, y: 182, width: width, height: 21)
        cancelButton.frame = NSRect(x: inset, y: 212, width: 134, height: 33)
    }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: bounds).addClip()
        defer { NSGraphicsContext.restoreGraphicsState() }
        if showsDivider {
            NSColor(white: 0.84, alpha: 1).setFill()
            NSRect(x: 0, y: 10, width: 1, height: max(0, bounds.height - 20)).fill()
        }
    }
    func update(_ value: TransferProgress) {
        let copying = value.kind == .copy
        let terminal = value.phase == .completed || value.phase == .cancelled || value.phase == .failed
        let action = copying ? "Copying" : "Moving"
        let files = value.totalFiles == 1 ? "1 file" : "\(value.totalFiles) files"
        heading.stringValue = value.totalFiles > 0 ? "\(action) \(files)" : "\(action) items"
        icon.image = NSImage(systemSymbolName: copying ? "doc.on.doc" : "arrow.right.square", accessibilityDescription: copying ? "Copy" : "Move")?.withSymbolConfiguration(.init(pointSize: 23, weight: .regular))
        let only = value.sources.count == 1 ? value.sources.first : nil
        if value.sourceDirectoryFlags.count == value.sources.count { sourceIsDirectory = value.sourceDirectoryFlags.first }
        // Directory identity comes from the transfer snapshot, not a source that
        // may already have disappeared after a successful move.
        let onlyIsFolder = only != nil && sourceIsDirectory == true
        let parents = Set(value.sources.map { $0.deletingLastPathComponent().path })
        if let only, onlyIsFolder { source.stringValue = transferCompactPath(only) }
        else if parents.count == 1, let first = value.sources.first { source.stringValue = transferCompactPath(first.deletingLastPathComponent()) }
        else { source.stringValue = "\(parents.count) source locations" }
        source.toolTip = value.sources.map(\.path).joined(separator: "\n")
        let committedTarget = only != nil ? value.committedDestinations.first : nil
        let target = onlyIsFolder ? (committedTarget ?? value.destination.appendingPathComponent(only!.lastPathComponent)) : (committedTarget?.deletingLastPathComponent() ?? value.destination)
        destination.stringValue = transferCompactPath(target)
        destination.toolTip = target.path
        current.stringValue = value.currentFile.isEmpty ? (terminal ? "" : "Preparing items…") : "Current file: \(value.currentFile)"
        current.toolTip = current.stringValue
        let fraction = value.totalBytes > 0 ? Double(value.completedBytes) / Double(value.totalBytes) : (value.phase == .completed ? 1 : 0)
        progress.fraction = fraction
        percent.stringValue = "\(Int(min(1, max(0, fraction)) * 100))%"
        detail.stringValue = "\(byteText(value.completedBytes)) of \(byteText(value.totalBytes)) · \(value.completedFiles) of \(value.totalFiles) files complete"
        switch value.phase {
        case .preparing:
            heading.stringValue = copying ? "Preparing copy…" : "Preparing move…"
            speed.stringValue = "Calculating transfer size…"
        case .transferring:
            let remaining = value.remainingSeconds.map { seconds in
                let count = Int(max(1, seconds))
                return " · About \(count) second\(count == 1 ? "" : "s") left"
            } ?? ""
            speed.stringValue = value.bytesPerSecond > 0 ? "\(byteText(Int64(value.bytesPerSecond)))/s\(remaining)" : "Transferring…"
        case .waiting: speed.stringValue = "Waiting for your choice"
        case .completed:
            heading.stringValue = copying ? "Copy complete" : "Move complete"
            speed.stringValue = value.message ?? "Completed"
        case .cancelled:
            heading.stringValue = copying ? "Copy cancelled" : "Move cancelled"
            speed.stringValue = "Completed items were kept"
        case .failed:
            heading.stringValue = "Transfer couldn’t finish"
            speed.stringValue = value.message ?? "Unknown error"
        }
        detail.toolTip = detail.stringValue
        speed.toolTip = speed.stringValue
        speed.textColor = value.phase == .failed ? .systemRed : NSColor(white: 0.08, alpha: 1)
        cancelButton.title = copying ? "Cancel copy" : "Cancel move"
        cancelButton.setAccessibilityLabel(cancelButton.title)
        cancelButton.isHidden = terminal
        needsLayout = true
    }
}

/// A custom dialog presented by the window controller's centered, dimmed overlay.
/// Return chooses Keep Both, never Replace. The controller owns modal event routing.
final class ConflictDialogView: NSView {
    private let conflict: FileConflict
    private let moving: Bool
    private let onResolve: (ConflictResolution) -> Void
    private var resolved = false
    private let status: NSTextField
    private let documentIcon: TransferFileIcon
    private let warningBadge = TransferWarningBadge()
    private let heading: NSTextField
    private let subtitle: NSTextField
    private let sourceColumn: ConflictFileColumn
    private let destinationColumn: ConflictFileColumn
    private let choices: [NSTextField]
    private let apply = TransferScopeCheckbox()
    private let note: NSTextField
    private var cancelButton: TransferActionButton!
    private var skipButton: TransferActionButton!
    private var replaceButton: TransferActionButton!
    private var keepBothButton: TransferActionButton!

    init(conflict: FileConflict, moving: Bool, onResolve: @escaping (ConflictResolution) -> Void) {
        self.conflict = conflict
        self.moving = moving
        self.onResolve = onResolve
        let operation = moving ? "move" : "copy"
        let destinationName = conflict.destination.deletingLastPathComponent().lastPathComponent
        let sourceIsFolder = (try? conflict.source.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        let sourceKind = sourceIsFolder ? "Folder" : "File"
        status = transferLabel("\(moving ? "Move" : "Copy") paused — waiting for your choice", size: 15, color: .secondaryLabelColor)
        documentIcon = TransferFileIcon(url: conflict.source)
        heading = transferLabel("“\(conflict.destination.lastPathComponent)” already exists", size: 23, bold: true)
        subtitle = transferLabel("Choose what to do with this \(conflict.isDirectory ? "item" : "file") in \(destinationName).", size: 17)
        sourceColumn = ConflictFileColumn(url: conflict.source, heading: moving ? "\(sourceKind) you’re moving" : "\(sourceKind) you’re copying", locationLabel: "From")
        destinationColumn = ConflictFileColumn(url: conflict.destination, heading: "\(conflict.isDirectory ? "Item" : "File") already in \(destinationName)", locationLabel: "Location")
        choices = [
            Self.choiceLine("Keep Both:", "Save \(moving ? "the moved item" : "the new copy") as \(conflict.suggestedName)."),
            Self.choiceLine("Skip:", moving ? "Keep both items where they are and continue moving." : "Keep the existing \(conflict.isDirectory ? "item" : "file") and continue copying."),
            Self.choiceLine("Replace:", conflict.canReplace ? "Overwrite the file already in \(destinationName)." : "Replacement isn’t available for folders or symbolic links.")
        ]
        note = transferLabel("Cancel \(operation) stops remaining work. \(moving ? "Items already moved" : "Files already copied") stay in \(destinationName).", size: 14, color: .secondaryLabelColor)
        super.init(frame: NSRect(x: 0, y: 0, width: 730, height: 600))
        wantsLayer = true
        layer?.backgroundColor = NSColor.white.cgColor
        layer?.cornerRadius = 14
        layer?.borderWidth = 1
        layer?.borderColor = NSColor(white: 0.72, alpha: 1).cgColor
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.2
        layer?.shadowRadius = 16
        layer?.shadowOffset = NSSize(width: 0, height: -5)
        setAccessibilityRole(.group)
        setAccessibilityLabel("File conflict")
        setAccessibilityIdentifier("file-conflict-dialog")
        heading.toolTip = heading.stringValue
        subtitle.toolTip = subtitle.stringValue
        apply.title = "Apply this choice to remaining file conflicts in this \(operation)"
        apply.font = .systemFont(ofSize: 16)
        apply.state = .off
        apply.isEnabled = !conflict.isDirectory && conflict.canReplace
        apply.setAccessibilityIdentifier("conflict-apply-to-remaining")
        apply.toolTip = "Applies only to compatible file conflicts in this transfer."
        note.toolTip = note.stringValue
        [status, documentIcon, warningBadge, heading, subtitle, sourceColumn, destinationColumn, apply, note].forEach(addSubview)
        choices.forEach(addSubview)
        cancelButton = TransferActionButton("Cancel \(operation)") { [weak self] in self?.cancel() }
        skipButton = TransferActionButton("Skip") { [weak self] in self?.resolve(.skip) }
        replaceButton = TransferActionButton("Replace", style: .destructive) { [weak self] in self?.resolve(.replace) }
        keepBothButton = TransferActionButton("Keep Both", style: .primary) { [weak self] in self?.chooseDefault() }
        replaceButton.isEnabled = conflict.canReplace
        [cancelButton, skipButton, replaceButton, keepBothButton].forEach { addSubview($0!) }
        cancelButton.setAccessibilityIdentifier("conflict-cancel")
        skipButton.setAccessibilityIdentifier("conflict-skip")
        replaceButton.setAccessibilityIdentifier("conflict-replace")
        keepBothButton.setAccessibilityIdentifier("conflict-keep-both")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: 730, height: 600) }
    func cancel() { resolve(.cancel) }
    func chooseDefault() { resolve(.keepBoth) }
    func moveFocus(backwards: Bool) {
        let buttons: [NSView] = [apply, cancelButton, skipButton, replaceButton, keepBothButton].compactMap { $0 }
            .filter { ($0 as? NSControl)?.isEnabled != false }
        guard !buttons.isEmpty, let window else { return }
        let current = buttons.firstIndex { $0 === window.firstResponder }
        let index: Int
        if let current { index = (current + (backwards ? buttons.count - 1 : 1)) % buttons.count }
        else { index = backwards ? buttons.count - 1 : 0 }
        window.makeFirstResponder(buttons[index])
        buttons.forEach { $0.needsDisplay = true }
    }
    private func resolve(_ choice: ConflictChoice) {
        guard !resolved else { return }
        if choice == .replace && !conflict.canReplace { return }
        resolved = true
        onResolve(ConflictResolution(choice: choice, applyToRemaining: choice != .cancel && apply.isEnabled && apply.state == .on))
    }
    override func layout() {
        super.layout()
        let inset: CGFloat = 34
        let inner = max(0, bounds.width - 2 * inset)
        status.frame = NSRect(x: inset, y: 20, width: inner, height: 23)
        documentIcon.frame = NSRect(x: inset, y: 61, width: 48, height: 52)
        warningBadge.frame = NSRect(x: inset + 30, y: 87, width: 27, height: 27)
        heading.frame = NSRect(x: inset + 74, y: 61, width: max(0, inner - 74), height: 32)
        subtitle.frame = NSRect(x: inset + 74, y: 96, width: max(0, inner - 74), height: 24)
        let columnWidth = (inner - 42) / 2
        sourceColumn.frame = NSRect(x: inset, y: 149, width: columnWidth, height: 170)
        destinationColumn.frame = NSRect(x: bounds.midX + 28, y: 149, width: columnWidth, height: 170)
        for (index, line) in choices.enumerated() {
            line.frame = NSRect(x: inset, y: 348 + CGFloat(index) * 28, width: inner, height: 25)
        }
        apply.frame = NSRect(x: inset, y: 454, width: inner, height: 27)
        note.frame = NSRect(x: inset, y: 490, width: inner, height: 24)
        cancelButton.frame = NSRect(x: 24, y: bounds.height - 56, width: 128, height: 34)
        keepBothButton.frame = NSRect(x: bounds.width - 24 - 112, y: bounds.height - 56, width: 112, height: 34)
        replaceButton.frame = NSRect(x: keepBothButton.frame.minX - 14 - 94, y: bounds.height - 56, width: 94, height: 34)
        skipButton.frame = NSRect(x: replaceButton.frame.minX - 14 - 80, y: bounds.height - 56, width: 80, height: 34)
    }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: bounds).addClip()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSColor(white: 0.83, alpha: 1).setFill()
        for y: CGFloat in [135, 330, 440, 526] {
            NSRect(x: 34, y: y, width: max(0, bounds.width - 68), height: 1).fill()
        }
        NSRect(x: bounds.midX, y: 149, width: 1, height: 170).fill()
    }
    private static func choiceLine(_ prefix: String, _ body: String) -> NSTextField {
        let label = transferLabel("", size: 16.5)
        let text = NSMutableAttributedString(string: prefix + " ", attributes: [.font: NSFont.boldSystemFont(ofSize: 16.5), .foregroundColor: NSColor.labelColor])
        text.append(NSAttributedString(string: body, attributes: [.font: NSFont.systemFont(ofSize: 16.5), .foregroundColor: NSColor.labelColor]))
        label.attributedStringValue = text
        label.toolTip = prefix + " " + body
        return label
    }
}

private final class TransferScopeCheckbox: NSButton {
    private lazy var hoverState = PointerHoverState(view: self) { [weak self] _ in self?.needsDisplay = true }
    private var hovering: Bool { isEnabled && hoverState.isHovered }
    override init(frame: NSRect) {
        super.init(frame: frame)
        setButtonType(.switch)
        isBordered = false
        focusRingType = .none
        target = self
        action = #selector(changed)
        setAccessibilityRole(.checkBox)
    }
    convenience init() { self.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    override var acceptsFirstResponder: Bool { isEnabled }
    override var state: NSControl.StateValue { didSet { needsDisplay = true } }
    override var isEnabled: Bool { didSet { if oldValue != isEnabled { hoverState.reset() }; needsDisplay = true } }
    override var isHighlighted: Bool { didSet { needsDisplay = true } }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        hoverState.updateTrackingAreas()
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { hoverState.reset() }
    }
    override func becomeFirstResponder() -> Bool { needsDisplay = true; return super.becomeFirstResponder() }
    override func resignFirstResponder() -> Bool { needsDisplay = true; return super.resignFirstResponder() }
    @objc private func changed() { needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: bounds).addClip()
        defer { NSGraphicsContext.restoreGraphicsState() }
        let box = NSRect(x: 1, y: (bounds.height - 18) / 2, width: 18, height: 18)
        let outline = NSBezierPath(roundedRect: box, xRadius: 3, yRadius: 3)
        let blue = NSColor(calibratedRed: 0, green: 0.43, blue: 1, alpha: 1)
        let fill: NSColor
        if !isEnabled { fill = .white }
        else if state == .on { fill = (isHighlighted || hovering) ? blue.blended(withFraction: isHighlighted ? 0.15 : 0.07, of: .black)! : blue }
        else if isHighlighted { fill = blue.blended(withFraction: 0.87, of: .white)! }
        else if hovering { fill = blue.blended(withFraction: 0.95, of: .white)! }
        else { fill = .white }
        fill.setFill(); outline.fill()
        (isEnabled ? (hovering || isHighlighted ? blue : NSColor(white: 0.57, alpha: 1)) : NSColor(white: 0.80, alpha: 1)).setStroke()
        outline.lineWidth = 1.2; outline.stroke()
        if state == .on {
            let check = NSBezierPath()
            check.move(to: NSPoint(x: box.minX + 4, y: box.midY))
            check.line(to: NSPoint(x: box.minX + 7.5, y: isFlipped ? box.maxY - 5 : box.minY + 5))
            check.line(to: NSPoint(x: box.maxX - 3, y: isFlipped ? box.minY + 4 : box.maxY - 4))
            (isEnabled ? NSColor.white : NSColor.disabledControlTextColor).setStroke()
            check.lineWidth = 2; check.lineCapStyle = .round; check.lineJoinStyle = .round; check.stroke()
        }
        if window?.firstResponder === self {
            blue.withAlphaComponent(0.5).setStroke()
            let focus = NSBezierPath(roundedRect: box.insetBy(dx: -1.5, dy: -1.5), xRadius: 4, yRadius: 4)
            focus.lineWidth = 2; focus.stroke()
        }
        let attributes: [NSAttributedString.Key: Any] = [.font: font ?? NSFont.systemFont(ofSize: 16), .foregroundColor: isEnabled ? NSColor.labelColor : NSColor.disabledControlTextColor]
        let size = (title as NSString).size(withAttributes: attributes)
        (title as NSString).draw(in: NSRect(x: 29, y: (bounds.height - size.height) / 2, width: max(0, bounds.width - 29), height: size.height), withAttributes: attributes)
    }
}

private final class ConflictFileColumn: NSView {
    private let heading: NSTextField
    private let icon: TransferFileIcon
    private let name: NSTextField
    private let labels: [NSTextField]
    private let values: [NSTextField]
    init(url: URL, heading: String, locationLabel: String) {
        self.heading = transferLabel(heading, size: 17, bold: true)
        icon = TransferFileIcon(url: url)
        name = transferLabel(url.lastPathComponent, size: 17)
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let isFolder = attributes?[.type] as? FileAttributeType == .typeDirectory
        let bytes = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "d MMM yyyy, HH:mm"
        let date = (attributes?[.modificationDate] as? Date).map(formatter.string) ?? "Unknown"
        labels = [transferLabel("Size", size: 16.5, color: .secondaryLabelColor), transferLabel("Modified", size: 16.5, color: .secondaryLabelColor), transferLabel(locationLabel, size: 16.5, color: .secondaryLabelColor)]
        values = [transferLabel(isFolder ? "Folder" : byteText(bytes), size: 16.5), transferLabel(date, size: 16.5), transferLabel(transferCompactPath(url.deletingLastPathComponent()), size: 16.5)]
        super.init(frame: .zero)
        [self.heading, icon, name].forEach(addSubview)
        (labels + values).forEach(addSubview)
        self.heading.toolTip = heading
        name.toolTip = url.path
        values[2].toolTip = url.deletingLastPathComponent().path
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    override var isFlipped: Bool { true }
    override func layout() {
        super.layout()
        heading.frame = NSRect(x: 0, y: 0, width: bounds.width, height: 24)
        icon.frame = NSRect(x: 3, y: 36, width: 38, height: 43)
        name.frame = NSRect(x: 62, y: 45, width: max(0, bounds.width - 62), height: 25)
        for index in 0..<3 {
            let y = 91 + CGFloat(index) * 26
            labels[index].frame = NSRect(x: 0, y: y, width: 94, height: 22)
            values[index].frame = NSRect(x: 108, y: y, width: max(0, bounds.width - 108), height: 22)
        }
    }
}

private final class TransferWarningBadge: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: bounds).addClip()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSColor(calibratedRed: 1, green: 0.67, blue: 0.02, alpha: 1).setFill()
        NSBezierPath(ovalIn: bounds.insetBy(dx: 0.5, dy: 0.5)).fill()
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: 22), .foregroundColor: NSColor.white]
        let size = ("!" as NSString).size(withAttributes: attributes)
        ("!" as NSString).draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2 + 1), withAttributes: attributes)
    }
}

private final class TransferFileIcon: NSView {
    private let url: URL
    init(url: URL) { self.url = url; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: bounds).addClip()
        defer { NSGraphicsContext.restoreGraphicsState() }
        let isFolder = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        if isFolder {
            let rect = bounds.insetBy(dx: 2, dy: 8)
            let folder = NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3)
            NSColor(calibratedRed: 0.36, green: 0.76, blue: 1, alpha: 1).setFill(); folder.fill()
            NSColor.systemBlue.setStroke(); folder.lineWidth = 1.3; folder.stroke()
            NSColor.systemBlue.setFill(); NSRect(x: rect.minX + 2, y: rect.minY - 3, width: rect.width * 0.44, height: 4).fill()
            return
        }
        let rect = bounds.insetBy(dx: 4, dy: 2)
        let fold = rect.width * 0.29
        let paper = NSBezierPath()
        paper.move(to: NSPoint(x: rect.minX, y: rect.minY))
        paper.line(to: NSPoint(x: rect.maxX - fold, y: rect.minY))
        paper.line(to: NSPoint(x: rect.maxX, y: rect.minY + fold))
        paper.line(to: NSPoint(x: rect.maxX, y: rect.maxY))
        paper.line(to: NSPoint(x: rect.minX, y: rect.maxY)); paper.close()
        NSColor.white.setFill(); paper.fill()
        NSColor(white: 0.54, alpha: 1).setStroke(); paper.lineWidth = 1.7; paper.stroke()
        let crease = NSBezierPath()
        crease.move(to: NSPoint(x: rect.maxX - fold, y: rect.minY))
        crease.line(to: NSPoint(x: rect.maxX - fold, y: rect.minY + fold))
        crease.line(to: NSPoint(x: rect.maxX, y: rect.minY + fold)); crease.lineWidth = 1.5; crease.stroke()
        if url.pathExtension.lowercased() == "pdf" {
            let mark = NSBezierPath()
            let x = rect.minX, y = rect.minY, w = rect.width, h = rect.height
            mark.move(to: NSPoint(x: x + w * 0.23, y: y + h * 0.78))
            mark.curve(to: NSPoint(x: x + w * 0.55, y: y + h * 0.36), controlPoint1: NSPoint(x: x + w * 0.56, y: y + h * 0.67), controlPoint2: NSPoint(x: x + w * 0.70, y: y + h * 0.29))
            mark.curve(to: NSPoint(x: x + w * 0.70, y: y + h * 0.72), controlPoint1: NSPoint(x: x + w * 0.31, y: y + h * 0.28), controlPoint2: NSPoint(x: x + w * 0.47, y: y + h * 0.72))
            mark.curve(to: NSPoint(x: x + w * 0.20, y: y + h * 0.81), controlPoint1: NSPoint(x: x + w * 0.93, y: y + h * 0.72), controlPoint2: NSPoint(x: x + w * 0.29, y: y + h * 0.59))
            mark.curve(to: NSPoint(x: x + w * 0.32, y: y + h * 0.77), controlPoint1: NSPoint(x: x + w * 0.13, y: y + h * 0.92), controlPoint2: NSPoint(x: x + w * 0.26, y: y + h * 0.87))
            NSColor.systemRed.setStroke(); mark.lineWidth = 1.7; mark.lineCapStyle = .round; mark.lineJoinStyle = .round; mark.stroke()
        } else {
            let ext = url.pathExtension.uppercased()
            let title = ext.isEmpty ? "FILE" : String(ext.prefix(4))
            let font = NSFont.boldSystemFont(ofSize: max(7, rect.width * 0.25))
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.systemBlue]
            let size = (title as NSString).size(withAttributes: attributes)
            (title as NSString).draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY + 2), withAttributes: attributes)
        }
    }
}

private func transferLabel(_ text: String, size: CGFloat, color: NSColor = NSColor(white: 0.08, alpha: 1), bold: Bool = false) -> NSTextField {
    let label = NSTextField(labelWithString: text)
    label.font = bold ? .boldSystemFont(ofSize: size) : .systemFont(ofSize: size)
    label.textColor = color
    label.lineBreakMode = .byTruncatingMiddle
    label.cell?.usesSingleLineMode = true
    label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    return label
}

private func transferCompactPath(_ url: URL) -> String {
    let components = url.standardizedFileURL.pathComponents.filter { $0 != "/" }
    if let volumes = components.firstIndex(of: "Volumes"), volumes + 1 < components.count {
        return components[(volumes + 1)...].joined(separator: " / ")
    }
    for anchor in ["Documents", "Downloads", "Desktop", "Pictures", "Music", "Work SSD"] {
        if let index = components.lastIndex(of: anchor) { return components[index...].joined(separator: " / ") }
    }
    if url.standardizedFileURL.path == FileManager.default.homeDirectoryForCurrentUser.path { return url.lastPathComponent }
    return components.suffix(2).joined(separator: " / ")
}
