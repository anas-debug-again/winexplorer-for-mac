import AppKit

/// Edits a local draft. Only Apply and OK publish preferences to the owner.
final class ExplorerOptionsWindowController: NSWindowController, NSWindowDelegate, NSTextFieldDelegate {
    var onApply: ((ExplorerPreferences) -> Void)?
    var onClose: (() -> Void)?

    private var applied: ExplorerPreferences
    private let startup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let customPath = NSTextField(string: "")
    private let defaultView = NSPopUpButton(frame: .zero, pullsDown: false)
    private let showExtensions = NSButton(checkboxWithTitle: "Show file name extensions", target: nil, action: nil)
    private let showHidden = NSButton(checkboxWithTitle: "Show hidden files and folders", target: nil, action: nil)
    private let compact = NSButton(checkboxWithTitle: "Use compact spacing", target: nil, action: nil)
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private var browseButton: ActionButton!
    private var applyButton: ActionButton!
    private var tabs: [ActionButton] = []
    private var pages: [NSView] = []
    private var keyMonitor: Any?
    private var isClosed = false

    init(preferences: ExplorerPreferences) {
        applied = preferences.normalized()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 452),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "WinExplorer for Mac Options"
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.identifier = NSUserInterfaceItemIdentifier("explorerOptionsWindow")
        super.init(window: window)
        window.delegate = self
        buildInterface()
        populate(applied)
        selectTab(0)
        window.center()
        installKeyboardShortcuts()
    }
    required init?(coder: NSCoder) { fatalError("Programmatic options window") }
    deinit { if let keyMonitor { NSEvent.removeMonitor(keyMonitor) } }

    private func buildInterface() {
        guard let window else { return }
        let root = NSView(); root.wantsLayer = true
        root.layer?.backgroundColor = NSColor(calibratedWhite: 0.965, alpha: 1).cgColor
        window.contentView = root
        let heading = makeLabel("WinExplorer for Mac Options", size: 20)
        heading.font = .systemFont(ofSize: 20, weight: .semibold)
        let subtitle = makeLabel("Choose how folders open and how files appear.", size: 13, color: .secondaryLabelColor)
        let tabBar = NSStackView(); tabBar.orientation = .horizontal; tabBar.spacing = 5; tabBar.distribution = .fill
        for (index, title) in ["General", "View"].enumerated() {
            let button = ActionButton(title) { [weak self] in self?.selectTab(index) }
            button.font = .systemFont(ofSize: 15)
            button.heightAnchor.constraint(equalToConstant: 33).isActive = true
            button.setAccessibilityIdentifier("optionsTab" + title)
            tabs.append(button); tabBar.addArrangedSubview(button)
        }
        tabBar.addArrangedSubview(NSView())
        let host = NSView(); host.wantsLayer = true
        host.layer?.backgroundColor = NSColor.white.cgColor
        host.layer?.borderWidth = 1; host.layer?.borderColor = NSColor(calibratedWhite: 0.82, alpha: 1).cgColor
        host.layer?.cornerRadius = 5; host.clipsToBounds = true
        buildGeneral(makePage(in: host)); buildView(makePage(in: host))
        errorLabel.font = .systemFont(ofSize: 13); errorLabel.textColor = .systemRed
        errorLabel.maximumNumberOfLines = 2; errorLabel.isSelectable = true
        errorLabel.setAccessibilityIdentifier("optionsError")
        let actions = NSStackView(); actions.orientation = .horizontal; actions.alignment = .centerY
        actions.distribution = .fill; actions.spacing = 8
        let restore = ActionButton("Restore defaults") { [weak self] in self?.populate(ExplorerPreferences()) }
        restore.setAccessibilityIdentifier("optionsRestoreDefaults")
        let ok = ActionButton("OK") { [weak self] in self?.apply(closeAfter: true) }
        let cancel = ActionButton("Cancel") { [weak self] in self?.close() }
        applyButton = ActionButton("Apply") { [weak self] in self?.apply(closeAfter: false) }
        for (title, button) in [("OK", ok), ("Cancel", cancel), ("Apply", applyButton!)] {
            button.setContentHuggingPriority(.defaultLow, for: .horizontal)
            button.widthAnchor.constraint(equalToConstant: 82).isActive = true
            button.setAccessibilityIdentifier("options" + title)
        }
        for button in [restore, ok, cancel, applyButton!] {
            button.font = .systemFont(ofSize: 14)
            button.heightAnchor.constraint(equalToConstant: 34).isActive = true
        }
        actions.addArrangedSubview(restore); actions.addArrangedSubview(NSView())
        actions.addArrangedSubview(ok); actions.addArrangedSubview(cancel); actions.addArrangedSubview(applyButton)
        ok.keyEquivalent = "\r"; window.defaultButtonCell = ok.cell as? NSButtonCell
        cancel.keyEquivalent = "\u{1b}"
        for view in [heading, subtitle, tabBar, host, errorLabel, actions] {
            view.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(view)
        }
        NSLayoutConstraint.activate([
            heading.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 22),
            heading.topAnchor.constraint(equalTo: root.topAnchor, constant: 20),
            subtitle.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            subtitle.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 5),
            tabBar.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),
            tabBar.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -18),
            tabBar.topAnchor.constraint(equalTo: subtitle.bottomAnchor, constant: 17),
            tabBar.heightAnchor.constraint(equalToConstant: 33),
            host.leadingAnchor.constraint(equalTo: tabBar.leadingAnchor), host.trailingAnchor.constraint(equalTo: tabBar.trailingAnchor),
            host.topAnchor.constraint(equalTo: tabBar.bottomAnchor, constant: 8),
            host.bottomAnchor.constraint(equalTo: errorLabel.topAnchor, constant: -10),
            errorLabel.leadingAnchor.constraint(equalTo: tabBar.leadingAnchor), errorLabel.trailingAnchor.constraint(equalTo: tabBar.trailingAnchor),
            errorLabel.heightAnchor.constraint(equalToConstant: 34),
            errorLabel.bottomAnchor.constraint(equalTo: actions.topAnchor, constant: -7),
            actions.leadingAnchor.constraint(equalTo: tabBar.leadingAnchor), actions.trailingAnchor.constraint(equalTo: tabBar.trailingAnchor),
            actions.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16)
        ])
    }

    private func makePage(in host: NSView) -> NSStackView {
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading
        stack.distribution = .fill; stack.spacing = 14; stack.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(stack); pages.append(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -18),
            stack.topAnchor.constraint(equalTo: host.topAnchor, constant: 18),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: host.bottomAnchor, constant: -18)
        ])
        return stack
    }

    private func buildGeneral(_ stack: NSStackView) {
        startup.addItems(withTitles: ExplorerPreferences.startupLocations.map { $0.1 })
        startup.target = self; startup.action = #selector(changed)
        startup.setAccessibilityIdentifier("optionsStartup")
        addRow("Startup location", control: startup, to: stack)
        customPath.placeholderString = "/Users/you/Documents"
        customPath.font = .systemFont(ofSize: 13); customPath.delegate = self
        customPath.setAccessibilityLabel("Startup folder path"); customPath.setAccessibilityIdentifier("optionsStartupPath")
        customPath.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        customPath.heightAnchor.constraint(equalToConstant: 25).isActive = true
        browseButton = ActionButton("Browse…") { [weak self] in self?.chooseFolder() }
        browseButton.font = .systemFont(ofSize: 13); browseButton.heightAnchor.constraint(equalToConstant: 29).isActive = true
        browseButton.setAccessibilityIdentifier("optionsBrowse")
        let pathRow = NSStackView(views: [customPath, browseButton!])
        pathRow.orientation = .horizontal; pathRow.alignment = .centerY; pathRow.spacing = 8; pathRow.distribution = .fill
        stack.addArrangedSubview(pathRow); pathRow.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        addNote("Choose a folder to use the path above. Restore previous tabs reopens your last browsing session.", to: stack)
    }

    private func buildView(_ stack: NSStackView) {
        defaultView.addItems(withTitles: ExplorerPreferences.viewModes.map { $0.1 })
        defaultView.target = self; defaultView.action = #selector(changed)
        defaultView.setAccessibilityIdentifier("optionsDefaultView")
        addRow("Default folder view", control: defaultView, to: stack)
        for (control, id) in [(showExtensions, "optionsShowExtensions"), (showHidden, "optionsShowHidden"), (compact, "optionsCompact")] {
            control.font = .systemFont(ofSize: 14)
            control.target = self; control.action = #selector(changed); control.setAccessibilityIdentifier(id)
            stack.addArrangedSubview(control)
        }
        addNote("Compact spacing fits more items in list and details views.", to: stack)
    }

    private func addRow(_ title: String, control: NSControl, to stack: NSStackView) {
        let label = makeLabel(title, size: 14, color: .secondaryLabelColor)
        label.widthAnchor.constraint(equalToConstant: 166).isActive = true
        control.font = .systemFont(ofSize: 14); control.setAccessibilityLabel(title)
        let row = NSStackView(views: [label, control]); row.orientation = .horizontal
        row.alignment = .centerY; row.distribution = .fill; row.spacing = 12
        stack.addArrangedSubview(row); row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    private func addNote(_ text: String, to stack: NSStackView) {
        let note = NSTextField(wrappingLabelWithString: text)
        note.font = .systemFont(ofSize: 13); note.textColor = .secondaryLabelColor
        stack.addArrangedSubview(note); note.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    private func selectTab(_ index: Int) {
        for (position, page) in pages.enumerated() { page.isHidden = position != index; tabs[position].selected = position == index }
    }

    private func populate(_ preferences: ExplorerPreferences) {
        let preferences = preferences.normalized()
        startup.selectItem(at: ExplorerPreferences.startupLocations.firstIndex { $0.0 == preferences.startupLocation } ?? 0)
        customPath.stringValue = preferences.startupPath
        defaultView.selectItem(at: ExplorerPreferences.viewModes.firstIndex { $0.0 == preferences.defaultViewMode } ?? 0)
        showExtensions.state = preferences.showFileExtensions ? .on : .off
        showHidden.state = preferences.showHiddenFiles ? .on : .off
        compact.state = preferences.compactView ? .on : .off
        changed()
    }

    private var draft: ExplorerPreferences {
        var result = applied
        result.startupLocation = ExplorerPreferences.startupLocations[max(0, startup.indexOfSelectedItem)].0
        result.startupPath = customPath.stringValue
        result.defaultViewMode = ExplorerPreferences.viewModes[max(0, defaultView.indexOfSelectedItem)].0
        result.showFileExtensions = showExtensions.state == .on
        result.showHiddenFiles = showHidden.state == .on
        result.compactView = compact.state == .on
        return result
    }

    @objc private func changed() {
        errorLabel.stringValue = ""
        let custom = draft.startupLocation == "custom"
        customPath.isEnabled = custom; browseButton.isEnabled = custom
        applyButton.isEnabled = draft != applied
    }

    private func chooseFolder() {
        guard let window else { return }
        let picker = NSOpenPanel(); picker.canChooseFiles = false; picker.canChooseDirectories = true
        picker.allowsMultipleSelection = false; picker.prompt = "Choose folder"
        let current = (customPath.stringValue as NSString).expandingTildeInPath
        if current.hasPrefix("/") { picker.directoryURL = URL(fileURLWithPath: current, isDirectory: true) }
        picker.beginSheetModal(for: window) { [weak self] response in
            guard let self, !self.isClosed, response == .OK, let url = picker.url else { return }
            self.customPath.stringValue = url.path; self.changed()
        }
    }

    private func apply(closeAfter: Bool) {
        window?.makeFirstResponder(nil)
        var preferences = draft
        if preferences.startupLocation == "custom" {
            let path = (preferences.startupPath as NSString).expandingTildeInPath
            var isDirectory: ObjCBool = false
            guard path.hasPrefix("/"), !path.contains("\0"),
                  FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue,
                  FileManager.default.isReadableFile(atPath: path), FileManager.default.isExecutableFile(atPath: path) else {
                selectTab(0); errorLabel.stringValue = "Choose an existing folder that you can open for startup."
                window?.makeFirstResponder(customPath); return
            }
            preferences.startupPath = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.path
        }
        preferences = preferences.normalized()
        if preferences != applied {
            guard let onApply else { errorLabel.stringValue = "Options could not be applied. Please reopen this window."; return }
            applied = preferences; populate(preferences)
            onApply(preferences)
        }
        if closeAfter { close() }
    }

    func controlTextDidChange(_ obj: Notification) { changed() }
    func controlTextDidBeginEditing(_ obj: Notification) { (customPath.currentEditor() as? NSTextView)?.allowsUndo = true }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) { apply(closeAfter: true); return true }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) { close(); return true }
        return false
    }
    func windowWillClose(_ notification: Notification) {
        guard !isClosed else { return }
        isClosed = true
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor); self.keyMonitor = nil }
        onClose?()
    }
    private func installKeyboardShortcuts() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.window else { return event }
            let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
            let key = shortcutKey(for: event)
            if event.keyCode == 53 || (modifiers == .command && key == "w") { self.close(); return nil }
            guard modifiers.contains(.control), !modifiers.contains(.command), !modifiers.contains(.option),
                  let editor = self.window?.firstResponder as? NSTextView else { return event }
            switch key {
            case "a": editor.selectAll(nil)
            case "c": editor.copy(nil)
            case "x": editor.cut(nil)
            case "v": editor.paste(nil)
            case "z": if modifiers.contains(.shift) { editor.undoManager?.redo() } else { editor.undoManager?.undo() }
            case "y": editor.undoManager?.redo()
            default: return event
            }
            return nil
        }
    }
}
