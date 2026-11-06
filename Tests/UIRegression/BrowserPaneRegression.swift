// Headless AppKit regression harness. Run from the project directory:
// xcrun swiftc -swift-version 5 Sources/MacFileManager/AppSupport.swift Sources/MacFileManager/ThisMacViewController.swift Sources/MacFileManager/BrowserPaneViewController.swift Sources/MacFileManager/ShortcutSupport.swift \
//   Tests/UIRegression/BrowserPaneRegression.swift -o .build/qa/browser-pane-regression
// .build/qa/browser-pane-regression
// It creates no visible windows and mutates only its own fixtures under .build/qa.
import AppKit

private struct RegressionFailure: Error, CustomStringConvertible {
    let description: String
}

private extension NSView {
    var descendants: [NSView] { subviews + subviews.flatMap(\.descendants) }
}

@main
struct BrowserPaneRegression {
    private static var checks = 0
    static func main() {
        do { try run() }
        catch {
            FileHandle.standardError.write(Data("FAIL: \(error)\n".utf8))
            exit(1)
        }
    }

    private static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        checks += 1
        if try !condition() { throw RegressionFailure(description: message) }
    }

    private static func wait(_ description: String, until condition: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition() && Date() < deadline {
            _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        try require(condition(), "Timed out: \(description)")
    }

    private static func run() throws {
        let application = NSApplication.shared
        application.setActivationPolicy(.prohibited)
        application.appearance = NSAppearance(named: .aqua)
        let manager = FileManager.default
        let legacy = Data(#"{"leftTabs":["/first"],"rightTabs":["/second"],"split":true,"preview":false,"showHidden":true}"#.utf8)
        let legacySettings = try JSONDecoder().decode(SavedSettings.self, from: legacy)
        try require(legacySettings.leftSelectedTab == 0 && legacySettings.rightSelectedTab == 0 && !legacySettings.activeRightPane, "Legacy settings must default both active tab indexes and active pane")
        try require(!legacySettings.singlePreview && legacySettings.split && legacySettings.showHidden, "Legacy single-preview preference must inherit preview")
        var settings = SavedSettings()
        settings.leftSelectedTab = 2
        settings.rightSelectedTab = 3
        settings.activeRightPane = true
        settings.preview = false
        settings.singlePreview = true
        let restoredSettings = try JSONDecoder().decode(SavedSettings.self, from: JSONEncoder().encode(settings))
        try require(restoredSettings.leftSelectedTab == 2 && restoredSettings.rightSelectedTab == 3 && restoredSettings.activeRightPane && restoredSettings.singlePreview && !restoredSettings.preview, "New tab, pane and single-preview settings must round-trip independently")
        let project = URL(fileURLWithPath: manager.currentDirectoryPath, isDirectory: true)
        let fixtures = project.appendingPathComponent(".build/qa/browser-fixtures-\(UUID().uuidString)", isDirectory: true)
        let a = fixtures.appendingPathComponent("A", isDirectory: true)
        let b = fixtures.appendingPathComponent("B", isDirectory: true)
        let nested = a.appendingPathComponent("nested", isDirectory: true)
        try manager.createDirectory(at: nested, withIntermediateDirectories: true)
        try manager.createDirectory(at: b, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: fixtures) }
        let alpha = a.appendingPathComponent("alpha.txt")
        let beta = a.appendingPathComponent("beta.txt")
        let needle = nested.appendingPathComponent("needle.txt")
        try Data("alpha".utf8).write(to: alpha)
        try Data("a longer beta".utf8).write(to: beta)
        try Data("nested match".utf8).write(to: needle)
        try Data("hidden".utf8).write(to: a.appendingPathComponent(".secret"))
        try Data("other".utf8).write(to: b.appendingPathComponent("other.txt"))

        let pane = BrowserPaneViewController(url: a)
        var status = ""
        var lastSelection: [URL] = []
        pane.onStatusChange = { status = $0 }
        pane.onSelectionChange = { lastSelection = $0 }
        pane.onActivate = { [weak pane] in pane?.setActive(true) }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = pane.view
        window.orderOut(nil)
        defer { window.close() }
        let table = try find(NSTableView.self, in: pane.view, identifier: "browser.files")
        let search = try find(NSSearchField.self, in: pane.view, identifier: "browser.search")
        let address = try find(NSTextField.self, in: pane.view, identifier: "browser.address")
        // This suite exercises synchronous current-folder filtering below;
        // default recursive search is covered by BrowserSearchRegression.
        let initialDirectScope = NSMenuItem()
        initialDirectScope.tag = 0
        application.sendAction(NSSelectorFromString("searchScopeSelected:"), to: pane, from: initialDirectScope)
        func settled(_ count: Int) -> Bool { table.numberOfRows == count && !status.contains("Loading") && !status.contains("Searching") }
        try wait("initial directory", until: { settled(3) })

        try checkAddressEditing(pane: pane, window: window, address: address, search: search,
                                table: table, initialURL: a, alternateURL: b, fixtures: fixtures,
                                project: project)
        try wait("directory after address checks", until: { settled(3) })

        pane.selectFiles([alpha, beta])
        try require(Set(pane.selectedURLs) == Set([alpha, beta]), "Multi-selection must select both requested files")
        pane.setCutURLs([alpha])
        try require(Set(pane.selectedURLs) == Set([alpha, beta]), "Cut appearance must preserve multi-selection")
        pane.reload()
        try wait("selection after refresh", until: { settled(3) })
        try require(Set(pane.selectedURLs) == Set([alpha, beta]), "Directory refresh must preserve live selection")
        pane.setSort(key: "size", ascending: false)
        try require(Set(pane.selectedURLs) == Set([alpha, beta]), "Sorting must preserve URLs, not row indexes")

        pane.setViewMode("icons")
        try require(Set(pane.selectedURLs) == Set([alpha, beta]), "Icon mode must preserve selection")
        guard let collection = pane.view.descendants.first(where: { $0 is NSCollectionView }) as? NSCollectionView else { throw RegressionFailure(description: "Missing icon collection") }
        collection.selectAll(nil)
        try require(pane.selectedURLs.count == 3 && lastSelection.count == 3, "Native icon Select All must update state and callbacks")
        pane.selectAllFiles()
        try require(pane.selectedURLs.count == 3 && lastSelection.count == 3, "Icon Select All must update state and callbacks")
        pane.setViewMode("details")
        try require(pane.selectedURLs.count == 3, "Returning to Details must preserve icon selection")

        search.stringValue = "alpha"
        application.sendAction(search.action!, to: search.target, from: search)
        try require(table.numberOfRows == 1 && pane.selectedURLs == [alpha], "Current-folder search must filter the table and live selection")
        search.stringValue = ""
        application.sendAction(search.action!, to: search.target, from: search)
        try require(table.numberOfRows == 3, "Clearing search must restore the directory")

        let recursiveScope = NSMenuItem()
        recursiveScope.tag = 1
        application.sendAction(NSSelectorFromString("searchScopeSelected:"), to: pane, from: recursiveScope)
        search.stringValue = "needle"
        application.sendAction(search.action!, to: search.target, from: search)
        try wait("recursive search", until: { settled(1) && status.contains("matching") })
        pane.selectAllFiles()
        try require(pane.selectedURLs == [needle], "Recursive search must return the actual nested URL")
        search.stringValue = "alpha"
        application.sendAction(search.action!, to: search.target, from: search)
        search.stringValue = ""
        application.sendAction(search.action!, to: search.target, from: search)
        try wait("cancelled recursive query", until: { settled(3) })
        let directScope = NSMenuItem()
        directScope.tag = 0
        application.sendAction(NSSelectorFromString("searchScopeSelected:"), to: pane, from: directScope)

        pane.navigate(to: b)
        try wait("navigation B", until: { settled(1) })
        pane.showRecents()
        try require(pane.isShowingRecents, "Recents must activate the virtual location")
        pane.goBack()
        try require(!pane.isShowingRecents && pane.currentURL == b, "Back from Recents must restore the preceding folder")
        pane.goBack()
        try require(pane.currentURL == a, "Back must retain earlier folder history")
        pane.goForward()
        try require(pane.currentURL == b && !pane.isShowingRecents, "Forward to folder must not retain the Recents flag")
        pane.goForward()
        try require(pane.isShowingRecents, "Forward must restore a Recents history entry")
        pane.navigate(to: b)
        try require(!pane.isShowingRecents && pane.currentURL == b, "Navigating to the underlying folder must leave Recents")

        pane.restoreTabs([a, b], selectedIndex: 1)
        try wait("active tab restoration", until: { settled(1) })
        try require(pane.selectedTabIndex == 1 && pane.currentURL == b, "Saved active tab must be restored")
        pane.restoreTabs([a, b], selectedIndex: 99)
        try require(pane.selectedTabIndex == 1, "Out-of-range active tab must clamp safely")
        pane.restoreTabs([a, b], selectedIndex: -1)
        try wait("first restored tab", until: { settled(3) })
        try require(pane.selectedTabIndex == 0 && pane.currentURL == a, "Negative active tab must clamp to first tab")
        pane.selectFiles([alpha])
        guard let closeBackground = pane.tabsView.descendants.compactMap({ $0 as? NSButton }).first(where: { $0.toolTip == "Close B tab" }) else { throw RegressionFailure(description: "Missing background tab close control") }
        application.sendAction(closeBackground.action!, to: closeBackground.target, from: closeBackground)
        try require(pane.openDirectories == [a] && pane.selectedURLs == [alpha] && table.numberOfRows == 3, "Closing a background tab must retain active rows and selection")
        pane.setHiddenFiles(true)
        try wait("hidden file toggle", until: { settled(4) })
        pane.setHiddenFiles(false)
        try wait("hide dotfiles", until: { settled(3) })

        pane.selectFiles([alpha])
        let renamed = a.appendingPathComponent("renamed-alpha.txt")
        try manager.moveItem(at: alpha, to: renamed)
        pane.reload()
        pane.selectFiles([renamed])
        try wait("selection after filesystem rename", until: { settled(3) })
        try require(pane.selectedURLs == [renamed] && lastSelection == [renamed], "Reload followed by selecting the renamed URL must preserve that selection when enumeration completes")

        let created = a.appendingPathComponent("created.txt")
        try Data("new file".utf8).write(to: created)
        pane.reload()
        pane.selectFiles([created])
        try wait("selection after file creation", until: { settled(4) })
        try require(pane.selectedURLs == [created] && lastSelection == [created], "Reload followed by selecting a newly created URL must preserve that selection when enumeration completes")

        for (width, split) in [(814.0, false), (1180.0, false), (814.0, false), (575.0, true)] {
            pane.setPresentationMode(split: split)
            window.setContentSize(NSSize(width: width, height: 700))
            pane.view.layoutSubtreeIfNeeded()
            pane.viewDidLayout()
            try wait("metadata columns fit \(width)", until: {
                guard let viewport = table.enclosingScrollView?.contentView.bounds.width,
                      let last = table.tableColumns.lastIndex(where: { !$0.isHidden }) else { return false }
                return table.rect(ofColumn: last).maxX <= viewport + 1
            })
        }
        print("PASS: \(checks) checks: address geometry/focus/editing, settings compatibility, history, Recents, restored/background tabs, selection, rename/create selection, sorting, recursive search, cancellation, hidden files, and resize regressions")
    }

    private static func checkAddressEditing(pane: BrowserPaneViewController, window: NSWindow,
                                            address: NSTextField, search: NSSearchField, table: NSTableView,
                                            initialURL: URL, alternateURL: URL, fixtures: URL, project: URL) throws {
        guard let box = address.superview,
              let icon = box.subviews.first(where: { $0 is NSImageView }),
              let breadcrumb = box.subviews.first(where: { $0 !== address && $0 !== icon }) else {
            throw RegressionFailure(description: "Address editor must share a surface with its folder icon and breadcrumbs")
        }
        func editor() throws -> NSTextView {
            guard let editor = address.currentEditor() as? NSTextView else {
                throw RegressionFailure(description: "Missing actual address field editor")
            }
            return editor
        }
        func geometry() throws {
            pane.view.layoutSubtreeIfNeeded()
            // NSTextField's frame includes AppKit's 2pt horizontal alignment insets.
            let textAlignment = address.alignmentRect(forFrame: address.frame)
            try require(abs(box.bounds.height - 36) < 0.5 && abs(address.frame.height - 22) < 0.5,
                        "Address surface must remain 36pt high with a 22pt editor")
            try require(abs(address.frame.midY - box.bounds.midY) < 0.5,
                        "Address text must be vertically centered within its surface")
            try require(abs(textAlignment.minX - 43) < 0.5 && abs(box.bounds.maxX - textAlignment.maxX - 10) < 0.5,
                        "Address text must retain icon space and its 10pt trailing inset")
            try require(abs(icon.frame.minX - 12) < 0.5 && abs(icon.frame.width - 23) < 0.5 && abs(icon.frame.midY - box.bounds.midY) < 0.5,
                        "Address folder icon must remain centered with its own inset")
            try require(box.layer?.borderWidth == 1 && box.layer?.cornerRadius == 6,
                        "The shared address surface must keep a slim rounded border")
            let actualEditor = try editor()
            let visibleEditor = actualEditor.convert(actualEditor.visibleRect, to: box)
            try require(visibleEditor.height > 0 && visibleEditor.minY >= 0 && visibleEditor.maxY <= box.bounds.height,
                        "Actual field-editor text must stay inside the address surface: \(visibleEditor)")
        }
        try require(address.isHidden && icon.isHidden && !breadcrumb.isHidden, "Idle address must display breadcrumbs only")
        try require(address.focusRingType == .none && !address.isBordered && !address.isBezeled && address.toolTip == nil,
                    "Editor must not add a native focus ring, border, bezel or path tooltip")
        try require(address.usesSingleLineMode && address.cell?.isScrollable == true && address.cell?.wraps == false,
                    "Folder paths must use a single horizontally scrolling line")
        pane.focusFiles()
        pane.focusAddress()
        try require(!address.isHidden && !icon.isHidden && breadcrumb.isHidden && window.firstResponder === address.currentEditor(),
                    "Address focus must show its icon/editor and focus the real editor")
        try require(try editor().selectedRange() == NSRange(location: 0, length: (initialURL.path as NSString).length),
                    "Address focus must select the complete path from its first character")
        try geometry()
        pane.focusAddress()
        try require(!address.isHidden && window.firstResponder === address.currentEditor(), "Repeated address focus must not close the editor")

        let draftEditor = try editor()
        draftEditor.insertText(alternateURL.path, replacementRange: draftEditor.selectedRange())
        let padding = box.convert(NSPoint(x: 3, y: box.bounds.midY), to: nil)
        guard let paddingClick = NSEvent.mouseEvent(with: .leftMouseDown, location: padding, modifierFlags: [],
                                                   timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                                   eventNumber: 1, clickCount: 1, pressure: 1) else {
            throw RegressionFailure(description: "Unable to create direct padding-click fixture")
        }
        box.mouseDown(with: paddingClick)
        try require(draftEditor.string == alternateURL.path && window.firstResponder === draftEditor,
                    "Clicking address padding while editing must preserve the draft and editor")
        draftEditor.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        try require(address.isHidden && icon.isHidden && !breadcrumb.isHidden && pane.currentURL == initialURL,
                    "Escape must restore breadcrumbs without navigating to the draft")
        try require(address.stringValue == initialURL.path && window.firstResponder === table,
                    "Escape must restore the current path and return focus to files")

        pane.focusAddress()
        let blurEditor = try editor()
        blurEditor.insertText(alternateURL.path, replacementRange: blurEditor.selectedRange())
        pane.focusSearch()
        try require(address.isHidden && window.firstResponder === search.currentEditor() && pane.currentURL == initialURL,
                    "Search focus must close address editing without submitting its draft")
        pane.focusAddress()
        try require(try editor().string == initialURL.path && !address.isHidden,
                    "Reopening a blurred editor must show the current folder, not an unsubmitted draft")

        let longURL = fixtures.appendingPathComponent(String(repeating: "Long folder with spaces ", count: 5), isDirectory: true)
            .appendingPathComponent(String(repeating: "أرشيف-資料-", count: 6), isDirectory: true)
        try FileManager.default.createDirectory(at: longURL, withIntermediateDirectories: true)
        pane.navigate(to: longURL)
        try wait("long-path folder", until: { table.numberOfRows == 0 })
        pane.setPresentationMode(split: true)
        window.setContentSize(NSSize(width: 575, height: 700))
        pane.view.layoutSubtreeIfNeeded()
        pane.focusAddress()
        let longEditor = try editor()
        try require(longEditor.string == longURL.path && longEditor.selectedRange() == NSRange(location: 0, length: (longURL.path as NSString).length),
                    "Narrow-pane editing must preserve and select the complete Unicode path")
        try geometry()
        let end = NSRange(location: (longEditor.string as NSString).length, length: 0)
        longEditor.setSelectedRange(end)
        longEditor.scrollRangeToVisible(end)
        if let container = longEditor.textContainer, let layout = longEditor.layoutManager {
            layout.ensureLayout(for: container)
            var lines = 0
            layout.enumerateLineFragments(forGlyphRange: layout.glyphRange(for: container)) { _, _, _, _, _ in lines += 1 }
            try require(lines == 1, "A long address must stay on one rendered line rather than wrapping")
            try require(longEditor.visibleRect.minX > 0, "The actual long-path editor must scroll horizontally to its end")
        } else { throw RegressionFailure(description: "Missing address editor text layout") }
        longEditor.selectAll(nil)
        let renderRect = box.convert(box.bounds, to: pane.view).insetBy(dx: -8, dy: -8)
        guard let bitmap = pane.view.bitmapImageRepForCachingDisplay(in: renderRect) else {
            throw RegressionFailure(description: "Unable to render focused address bar")
        }
        pane.view.cacheDisplay(in: renderRect, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw RegressionFailure(description: "Unable to encode focused address bar")
        }
        try png.write(to: project.appendingPathComponent(".build/qa/address-edit.png"))
        longEditor.insertText("This Mac", replacementRange: longEditor.selectedRange())
        longEditor.doCommand(by: NSSelectorFromString("insertNewline:"))
        try require(pane.isShowingThisMac && address.isHidden && window.firstResponder !== longEditor,
                    "Submitting This Mac must close address editing and move focus into its contents")
        pane.focusAddress()
        try editor().doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        try require(pane.isShowingThisMac && address.isHidden && window.firstResponder !== address.currentEditor(),
                    "Escape from the This Mac address must close editing without leaving the location")
        pane.navigate(to: initialURL)
        pane.setPresentationMode(split: false)
        window.setContentSize(NSSize(width: 900, height: 700))
        pane.view.layoutSubtreeIfNeeded()
        pane.focusFiles()
    }

    private static func find<T: NSView>(_ type: T.Type, in view: NSView, identifier: String) throws -> T {
        guard let match = ([view] + view.descendants).first(where: { $0.identifier?.rawValue == identifier }) as? T else {
            throw RegressionFailure(description: "Missing view \(identifier)")
        }
        return match
    }
}
