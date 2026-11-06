// Hidden AppKit regression harness. Run from the project directory after swift build:
// xcrun swiftc -swift-version 5 -I .build/debug/Modules \
//   Sources/MacFileManager/AppSupport.swift Sources/MacFileManager/AppShortcutDocument.swift \
//   Sources/MacFileManager/PropertiesWindowController.swift \
//   Tests/UIRegression/PropertiesWindowRegression.swift .build/debug/FileManagerCore.build/*.swift.o \
//   -o .build/qa/properties-window-regression
// .build/qa/properties-window-regression
// Optional hidden renders: append --render /absolute/path/to/fixture/file.txt
// Never orders a window on screen and never changes the system clipboard.
import AppKit
import FileManagerCore

private struct PropertiesWindowRegressionFailure: Error, CustomStringConvertible {
    let description: String
}

@main struct PropertiesWindowRegression {
    static func main() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        NSApp.appearance = NSAppearance(named: .aqua)
        let manager = FileManager.default
        let project = URL(fileURLWithPath: manager.currentDirectoryPath)
        let fixtures = project.appendingPathComponent(".build/qa/properties-window-fixtures-\(UUID().uuidString)")
        try manager.createDirectory(at: fixtures, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: fixtures) }
        let file = fixtures.appendingPathComponent("Report.txt")
        let second = fixtures.appendingPathComponent("Notes.txt")
        try Data("A reproducible properties fixture.\n".utf8).write(to: file)
        try Data("Second file.\n".utf8).write(to: second)
        func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            if !condition() { throw PropertiesWindowRegressionFailure(description: message) }
        }
        func find(_ id: String, in root: NSView) -> NSView? {
            if root.identifier?.rawValue == id || root.accessibilityIdentifier() == id { return root }
            return root.subviews.lazy.compactMap { find(id, in: $0) }.first
        }
        func control<T: NSView>(_ controller: PropertiesWindowController, _ id: String, _: T.Type) -> T {
            find(id, in: controller.window!.contentView!) as! T
        }
        func pump(_ seconds: TimeInterval) {
            let end = Date().addingTimeInterval(seconds)
            while Date() < end { _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
        }
        func waitFor(_ condition: () -> Bool) throws {
            let end = Date().addingTimeInterval(5)
            while !condition(), Date() < end { pump(0.02) }
            try require(condition(), "Timed out waiting for Properties metadata")
        }
        func edit(_ controller: PropertiesWindowController, _ name: String) {
            let field = control(controller, "propertiesName", NSTextField.self)
            field.stringValue = name
            controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
        }
        let controller = PropertiesWindowController(urls: [file])
        defer { controller.close() }
        controller.window!.contentView!.layoutSubtreeIfNeeded()
        let size = control(controller, "propertiesValue-size", NSTextField.self)
        try waitFor { size.stringValue.contains("bytes") }
        let apply = control(controller, "propertiesApply", NSButton.self)
        let name = control(controller, "propertiesName", NSTextField.self)
        try require(!apply.isEnabled, "Apply must be disabled for an unchanged name")
        try require(size.frame.width > 250, "Metadata value column must use the available width")
        let path = control(controller, "propertiesValue-path", NSTextField.self)
        try require(path.isSelectable && path.stringValue == file.path, "Full path must be selectable and complete")
        edit(controller, "pending.txt")
        try require(apply.isEnabled, "Apply must become enabled for a changed name")
        control(controller, "propertiesRefresh", NSButton.self).performClick(nil)
        try waitFor { size.stringValue.contains("bytes") }
        try require(name.stringValue == "pending.txt", "Refresh must preserve a pending name edit")
        var renameCount = 0, closed = false
        controller.onRename = { _, _, completion in
            renameCount += 1
            completion(.failure(NSError(domain: NSCocoaErrorDomain, code: NSFileWriteFileExistsError,
                                        userInfo: [NSLocalizedDescriptionKey: "A file already exists."])))
        }
        controller.onClose = { closed = true }
        apply.performClick(nil); pump(0.1)
        try require(renameCount == 1 && !closed, "A failed rename must keep the dialog open")
        try require(!control(controller, "propertiesError", NSTextField.self).isHidden, "Rename errors must appear inline")
        control(controller, "propertiesCancel", NSButton.self).performClick(nil); pump(0.05)
        try require(closed && renameCount == 1, "Cancel must close without applying the pending name")
        let multi = PropertiesWindowController(urls: [file, second])
        defer { multi.close() }
        try waitFor { control(multi, "propertiesValue-size", NSTextField.self).stringValue.contains("bytes") }
        try require(!control(multi, "propertiesName", NSTextField.self).isEditable, "Multiple items must not allow rename")
        for tab in ["Details", "Permissions"] { control(multi, "propertiesTab" + tab, NSButton.self).performClick(nil) }
        try require(control(multi, "propertiesValue-owner", NSTextField.self).stringValue != "—", "Permissions tab must show owner metadata")
        multi.close()
        let success = PropertiesWindowController(urls: [file])
        defer { success.close() }
        var successfulClose = false
        success.onClose = { successfulClose = true }
        // Test the controller contract without mutating the fixture.
        success.onRename = { _, _, completion in completion(.success(file)) }
        edit(success, "renamed.txt")
        control(success, "propertiesOK", NSButton.self).performClick(nil); pump(0.1)
        try require(successfulClose, "OK must close only after rename succeeds")
        let folder = PropertiesWindowController(urls: [fixtures])
        defer { folder.close() }
        try waitFor { control(folder, "propertiesValue-size", NSTextField.self).stringValue.contains("bytes") }
        try require(control(folder, "propertiesValue-contains", NSTextField.self).stringValue == "2 files, 0 subfolders",
                    "Folder totals must distinguish selected roots from contained subfolders")
        folder.close()

        let shortcutURL = fixtures.appendingPathComponent("Report.txt - Shortcut.fmlink")
        try AppShortcutDocument.data(for: file).write(to: shortcutURL)
        let shortcut = PropertiesWindowController(urls: [shortcutURL])
        defer { shortcut.close() }
        try waitFor { control(shortcut, "propertiesValue-type", NSTextField.self).stringValue == "Shortcut" }
        let shortcutName = control(shortcut, "propertiesName", NSTextField.self)
        try require(shortcutName.stringValue == "Report.txt - Shortcut" && shortcut.window?.title == "Report.txt - Shortcut Properties",
                    "Shortcut name and title must hide the internal document extension")
        try require(control(shortcut, "propertiesValue-detailName", NSTextField.self).stringValue == "Report.txt - Shortcut",
                    "Details Name must match the shortcut display name")
        try require(control(shortcut, "propertiesValue-application", NSTextField.self).stringValue == "WinExplorer for Mac",
                    "Properties must identify the application that opens shortcut documents")
        try require(control(shortcut, "propertiesValue-path", NSTextField.self).stringValue == shortcutURL.path,
                    "Copyable full paths must preserve the actual shortcut document path")
        var requestedShortcutNames: [String] = []
        shortcut.onRename = { source, newName, completion in
            requestedShortcutNames.append(newName)
            let destination = source.deletingLastPathComponent().appendingPathComponent(newName)
            do { try manager.moveItem(at: source, to: destination); completion(.success(destination)) }
            catch { completion(.failure(error)) }
        }
        edit(shortcut, "Renamed shortcut")
        control(shortcut, "propertiesApply", NSButton.self).performClick(nil)
        try waitFor { shortcut.urls.first?.lastPathComponent == "Renamed shortcut.fmlink" }
        try require(requestedShortcutNames == ["Renamed shortcut.fmlink"] && shortcutName.stringValue == "Renamed shortcut",
                    "Renaming a display name must retain the document extension and refresh the display name")
        try require(!control(shortcut, "propertiesApply", NSButton.self).isEnabled,
                    "A completed shortcut rename must leave no pending name edit")
        let resolvedShortcut = try AppShortcutDocument.resolve(shortcut.urls[0])
        try require(resolvedShortcut.standardizedFileURL == file.standardizedFileURL, "Renaming must preserve the bookmark document target")
        edit(shortcut, "Explicit.FMLINK")
        control(shortcut, "propertiesApply", NSButton.self).performClick(nil)
        try waitFor { shortcut.urls.first?.lastPathComponent == "Explicit.FMLINK" }
        try require(requestedShortcutNames.last == "Explicit.FMLINK" && shortcutName.stringValue == "Explicit",
                    "An explicitly typed extension must not be duplicated, regardless of case")
        edit(shortcut, "Discarded name")
        control(shortcut, "propertiesCancel", NSButton.self).performClick(nil)
        try require(requestedShortcutNames.count == 2 && manager.fileExists(atPath: shortcut.urls[0].path),
                    "Cancel must leave a shortcut and its internal extension untouched")
        if let index = CommandLine.arguments.firstIndex(of: "--render"), index + 1 < CommandLine.arguments.count {
            let renderURL = URL(fileURLWithPath: CommandLine.arguments[index + 1])
            let render = PropertiesWindowController(urls: [renderURL])
            defer { render.close() }
            try waitFor { control(render, "propertiesValue-size", NSTextField.self).stringValue.contains("bytes") }
            let root = render.window!.contentView!
            let output = project.appendingPathComponent(".build/qa")
            try manager.createDirectory(at: output, withIntermediateDirectories: true)
            var layoutLines: [String] = []
            for (suffix, dimensions) in [("preview", NSSize(width: 620, height: 660)), ("minimum", NSSize(width: 560, height: 560))] {
                render.window!.setContentSize(dimensions); root.layoutSubtreeIfNeeded(); pump(0.05)
                root.layoutSubtreeIfNeeded()
                guard let bitmap = root.bitmapImageRepForCachingDisplay(in: root.bounds) else {
                    throw PropertiesWindowRegressionFailure(description: "Could not allocate Properties preview bitmap")
                }
                root.cacheDisplay(in: root.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("properties-window-\(suffix).png"))
                layoutLines.append("\(suffix): \(root.bounds)")
                for id in ["propertiesName", "propertiesValue-path", "propertiesValue-created", "propertiesValue-modified", "propertiesValue-accessed", "propertiesOK"] {
                    if let field = find(id, in: root) {
                        layoutLines.append("  \(id): \(field.convert(field.bounds, to: root)); visible \(field.visibleRect)")
                    }
                }
                try require(control(render, "propertiesValue-size", NSTextField.self).frame.width > 200, "Minimum window width collapsed metadata")
            }
            try layoutLines.joined(separator: "\n").write(to: output.appendingPathComponent("properties-window-layout.txt"), atomically: true, encoding: .utf8)
        }
        print("PASS: Properties metadata/layout, selectable paths, dirty refresh, failure/Cancel/OK lifecycle, multiple items, folder totals, and shortcut display/rename preservation")
    }
}
