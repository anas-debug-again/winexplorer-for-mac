// Hidden AppKit regression. Run from the project directory:
// xcrun swiftc -swift-version 5 -module-cache-path .build/module-cache \
//   Sources/MacFileManager/AppSupport.swift Sources/MacFileManager/ExplorerOptionsWindowController.swift \
//   Tests/UIRegression/ExplorerOptionsRegression.swift -o .build/qa/explorer-options-regression
// .build/qa/explorer-options-regression
// No visible windows, posted input, real settings writes, or user files.
import AppKit

private struct OptionsRegressionFailure: Error, CustomStringConvertible { let description: String }

@main struct ExplorerOptionsRegression {
    static var checks = 0
    static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        checks += 1
        if try !condition() { throw OptionsRegressionFailure(description: message) }
    }
    static func control<T: NSView>(_ controller: ExplorerOptionsWindowController, _ id: String, _ type: T.Type) throws -> T {
        func find(_ view: NSView) -> NSView? {
            if view.accessibilityIdentifier() == id { return view }
            return view.subviews.lazy.compactMap(find).first
        }
        guard let result = controller.window?.contentView.flatMap(find) as? T else {
            throw OptionsRegressionFailure(description: "Missing options control: \(id)")
        }
        return result
    }
    static func change(_ button: NSButton) { button.performClick(nil) }
    static func select(_ popup: NSPopUpButton, _ index: Int) {
        popup.selectItem(at: index); NSApp.sendAction(popup.action!, to: popup.target, from: popup)
    }
    static func main() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        NSApp.appearance = NSAppearance(named: .aqua)
        let manager = FileManager.default
        let fixture = URL(fileURLWithPath: manager.currentDirectoryPath).appendingPathComponent(".build/qa/options-fixtures-" + UUID().uuidString)
        try manager.createDirectory(at: fixture, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: fixture) }
        let defaults = ExplorerPreferences()
        let controller = ExplorerOptionsWindowController(preferences: defaults)
        defer { controller.close() }
        var applications: [ExplorerPreferences] = []
        var closed = 0
        controller.onApply = { applications.append($0) }; controller.onClose = { closed += 1 }
        controller.window!.contentView!.layoutSubtreeIfNeeded()
        let apply = try control(controller, "optionsApply", NSButton.self)
        let path = try control(controller, "optionsStartupPath", NSTextField.self)
        let startup = try control(controller, "optionsStartup", NSPopUpButton.self)
        let browse = try control(controller, "optionsBrowse", NSButton.self)
        try require(!apply.isEnabled && !path.isEnabled && !browse.isEnabled, "Unchanged default settings must disable Apply and custom-folder controls")
        try require(applications.isEmpty, "Opening Options must not mutate app settings")
        change(try control(controller, "optionsTabView", NSButton.self))
        let extensions = try control(controller, "optionsShowExtensions", NSButton.self)
        let hidden = try control(controller, "optionsShowHidden", NSButton.self)
        let compact = try control(controller, "optionsCompact", NSButton.self)
        change(extensions); change(hidden); change(compact)
        let view = try control(controller, "optionsDefaultView", NSPopUpButton.self)
        select(view, 5)
        try require(apply.isEnabled && applications.isEmpty, "View edits must remain a draft until Apply")
        change(apply)
        try require(applications.count == 1 && !applications[0].showFileExtensions && applications[0].showHiddenFiles,
                    "Apply must publish extension and hidden-file preferences")
        try require(applications[0].compactView && applications[0].defaultViewMode == "tiles", "Apply must publish default view and compact spacing")
        try require(!apply.isEnabled && closed == 0, "Apply must establish a new baseline without closing")
        change(try control(controller, "optionsRestoreDefaults", NSButton.self))
        try require(apply.isEnabled && applications.count == 1, "Restore defaults must only replace the draft")
        change(try control(controller, "optionsCancel", NSButton.self))
        try require(closed == 1 && applications.count == 1, "Cancel must discard default restoration without undoing the earlier Apply")

        let custom = ExplorerOptionsWindowController(preferences: defaults)
        defer { custom.close() }
        var customApplications: [ExplorerPreferences] = []
        var customClosed = 0
        custom.onApply = { customApplications.append($0) }; custom.onClose = { customClosed += 1 }
        let customStartup = try control(custom, "optionsStartup", NSPopUpButton.self)
        let customField = try control(custom, "optionsStartupPath", NSTextField.self)
        select(customStartup, 3)
        try require(customField.isEnabled, "Custom startup choice must enable its path field")
        func editPath(_ value: String) {
            customField.stringValue = value
            custom.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: customField))
        }
        editPath(fixture.appendingPathComponent("missing").path)
        change(try control(custom, "optionsOK", NSButton.self))
        try require(customApplications.isEmpty && customClosed == 0, "Invalid startup path must block OK without changing settings")
        try require(!(try control(custom, "optionsError", NSTextField.self)).stringValue.isEmpty, "Invalid folder must show an inline validation error")
        let regularFile = fixture.appendingPathComponent("file.txt")
        try Data("not a folder".utf8).write(to: regularFile)
        editPath(regularFile.path)
        change(try control(custom, "optionsApply", NSButton.self))
        try require(customApplications.isEmpty, "A file cannot be used as the custom startup folder")
        if geteuid() != 0 {
            let restricted = fixture.appendingPathComponent("restricted", isDirectory: true)
            try manager.createDirectory(at: restricted, withIntermediateDirectories: true)
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: restricted.path)
            defer { try? manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: restricted.path) }
            editPath(restricted.path)
            change(try control(custom, "optionsApply", NSButton.self))
            try require(customApplications.isEmpty, "A readable folder without traversal permission cannot be a startup folder")
        }
        editPath(fixture.path)
        change(try control(custom, "optionsApply", NSButton.self))
        try require(customApplications.count == 1 && customApplications[0].startupPath == fixture.path && customApplications[0].startupLocation == "custom",
                    "Valid custom folder must be applied")
        try require(customClosed == 0, "Apply must leave custom options open")
        change(try control(custom, "optionsRestoreDefaults", NSButton.self))
        change(try control(custom, "optionsOK", NSButton.self))
        try require(customApplications.count == 2 && customApplications[1] == defaults && customClosed == 1,
                    "OK after Restore defaults must apply defaults and close once")

        let clean = ExplorerOptionsWindowController(preferences: defaults)
        var cleanApplies = 0, cleanClosed = 0
        clean.onApply = { _ in cleanApplies += 1 }; clean.onClose = { cleanClosed += 1 }
        change(try control(clean, "optionsOK", NSButton.self))
        try require(cleanApplies == 0 && cleanClosed == 1, "Unchanged OK must close without a redundant settings write")
        try require(ExplorerPreferences.viewModes.count == 6 && startup.numberOfItems == 4, "All requested default views and startup choices must be available")
        if CommandLine.arguments.contains("--render") {
            let render = ExplorerOptionsWindowController(preferences: defaults)
            defer { render.close() }
            let root = render.window!.contentView!
            let output = URL(fileURLWithPath: manager.currentDirectoryPath).appendingPathComponent(".build/qa")
            for (name, id) in [("general", "optionsTabGeneral"), ("view", "optionsTabView")] {
                change(try control(render, id, NSButton.self))
                root.layoutSubtreeIfNeeded()
                guard let bitmap = root.bitmapImageRepForCachingDisplay(in: root.bounds) else {
                    throw OptionsRegressionFailure(description: "Unable to create options preview bitmap")
                }
                root.cacheDisplay(in: root.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("explorer-options-\(name).png"))
            }
        }
        print("PASS: \(checks) Explorer Options checks covering draft isolation, six views, Apply/OK/Cancel, Restore defaults, and custom-folder validation")
    }
}
