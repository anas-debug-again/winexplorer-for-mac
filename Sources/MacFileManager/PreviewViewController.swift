import AppKit
import Quartz
import UniformTypeIdentifiers

private final class FilePreviewItem: NSObject, QLPreviewItem {
    let previewItemURL: URL?
    var previewItemTitle: String? { previewItemURL?.lastPathComponent }
    init(url: URL) { previewItemURL = url }
}

private final class FilePreviewDocumentView: NSView {
    override var isFlipped: Bool { true }
}

private class PreviewHoverButton: NSButton {
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
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 5, yRadius: 5)
        path.lineWidth = 2; path.stroke()
    }
}

private final class PreviewCloseButton: PreviewHoverButton {
    override func draw(_ dirtyRect: NSRect) {
        if hovered || cell?.isHighlighted == true {
            NSColor(calibratedWhite: cell?.isHighlighted == true ? 0.87 : 0.94, alpha: 1).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 1), xRadius: 5, yRadius: 5).fill()
        }
        super.draw(dirtyRect); drawKeyboardFocus()
    }
}

private final class PreviewOutlineButton: PreviewHoverButton {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false; setButtonType(.momentaryPushIn); clipsToBounds = true
        font = .systemFont(ofSize: 18)
    }
    required init?(coder: NSCoder) { fatalError("Programmatic button") }
    override var intrinsicContentSize: NSSize { NSSize(width: 145, height: 36) }
    override func draw(_ dirtyRect: NSRect) {
        let outline = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
        NSColor(calibratedWhite: cell?.isHighlighted == true ? 0.90 : (hovered && isEnabled ? 0.96 : 1), alpha: 1).setFill(); outline.fill()
        NSColor(calibratedWhite: 0.73, alpha: 1).setStroke(); outline.lineWidth = 1; outline.stroke()
        let attributes: [NSAttributedString.Key: Any] = [.font: font ?? NSFont.systemFont(ofSize: 18), .foregroundColor: isEnabled ? NSColor.black : NSColor.secondaryLabelColor]
        let size = title.size(withAttributes: attributes)
        title.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2), withAttributes: attributes)
        drawKeyboardFocus()
    }
}

private struct PreviewFileSignature: Equatable {
    let identifier: String?
    let size: Int?
    let modified: Date?
    let isDirectory: Bool
    let isLink: Bool
    let isAlias: Bool
}

final class PreviewViewController: NSViewController {
    var onClose: (() -> Void)?
    var onOpen: ((URL) -> Void)?
    private let body = NSStackView()
    private let scroll = NSScrollView()
    private let emptyLabel = NSTextField(wrappingLabelWithString: "Select a file to preview")
    private let fileName = NSTextField(wrappingLabelWithString: "")
    private let kind = NSTextField(labelWithString: "")
    private let sizeValue = NSTextField(labelWithString: "")
    private let modifiedValue = NSTextField(wrappingLabelWithString: "")
    private let locationValue = NSTextField(wrappingLabelWithString: "")
    private let icon = NSImageView()
    private let previewContainer = NSView()
    private let pageSurface = NSView()
    private let openButton = PreviewOutlineButton(frame: .zero)
    private var quickLook: QLPreviewView?
    private var previewItem: FilePreviewItem?
    private var currentURL: URL?
    private var displayedURL: URL?
    private var metadataSignature: PreviewFileSignature?
    private var metadataTask: DispatchWorkItem?
    private var metadataGeneration = 0
    private let metadataQueue = DispatchQueue(label: "FileManager.preview", qos: .userInitiated, attributes: .concurrent)

    init() { super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.white.cgColor
        view.setAccessibilityIdentifier("filePreview")
        let header = NSTextField(labelWithString: "Preview")
        header.font = .systemFont(ofSize: 17, weight: .bold)
        header.textColor = .black
        let close = PreviewCloseButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close preview")!, target: self, action: #selector(closePreview))
        close.bezelStyle = .inline
        close.isBordered = false
        close.contentTintColor = .black
        close.toolTip = "Close preview"
        close.setAccessibilityIdentifier("closePreview")
        let headerRow = NSStackView(views: [header, NSView(), close])
        headerRow.orientation = .horizontal
        headerRow.alignment = .centerY
        headerRow.distribution = .fill
        headerRow.spacing = 6
        headerRow.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(headerRow)

        body.orientation = .vertical
        body.alignment = .leading
        body.spacing = 10
        body.translatesAutoresizingMaskIntoConstraints = false
        let document = FilePreviewDocumentView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(body)
        scroll.documentView = document
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll)
        emptyLabel.font = .systemFont(ofSize: 17)
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(emptyLabel)

        previewContainer.translatesAutoresizingMaskIntoConstraints = false
        previewContainer.heightAnchor.constraint(equalToConstant: 301).isActive = true
        pageSurface.translatesAutoresizingMaskIntoConstraints = false
        pageSurface.wantsLayer = true
        pageSurface.layer?.backgroundColor = NSColor.white.cgColor
        pageSurface.layer?.cornerRadius = 4
        pageSurface.layer?.borderWidth = 1
        pageSurface.layer?.borderColor = NSColor(calibratedWhite: 0.78, alpha: 1).cgColor
        pageSurface.layer?.shadowColor = NSColor.black.cgColor
        pageSurface.layer?.shadowOpacity = 0.10
        pageSurface.layer?.shadowRadius = 5
        pageSurface.layer?.shadowOffset = NSSize(width: 0, height: -2)
        previewContainer.addSubview(pageSurface)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        pageSurface.addSubview(icon)
        NSLayoutConstraint.activate([
            pageSurface.centerXAnchor.constraint(equalTo: previewContainer.centerXAnchor),
            pageSurface.topAnchor.constraint(equalTo: previewContainer.topAnchor, constant: 8),
            pageSurface.widthAnchor.constraint(equalToConstant: 225),
            pageSurface.heightAnchor.constraint(equalToConstant: 285),
            icon.centerXAnchor.constraint(equalTo: pageSurface.centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: pageSurface.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 110),
            icon.heightAnchor.constraint(equalToConstant: 110)
        ])
        body.addArrangedSubview(previewContainer)
        body.setCustomSpacing(14, after: previewContainer)
        fileName.font = .systemFont(ofSize: 20, weight: .bold)
        fileName.textColor = .black
        fileName.maximumNumberOfLines = 2
        fileName.lineBreakMode = .byTruncatingMiddle
        kind.font = .systemFont(ofSize: 17)
        kind.textColor = .secondaryLabelColor
        kind.lineBreakMode = .byTruncatingTail
        body.addArrangedSubview(fileName)
        body.addArrangedSubview(kind)
        body.setCustomSpacing(3, after: fileName)
        body.setCustomSpacing(17, after: kind)
        body.addArrangedSubview(makeSeparator())
        for (title, value) in [("Size", sizeValue), ("Modified", modifiedValue), ("Location", locationValue)] {
            let label = NSTextField(labelWithString: title)
            label.font = .systemFont(ofSize: 17)
            label.textColor = .black
            label.widthAnchor.constraint(equalToConstant: 92).isActive = true
            value.font = .systemFont(ofSize: 17)
            value.textColor = .black
            value.maximumNumberOfLines = title == "Location" ? 2 : 1
            value.lineBreakMode = .byTruncatingMiddle
            value.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            let row = NSStackView(views: [label, value])
            row.orientation = .horizontal
            row.distribution = .fill
            row.alignment = .top
            row.spacing = 8
            body.addArrangedSubview(row)
        }
        body.addArrangedSubview(makeSeparator())
        openButton.target = self
        openButton.action = #selector(openFile)
        openButton.title = "Open"
        openButton.setAccessibilityIdentifier("openPreviewFile")
        let openRow = NSView()
        openRow.heightAnchor.constraint(equalToConstant: 49).isActive = true
        openButton.translatesAutoresizingMaskIntoConstraints = false
        openRow.addSubview(openButton)
        NSLayoutConstraint.activate([
            openButton.centerXAnchor.constraint(equalTo: openRow.centerXAnchor),
            openButton.topAnchor.constraint(equalTo: openRow.topAnchor, constant: 10),
            openButton.widthAnchor.constraint(equalToConstant: 145),
            openButton.heightAnchor.constraint(equalToConstant: 36)
        ])
        body.addArrangedSubview(openRow)
        NSLayoutConstraint.activate([
            headerRow.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            headerRow.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -18),
            headerRow.topAnchor.constraint(equalTo: view.topAnchor, constant: 10),
            headerRow.heightAnchor.constraint(equalToConstant: 29),
            close.widthAnchor.constraint(equalToConstant: 22),
            close.heightAnchor.constraint(equalToConstant: 26),
            scroll.topAnchor.constraint(equalTo: headerRow.bottomAnchor, constant: 4),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            body.topAnchor.constraint(equalTo: document.topAnchor, constant: 12),
            body.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 20),
            body.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -20),
            body.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -16),
            previewContainer.widthAnchor.constraint(equalTo: body.widthAnchor),
            fileName.widthAnchor.constraint(equalTo: body.widthAnchor),
            kind.widthAnchor.constraint(equalTo: body.widthAnchor),
            emptyLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            emptyLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            emptyLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])
        for child in body.arrangedSubviews {
            child.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true
        }
        show(url: currentURL)
    }

    deinit { metadataTask?.cancel(); quickLook?.close() }

    func show(url: URL?) {
        let url = url?.standardizedFileURL
        currentURL = url
        guard isViewLoaded else { return }
        metadataTask?.cancel()
        metadataGeneration += 1
        let generation = metadataGeneration
        guard let url else {
            clearPreview()
            displayedURL = nil
            scroll.isHidden = true
            emptyLabel.stringValue = "Select a file to preview"
            emptyLabel.isHidden = false
            return
        }
        scroll.isHidden = false
        emptyLabel.isHidden = true
        if displayedURL != url {
            clearPreview()
            displayedURL = url
            scroll.contentView.scroll(to: .zero)
            scroll.reflectScrolledClipView(scroll.contentView)
            fileName.stringValue = AppShortcutDocument.isShortcut(url) ? url.deletingPathExtension().lastPathComponent : url.lastPathComponent
            fileName.toolTip = url.path
            kind.stringValue = "Loading…"
            sizeValue.stringValue = "—"
            modifiedValue.stringValue = "—"
            locationValue.stringValue = compactLocation(url.deletingLastPathComponent())
            locationValue.toolTip = url.deletingLastPathComponent().path
            icon.image = NSWorkspace.shared.icon(for: .data)
            icon.isHidden = false
            openButton.isEnabled = true
        }

        let task = DispatchWorkItem { [weak self] in
            var metadataURL = url
            metadataURL.removeAllCachedResourceValues()
            let values = try? metadataURL.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey, .isSymbolicLinkKey, .isAliasFileKey, .fileSizeKey, .contentModificationDateKey, .localizedTypeDescriptionKey, .contentTypeKey, .fileResourceIdentifierKey])
            DispatchQueue.main.async { [weak self] in
                guard let self, generation == self.metadataGeneration else { return }
                self.metadataTask = nil
                guard let values else {
                    self.clearPreview()
                    self.kind.stringValue = "Preview unavailable"
                    self.sizeValue.stringValue = "—"; self.modifiedValue.stringValue = "—"
                    return
                }
                let signature = PreviewFileSignature(identifier: values.fileResourceIdentifier.map { String(describing: $0) }, size: values.fileSize,
                    modified: values.contentModificationDate, isDirectory: values.isDirectory == true, isLink: values.isSymbolicLink == true,
                    isAlias: AppShortcutDocument.isShortcut(url) || (values.isAliasFile == true && values.isSymbolicLink != true))
                let changed = signature != self.metadataSignature
                self.metadataSignature = signature
                self.kind.stringValue = signature.isAlias ? "Shortcut" : (values.localizedTypeDescription ?? (values.isDirectory == true ? "Folder" : "File"))
                self.sizeValue.stringValue = values.isDirectory == true ? "—" : ByteCountFormatter.string(fromByteCount: Int64(values.fileSize ?? 0), countStyle: .file)
                if let date = values.contentModificationDate {
                    let formatter = DateFormatter()
                    formatter.dateFormat = "d MMM yyyy"
                    self.modifiedValue.stringValue = formatter.string(from: date)
                } else { self.modifiedValue.stringValue = "—" }
                if changed { self.icon.image = ShortcutSupport.icon(for: url, size: 110) }
                // Avoid opening folder/package contents or following symlinks merely
                // because a row is selected. Quick Look handles ordinary files.
                if changed && values.isDirectory != true && values.isSymbolicLink != true && !signature.isAlias {
                    self.installQuickLook(url: url)
                } else if values.isDirectory == true || values.isSymbolicLink == true || signature.isAlias {
                    self.quickLook?.previewItem = nil; self.quickLook?.isHidden = true; self.icon.isHidden = false
                }
            }
        }
        metadataTask = task
        metadataQueue.asyncAfter(deadline: .now() + 0.12, execute: task)
    }

    private func clearPreview() {
        quickLook?.previewItem = nil; quickLook?.isHidden = true
        previewItem = nil; metadataSignature = nil; icon.isHidden = false
    }

    private func installQuickLook(url: URL) {
        if let quickLook {
            let item = FilePreviewItem(url: url); previewItem = item
            quickLook.previewItem = item; quickLook.isHidden = false; icon.isHidden = true
            return
        }
        guard let preview = QLPreviewView(frame: .zero, style: .compact) else { return }
        preview.translatesAutoresizingMaskIntoConstraints = false
        preview.autostarts = false
        preview.clipsToBounds = true
        preview.shouldCloseWithWindow = false
        let item = FilePreviewItem(url: url)
        previewItem = item
        preview.previewItem = item
        pageSurface.addSubview(preview)
        NSLayoutConstraint.activate([
            preview.leadingAnchor.constraint(equalTo: pageSurface.leadingAnchor, constant: 1),
            preview.trailingAnchor.constraint(equalTo: pageSurface.trailingAnchor, constant: -1),
            preview.topAnchor.constraint(equalTo: pageSurface.topAnchor, constant: 1),
            preview.bottomAnchor.constraint(equalTo: pageSurface.bottomAnchor, constant: -1)
        ])
        quickLook = preview
        icon.isHidden = true
    }

    private func makeSeparator() -> NSBox {
        let separator = NSBox()
        separator.boxType = .separator
        separator.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return separator
    }

    private func compactLocation(_ url: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser
        if url.standardizedFileURL == home.standardizedFileURL { return home.lastPathComponent }
        let components = url.pathComponents.filter { $0 != "/" }
        if components.count <= 2 { return components.joined(separator: " / ") }
        if url.deletingLastPathComponent().standardizedFileURL == home.standardizedFileURL { return url.lastPathComponent }
        return components.suffix(2).joined(separator: " / ")
    }

    @objc private func closePreview() { onClose?() }
    @objc private func openFile() {
        guard let url = currentURL else { return }
        onOpen?(url)
    }
}
