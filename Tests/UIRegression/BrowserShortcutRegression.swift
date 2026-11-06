// Run from the project directory:
// xcrun swiftc -swift-version 5 -module-cache-path .build/module-cache \
//   Sources/MacFileManager/AppSupport.swift Sources/MacFileManager/AppShortcutDocument.swift Sources/MacFileManager/ShortcutSupport.swift \
//   Sources/MacFileManager/ThisMacViewController.swift Sources/MacFileManager/BrowserPaneViewController.swift \
//   Sources/MacFileManager/PreviewViewController.swift Tests/UIRegression/BrowserShortcutRegression.swift \
//   -o .build/qa/browser-shortcut-regression
// .build/qa/browser-shortcut-regression
// Hidden windows, generated project fixtures, injected opening callbacks. No apps are opened,
// no input is posted, and no system recent-document or clipboard state is changed.
import AppKit

private struct ShortcutRegressionFailure: Error, CustomStringConvertible { let description: String }

@main struct BrowserShortcutRegression {
    static var checks = 0
    static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        checks += 1
        if try !condition() { throw ShortcutRegressionFailure(description: message) }
    }
    static func wait(_ message: String, until condition: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(6)
        while !condition() && Date() < deadline {
            _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        try require(condition(), message)
    }
    static func descendants(_ view: NSView) -> [NSView] { view.subviews + view.subviews.flatMap(descendants) }
    static func bitmap(_ image: NSImage, size: Int) -> NSBitmapImageRep {
        let result = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: result)
        NSColor.white.setFill(); NSRect(x: 0, y: 0, width: size, height: size).fill()
        image.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
        NSGraphicsContext.restoreGraphicsState()
        return result
    }
    static func hasBadge(_ image: NSImage, size: Int) -> Bool {
        let pixels = bitmap(image, size: size)
        let side = Int(max(9, min(34, CGFloat(size) * 0.42)))
        var arrowPixels = 0
        // Bitmap y coordinates run top-to-bottom; the badge occupies the lower-left corner.
        for x in 1..<side {
            for y in (size - side)..<(size - 1) {
                let color = pixels.colorAt(x: x, y: y)!.usingColorSpace(.deviceRGB)!
                if color.blueComponent > 0.40 && color.redComponent < 0.30 && color.greenComponent < 0.48 { arrowPixels += 1 }
            }
        }
        return arrowPixels >= (size < 30 ? 3 : 10)
    }

    static func main() throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        app.appearance = NSAppearance(named: .aqua)
        let manager = FileManager.default
        let project = URL(fileURLWithPath: manager.currentDirectoryPath, isDirectory: true)
        let fixture = project.appendingPathComponent(".build/qa/browser-shortcut-fixtures-" + UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: fixture, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: fixture) }
        func folder(_ parent: URL, _ name: String) throws -> URL {
            let url = parent.appendingPathComponent(name, isDirectory: true)
            try manager.createDirectory(at: url, withIntermediateDirectories: true); return url
        }
        func alias(_ target: URL, _ name: String, in parent: URL) throws -> URL {
            let url = parent.appendingPathComponent(name)
            let data = try target.bookmarkData(options: [.suitableForBookmarkFile], includingResourceValuesForKeys: nil, relativeTo: nil)
            try URL.writeBookmarkData(data, to: url)
            return url
        }
        let source = try folder(fixture, "Sources")
        let browser = try folder(fixture, "Browser")
        let targetFolder = try folder(source, "Target folder")
        let targetFile = source.appendingPathComponent("Target file.txt")
        try Data("shortcut target content".utf8).write(to: targetFile)
        let folderAlias = try alias(targetFolder, "Folder shortcut", in: browser)
        let fileAlias = try alias(targetFile, "File shortcut", in: browser)
        let chainAlias = try alias(folderAlias, "Chained shortcut", in: browser)
        let missingTarget = source.appendingPathComponent("Deleted target.txt")
        try Data("gone".utf8).write(to: missingTarget)
        let brokenAlias = try alias(missingTarget, "Broken shortcut", in: browser)
        try manager.removeItem(at: missingTarget)
        let normalFolder = try folder(browser, "Normal folder")
        let normalFile = browser.appendingPathComponent("Normal file.txt")
        try Data("ordinary content".utf8).write(to: normalFile)
        let symlink = source.appendingPathComponent("Symbolic link")
        try manager.createSymbolicLink(at: symlink, withDestinationURL: targetFolder)

        try require(ShortcutSupport.isAlias(folderAlias) && ShortcutSupport.isAlias(fileAlias), "Generated shortcuts must be recognized as genuine aliases")
        try require(!ShortcutSupport.isAlias(normalFolder) && !ShortcutSupport.isAlias(normalFile) && !ShortcutSupport.isAlias(symlink), "Normal folders, files, and symlinks must not become alias files")
        try require(try ShortcutSupport.resolve(folderAlias) == targetFolder, "Folder alias must resolve to its actual folder")
        try require(try ShortcutSupport.resolve(fileAlias) == targetFile, "File alias must resolve to its document")
        try require(try ShortcutSupport.resolve(chainAlias) == targetFolder, "Chained aliases must resolve to the final folder")
        do {
            _ = try ShortcutSupport.resolve(brokenAlias)
            throw ShortcutRegressionFailure(description: "Deleted shortcut target must fail resolution")
        } catch let failure as ShortcutSupport.ResolutionError {
            try require(failure.localizedDescription.contains("Broken shortcut") && failure.localizedDescription.contains("target"), "Broken-shortcut errors must identify the shortcut and unavailable target")
        }
        for size in [18, 24, 48, 58, 102, 110] {
            for url in [folderAlias, fileAlias, brokenAlias] {
                try require(hasBadge(ShortcutSupport.icon(for: url, size: CGFloat(size)), size: size), "Shortcut badge must remain recognizable at \(size) points for \(url.lastPathComponent)")
            }
        }
        try require(!hasBadge(ShortcutSupport.icon(for: normalFolder, size: 48), size: 48), "Normal folder icons must not have the shortcut arrow")
        let gallery = NSImage(size: NSSize(width: 600, height: 180), flipped: false) { _ in
            NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 600, height: 180).fill()
            for (index, pair) in [("Folder", normalFolder), ("Folder shortcut", folderAlias), ("File shortcut", fileAlias), ("Broken shortcut", brokenAlias)].enumerated() {
                ShortcutSupport.icon(for: pair.1, size: 90).draw(in: NSRect(x: 25 + index * 150, y: 60, width: 90, height: 90))
                (pair.0 as NSString).draw(at: NSPoint(x: 12 + index * 150, y: 24), withAttributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.black])
                ShortcutSupport.icon(for: pair.1, size: 24).draw(in: NSRect(x: 120 + index * 150, y: 92, width: 24, height: 24))
            }
            return true
        }
        if let data = gallery.tiffRepresentation, let pixels = NSBitmapImageRep(data: data) {
            try pixels.representation(using: .png, properties: [:])!.write(to: project.appendingPathComponent(".build/qa/shortcut-icons.png"))
        }

        let pane = BrowserPaneViewController(url: browser)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = pane.view; window.orderOut(nil)
        defer { window.close() }
        let table = descendants(pane.view).first { $0 is NSTableView } as! NSTableView
        var openedFolders: [URL] = [], openedFiles: [URL] = [], errors: [String] = []
        pane.onOpenFolderWindow = { openedFolders.append($0) }
        pane.openFile = { openedFiles.append($0); return true }
        pane.onOpenError = { errors.append($0) }
        try wait("Browser shortcut fixture must load", until: { table.numberOfRows == 6 })
        pane.selectFiles([folderAlias]); pane.openSelection()
        try require(openedFolders == [targetFolder] && openedFiles.isEmpty && pane.currentURL == browser, "Opening a folder shortcut must request a new app window without Finder or current-pane navigation")
        try require(pane.selectedURLs == [folderAlias], "Folder shortcut selection must retain the alias filesystem URL")
        pane.selectFiles([fileAlias]); pane.openSelection()
        try require(openedFiles == [targetFile] && pane.currentURL == browser, "Opening a file shortcut must open the resolved document through the file handler")
        pane.selectFiles([brokenAlias]); pane.openSelection()
        try require(errors.count == 1 && errors[0].contains("Broken shortcut") && openedFiles == [targetFile], "Broken aliases must report an error without falling through to an external opener")
        let selectedRow = table.selectedRowIndexes.first!
        let writer = pane.tableView(table, pasteboardWriterForRow: selectedRow) as? NSURL
        try require(writer as URL? == brokenAlias, "Drag/copy data must preserve the shortcut file URL, even when its target is broken")
        pane.selectFiles([folderAlias])
        let aliasRow = table.selectedRowIndexes.first!
        let nameColumn = table.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier("name"))!
        let nameCell = pane.tableView(table, viewFor: nameColumn, row: aliasRow) as! NSTableCellView
        try require(hasBadge(nameCell.imageView!.image!, size: 24), "Actual details cells must use the shortcut badge")
        let typeCell = pane.tableView(table, viewFor: table.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier("kind"))!, row: aliasRow) as! NSTableCellView
        try require(typeCell.textField?.stringValue == "Shortcut", "Shortcut type must describe the alias rather than the target")
        for mode in ["list", "smallIcons", "mediumIcons", "largeIcons", "tiles"] {
            pane.setViewMode(mode); pane.selectFiles([folderAlias]); pane.view.layoutSubtreeIfNeeded()
            let collection = descendants(pane.view).first { $0 is NSCollectionView } as! NSCollectionView
            let path = collection.selectionIndexPaths.first!
            let item = pane.collectionView(collection, itemForRepresentedObjectAt: path)
            let size = Int(item.imageView!.image!.size.width)
            try require(hasBadge(item.imageView!.image!, size: size), "Actual \(mode) cells must use the shortcut badge")
            try require((pane.collectionView(collection, pasteboardWriterForItemAt: path) as? NSURL) as URL? == folderAlias, "Icon drag data must preserve the alias URL in \(mode)")
        }
        pane.setViewMode("details"); pane.selectFiles([normalFolder])
        let selected = table.selectedRowIndexes.first!
        let point = table.convert(NSPoint(x: 60, y: table.rect(ofRow: selected).midY), to: nil)
        let event = NSEvent.mouseEvent(with: .rightMouseDown, location: point, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        let menu = table.menu(for: event)!
        pane.menuNeedsUpdate(menu)
        let openNew = menu.items.first { $0.title == "Open in New Window" }!
        try require(openNew.isEnabled, "Normal folders must offer Open in New Window")
        try require(app.sendAction(openNew.action!, to: openNew.target, from: openNew), "New-window context action must route")
        try require(openedFolders.last == normalFolder && pane.currentURL == browser, "Context Open in New Window must keep the source pane in place")
        pane.openURL(normalFolder)
        try require(pane.currentURL == normalFolder && openedFiles == [targetFile], "Ordinary folder Open must retain same-pane navigation")
        pane.openURL(normalFile)
        try require(openedFiles.last == normalFile, "Ordinary files must retain default-application routing")
        pane.openFile = { openedFiles.append($0); return false }
        pane.openURL(fileAlias)
        try require(errors.count == 2 && errors.last!.contains("default application"), "Failed document opens must report a useful error")

        let preview = PreviewViewController()
        let previewWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 345, height: 720), styleMask: [.titled], backing: .buffered, defer: false)
        previewWindow.contentView = preview.view; previewWindow.orderOut(nil)
        defer { previewWindow.close() }
        var previewOpened: URL?
        preview.onOpen = { previewOpened = $0 }
        preview.show(url: folderAlias)
        try wait("Alias preview metadata must settle", until: { descendants(preview.view).compactMap { $0 as? NSTextField }.contains { $0.stringValue == "Shortcut" } })
        let previewIcon = descendants(preview.view).compactMap { $0 as? NSImageView }.first { $0.frame.width > 50 && !$0.isHidden }!
        try require(hasBadge(previewIcon.image!, size: 110), "Preview must show the same shortcut badge instead of Quick Look following the alias")
        let openButton = descendants(preview.view).compactMap { $0 as? NSButton }.first { $0.accessibilityIdentifier() == "openPreviewFile" }!
        openButton.performClick(nil)
        try require(previewOpened == folderAlias, "Preview Open must delegate the original alias URL for shared browser routing")
        try require(try String(contentsOf: targetFile, encoding: .utf8) == "shortcut target content", "Shortcut operations must not modify the original document")
        try require(manager.fileExists(atPath: folderAlias.path) && manager.fileExists(atPath: fileAlias.path), "Opening must not replace or remove alias files")

        // New app-owned documents exercise the same UI while every native-alias case above
        // remains intact. Creating these fixtures directly also proves hidden UI extensions
        // do not depend on the document having Finder's hidden-extension metadata already.
        let documents = try folder(fixture, "App shortcuts")
        func document(_ target: URL, _ name: String) throws -> URL {
            let url = documents.appendingPathComponent(name).appendingPathExtension(AppShortcutDocument.fileExtension)
            try AppShortcutDocument.data(for: target).write(to: url)
            return url
        }
        let folderDocument = try document(targetFolder, "Folder - Shortcut")
        let fileDocument = try document(targetFile, "Document.txt - Shortcut")
        let soonMissing = source.appendingPathComponent("Missing document target.txt")
        try Data("deleted target".utf8).write(to: soonMissing)
        let brokenDocument = try document(soonMissing, "Broken - Shortcut")
        try manager.removeItem(at: soonMissing)
        let documentToAlias = try document(folderAlias, "Document to legacy alias")
        let aliasToDocument = try alias(folderDocument, "Legacy alias to document", in: source)
        try require(AppShortcutDocument.isShortcut(folderDocument) && !ShortcutSupport.isAlias(folderDocument), "New shortcuts must be app-owned documents rather than native aliases")
        try require(ShortcutSupport.isShortcut(folderDocument) && ShortcutSupport.isShortcut(folderAlias), "Both app documents and legacy aliases must remain recognized")
        try require(try ShortcutSupport.resolve(documentToAlias) == targetFolder, "Custom-to-legacy shortcut chains must reach the target")
        try require(try ShortcutSupport.resolve(aliasToDocument) == targetFolder, "Legacy-to-custom shortcut chains must reach the target")
        let cycle = documents.appendingPathComponent("Cycle.fmlink")
        try Data("placeholder".utf8).write(to: cycle)
        try AppShortcutDocument.data(for: cycle).write(to: cycle)
        do {
            _ = try ShortcutSupport.resolve(cycle)
            throw ShortcutRegressionFailure(description: "Self-referential documents must not resolve indefinitely")
        } catch is ShortcutSupport.ResolutionError {
            try require(true, "Cyclic shortcuts must report an opening error")
        }
        pane.openFile = { openedFiles.append($0); return true }
        pane.navigate(to: documents)
        try wait("Custom shortcut fixture must load", until: { table.numberOfRows == 5 })
        let previousFolderCount = openedFolders.count
        pane.selectFiles([folderDocument]); pane.openSelection()
        try require(openedFolders.count == previousFolderCount + 1 && openedFolders.last == targetFolder && pane.currentURL == documents,
                    "Custom folder shortcuts must request a new WinExplorer for Mac window and retain the current pane")
        try require(pane.selectedURLs == [folderDocument], "Custom shortcut selection must retain its own filesystem URL")
        let previousFileCount = openedFiles.count
        pane.openURL(fileDocument)
        try require(openedFiles.count == previousFileCount + 1 && openedFiles.last == targetFile,
                    "Custom document shortcuts must send the resolved document to the default-file handler")
        let previousErrorCount = errors.count
        pane.openURL(brokenDocument)
        try require(errors.count == previousErrorCount + 1 && errors.last!.contains("Broken - Shortcut") && !errors.last!.contains("Broken - Shortcut.fmlink"),
                    "Broken custom shortcut errors must identify the friendly name without exposing its internal extension")
        try require(openedFiles.count == previousFileCount + 1, "Broken custom shortcuts must never fall through to an external opener")
        for showExtensions in [true, false] {
            pane.setDisplayPreferences(showExtensions: showExtensions, compact: false, defaultViewMode: "details")
            pane.selectFiles([fileDocument])
            let row = table.selectedRowIndexes.first!
            let cell = pane.tableView(table, viewFor: nameColumn, row: row) as! NSTableCellView
            try require(cell.textField?.stringValue == "Document.txt - Shortcut", "Details must hide only .fmlink regardless of ordinary extension preferences")
            try require(hasBadge(cell.imageView!.image!, size: 24), "Custom Details cells must have a shortcut badge")
            let writer = pane.tableView(table, pasteboardWriterForRow: row) as? NSURL
            try require(writer as URL? == fileDocument, "Custom document file operations must retain .fmlink on disk")
        }
        for mode in ["list", "smallIcons", "mediumIcons", "largeIcons", "tiles"] {
            pane.setViewMode(mode); pane.selectFiles([folderDocument]); pane.view.layoutSubtreeIfNeeded()
            let collection = descendants(pane.view).first { $0 is NSCollectionView } as! NSCollectionView
            let path = collection.selectionIndexPaths.first!
            let item = pane.collectionView(collection, itemForRepresentedObjectAt: path)
            try require(item.textField?.stringValue == "Folder - Shortcut", "\(mode) must hide the custom document extension")
            try require(hasBadge(item.imageView!.image!, size: Int(item.imageView!.image!.size.width)), "\(mode) must badge custom shortcut documents")
            try require((pane.collectionView(collection, pasteboardWriterForItemAt: path) as? NSURL) as URL? == folderDocument,
                        "\(mode) drag data must retain the custom shortcut document URL")
        }
        pane.setViewMode("details"); pane.selectFiles([folderDocument]); pane.menuNeedsUpdate(menu)
        try require(menu.items.first { $0.title == "Open in New Window" }?.isEnabled == true,
                    "Custom folder shortcuts must offer Open in New Window")
        preview.onOpen = { previewOpened = $0; pane.openURL($0) }
        preview.show(url: folderDocument)
        try wait("Custom shortcut preview metadata must settle", until: {
            let labels = descendants(preview.view).compactMap { $0 as? NSTextField }.map(\.stringValue)
            return labels.contains("Shortcut") && labels.contains("Folder - Shortcut")
        })
        try require(hasBadge(previewIcon.image!, size: 110), "Preview must badge custom shortcuts without opening Quick Look on their JSON")
        let beforePreviewOpen = openedFolders.count
        openButton.performClick(nil)
        try require(previewOpened == folderDocument && openedFolders.count == beforePreviewOpen + 1 && openedFolders.last == targetFolder,
                    "Preview Open must route a custom folder shortcut into the same new-window callback")
        print("PASS: \(checks) shortcut checks for app documents and legacy aliases, mixed/cyclic chains, broken targets, hidden extensions, badges in details/all icon modes/preview, original URL identity, default-app routing and new-window callbacks")
    }
}
